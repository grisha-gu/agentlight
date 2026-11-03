import Foundation

/// All of the "which session is in which slot and what's lit" logic, with no I/O.
/// Rules — docs/01-architecture.md §1.3–1.5. The whole value is saved to state.json.
public struct SlotAllocator: Codable, Equatable, Sendable {
    public private(set) var slots: [Slot]
    /// sessions without a traffic light, waiting for a slot to free up
    public private(set) var overflow: [SessionRecord]
    /// hidden sessions: the Claude Code daemon spare and shell tabs whose session moved
    /// to the background. They get no traffic light, but their events are absorbed so they don't land
    /// in a slot via claim on the very first hook. (The name comes from state.json of older versions.)
    public private(set) var background: [SessionRecord]

    public init(slotCount: Int = Config().slotCount) {
        slots = Array(repeating: Slot(), count: slotCount)
        overflow = []
        background = []
    }

    enum CodingKeys: String, CodingKey { case slots, overflow, background }

    /// state.json from older versions — without `background`
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slots = try c.decode([Slot].self, forKey: .slots)
        overflow = try c.decode([SessionRecord].self, forKey: .overflow)
        background = try c.decodeIfPresent([SessionRecord].self, forKey: .background) ?? []
    }

    /// What's known about the session's claude process (`ClaudeSessions.roles()`; a stand-in in tests).
    public struct Roles {
        /// this process's session gets no traffic light
        public var isHidden: (Int32) -> Bool
        /// for a background session — pid of the shell tab it was sent to the background from
        public var parkedShell: (Int32) -> Int32?

        public init(isHidden: @escaping (Int32) -> Bool = { _ in false },
                    parkedShell: @escaping (Int32) -> Int32? = { _ in nil }) {
            self.isHidden = isHidden
            self.parkedShell = parkedShell
        }

        public static var none: Roles { Roles() }
    }

    /// What changed after an event — for the transport and the UI.
    public struct Effects: Equatable, Sendable {
        public var welcome: [Int] = []
        public var changed = false

        mutating func merge(_ o: Effects) {
            welcome += o.welcome
            changed = changed || o.changed
        }
    }

    public var lights: [LightState] { slots.map(\.light) }

    public func slotIndex(of sessionId: String) -> Int? {
        slots.firstIndex { $0.session?.sessionId == sessionId }
    }

    public func isHidden(_ sessionId: String) -> Bool {
        background.contains { $0.sessionId == sessionId }
    }

    // MARK: - Events

    public mutating func handle(_ event: HookEvent, config: Config, now: Date,
                                roles: Roles = .none) -> Effects {
        let before = self
        var fx = Effects()

        switch SlotStateMachine.transition(for: event) {
        case .start:
            fx.merge(claim(event, config: config, now: now, roles: roles))
        case .end(let rebind):
            fx.merge(end(event, rebind: rebind, config: config, now: now))
        case .set(let state):
            if !touch(event, now: now) {
                // the daemon started after the agent, or hooks were installed mid-session
                fx.merge(claim(event, config: config, now: now, roles: roles))
            }
            update(event.sessionId) { $0.set(state, at: now) }
        case .ignore:
            if !touch(event, now: now) {
                fx.merge(claim(event, config: config, now: now, roles: roles))
            }
        }
        // an agent view spare became a job: show it right away, don't wait for sweep
        fx.merge(reveal(only: event.sessionId, roles: roles))
        fx.changed = fx.changed || lights != before.lights || self != before
        return fx
    }

    /// The user interrupted the turn with Esc (visible only in the transcript): the agent waits for input → green.
    public mutating func interrupted(_ sessionId: String, now: Date) -> Effects {
        let before = self
        update(sessionId) {
            $0.lastEventAt = now
            $0.set(.idle, at: now)
        }
        return Effects(changed: self != before)
    }

    /// Sessions with a transcript file — the daemon watches them.
    public var transcripts: [String: String] {
        var out: [String: String] = [:]
        for s in slots.compactMap(\.session) + overflow {
            if let p = s.transcriptPath { out[s.sessionId] = p }
        }
        return out
    }

    /// Free the slot the session sits in (the "forget" button, CLI).
    public mutating func release(slot: Int, now: Date) -> Effects {
        guard slots.indices.contains(slot), slots[slot].session != nil else { return Effects() }
        return free(slot, now: now)
    }

    /// Fill in a session's pid and terminal found after the fact (for sessions without SessionStart).
    public mutating func adopt(slot: Int, pid: Int32, tty: String?, cwd: String) {
        guard slots.indices.contains(slot), var s = slots[slot].session else { return }
        if s.claudePid == nil { s.claudePid = pid }
        s.cwd = cwd
        if s.terminal?.tty == nil {
            var t = s.terminal ?? TerminalRef()
            t.tty = tty
            s.terminal = t
        }
        slots[slot].session = s
    }

    public mutating func toggleMute(slot: Int) -> Effects {
        guard slots.indices.contains(slot), slots[slot].session != nil else { return Effects() }
        slots[slot].muted.toggle()
        return Effects(changed: true)
    }

    /// The number of traffic lights (`slot_count`) changed. Sessions from extra slots go
    /// to overflow, new slots are filled from overflow, like on release.
    public mutating func resize(to count: Int, now: Date) -> Effects {
        guard count != slots.count else { return Effects() }
        var fx = Effects(changed: true)
        if count < slots.count {
            // a slot in rebinding has already ended its session — nothing to move
            overflow += slots[count...].filter { $0.rebinding == nil }.compactMap(\.session)
            slots.removeSubrange(count...)
            return fx
        }
        let added = slots.count..<count
        slots += Array(repeating: Slot(), count: added.count)
        for i in added { fx.merge(free(i, now: now)) }
        return fx
    }

    // MARK: - Periodic check (every 5 s)

    /// BUSY timeouts, TTL, rebinding windows, PID liveness, and background sessions that got into slots
    /// earlier (state.json from an older version, pid learned after the first event).
    public mutating func sweep(config: Config, now: Date, isAlive: (Int32) -> Bool,
                               roles: Roles = .none) -> Effects {
        var fx = Effects()
        let before = self

        background.removeAll { Self.isDead($0, config: config, now: now, isAlive: isAlive) }
        overflow.removeAll { Self.isDead($0, config: config, now: now, isAlive: isAlive) }
        func hide(_ s: SessionRecord) -> Bool {
            guard let pid = s.claudePid, roles.isHidden(pid) else { return false }
            background.append(s)
            return true
        }
        overflow.removeAll(where: hide)
        for i in overflow.indices { Self.degradeBusy(&overflow[i], config: config, now: now) }

        // from the end: free(i) only shifts already-checked slots to the left
        for i in slots.indices.reversed() {
            if let r = slots[i].rebinding, r.until <= now {
                slots[i].rebinding = nil
                fx.merge(free(i, now: now))
                continue
            }
            guard slots[i].rebinding == nil, var s = slots[i].session else { continue }
            if Self.isDead(s, config: config, now: now, isAlive: isAlive) {
                fx.merge(free(i, now: now))
                continue
            }
            if hide(s) {
                // the tab was sent to the background: its slot goes to the background session, the lamp doesn't jump
                if let j = slots.indices.first(where: { j in
                    j != i && slots[j].rebinding == nil &&
                        slots[j].session?.claudePid.flatMap(roles.parkedShell) == s.claudePid
                }) {
                    slots[i].session = slots[j].session  // keep the tab's mute
                    fx.merge(free(j, now: now))
                } else {
                    fx.merge(free(i, now: now))
                }
                continue
            }
            Self.degradeBusy(&s, config: config, now: now)
            slots[i].session = s
        }
        fx.merge(reveal(only: nil, roles: roles))
        fx.changed = fx.changed || self != before
        return fx
    }

    /// Hidden sessions that now deserve a traffic light: an agent view spare was given a job,
    /// or hidden by an older version (back then any session under bg-pty-host counted as windowless).
    private mutating func reveal(only id: String?, roles: Roles) -> Effects {
        let shown = background.filter { s in
            (id == nil || s.sessionId == id) && (s.claudePid.map { !roles.isHidden($0) } ?? false)
        }
        guard !shown.isEmpty else { return Effects() }
        background.removeAll { s in shown.contains { $0.sessionId == s.sessionId } }
        var fx = Effects(changed: true)
        for s in shown {
            if let i = slots.firstIndex(where: \.isFree) {
                occupy(i, with: s)
                fx.merge(Effects(welcome: [i], changed: true))
            } else {
                overflow.append(s)
            }
        }
        return fx
    }

    /// The Mac slept for `interval`: sleep time doesn't count as agent silence — neither for TTL
    /// nor for the BUSY timeout.
    public mutating func postpone(by interval: TimeInterval) {
        guard interval > 0 else { return }
        func shift(_ s: inout SessionRecord) {
            s.lastEventAt += interval
            s.stateSince += interval
        }
        for i in slots.indices where slots[i].session != nil { shift(&slots[i].session!) }
        for i in overflow.indices { shift(&overflow[i]) }
    }

    // MARK: - Internals

    /// If the PID is known, only it decides: an agent may stay silent as long as it likes (a night with
    /// the lid open, laptop sleep). TTL is a safety net for sessions whose process we never found.
    private static func isDead(_ s: SessionRecord, config: Config, now: Date, isAlive: (Int32) -> Bool) -> Bool {
        if let pid = s.claudePid { return !isAlive(pid) }
        return now.timeIntervalSince(s.lastEventAt) > config.sessionTTLSec
    }

    private static func degradeBusy(_ s: inout SessionRecord, config: Config, now: Date) {
        if s.state == .busy, now.timeIntervalSince(s.lastEventAt) > config.busyTimeoutSec {
            s.set(.idle, at: now)
        }
    }

    /// Update a session's record wherever it is. false — unknown session.
    @discardableResult
    private mutating func update(_ id: String, _ body: (inout SessionRecord) -> Void) -> Bool {
        if let i = slotIndex(of: id) {
            body(&slots[i].session!)
            return true
        }
        if let i = overflow.firstIndex(where: { $0.sessionId == id }) {
            body(&overflow[i])
            return true
        }
        if let i = background.firstIndex(where: { $0.sessionId == id }) {
            body(&background[i])
            return true
        }
        return false
    }

    private mutating func touch(_ event: HookEvent, now: Date) -> Bool {
        update(event.sessionId) { $0.absorb(event, at: now) }
    }

    /// claim(session_id, cwd, pid), docs/01-architecture.md §1.4.
    private mutating func claim(_ event: HookEvent, config: Config, now: Date,
                                roles: Roles) -> Effects {
        // 1. the session is already known
        if touch(event, now: now) { return Effects() }

        var record = SessionRecord(sessionId: event.sessionId, cwd: event.cwd, state: .idle, at: now)
        record.absorb(event, at: now)

        // 2. daemon spare or shell tab (including /clear inside it) — no traffic light
        if let pid = record.claudePid, roles.isHidden(pid) {
            background.append(record)
            return Effects(changed: true)
        }

        // 2a. the session was sent to the background: the fork takes its shell tab's slot, no welcome
        if let shell = record.claudePid.flatMap(roles.parkedShell),
           let i = slots.indices.first(where: { slots[$0].rebinding == nil && slots[$0].session?.claudePid == shell }) {
            background.append(slots[i].session!)
            slots[i].session = record
            return Effects(changed: true)
        }

        // 3. /clear, /resume: same terminal → same slot, no welcome
        if let i = rebindTarget(for: record, source: event.source, now: now) {
            if let old = slots[i].session, old.terminal != nil, record.terminal == nil {
                record.terminal = old.terminal
            }
            slots[i].session = record
            slots[i].rebinding = nil
            return Effects(changed: true)
        }

        // 4. explicit request (empty slot button), 5. pin, 6. first free one
        let preferred = [event.agentlight?.preferSlot, config.pinnedSlot(for: record.cwd)]
            .compactMap { $0 }
            .filter { slots.indices.contains($0) }
        if let i = preferred.first(where: { slots[$0].isFree }) ?? slots.firstIndex(where: \.isFree) {
            occupy(i, with: record)
            return Effects(welcome: [i], changed: true)
        }

        // 7. no room — to overflow, no traffic light
        overflow.append(record)
        return Effects(changed: true)
    }

    private func rebindTarget(for record: SessionRecord, source: String?, now: Date) -> Int? {
        func sameTerminal(cwd: String?, pid: Int32?) -> Bool {
            if let a = pid, let b = record.claudePid { return a == b }
            return cwd != nil && cwd == record.cwd
        }
        if let i = slots.indices.first(where: { i in
            guard let r = slots[i].rebinding, r.until > now else { return false }
            return sameTerminal(cwd: r.cwd, pid: r.claudePid)
        }) {
            return i
        }
        // the SessionStart command hook may overtake the old session's SessionEnd http hook:
        // then the old one still sits in the slot — recognize it by the claude process PID
        guard source == "clear" || source == "resume", let pid = record.claudePid else { return nil }
        return slots.indices.first { slots[$0].session?.claudePid == pid }
    }

    private mutating func end(_ event: HookEvent, rebind: Bool, config: Config, now: Date) -> Effects {
        if let i = background.firstIndex(where: { $0.sessionId == event.sessionId }) {
            background.remove(at: i)
            return Effects(changed: true)
        }
        if let i = overflow.firstIndex(where: { $0.sessionId == event.sessionId }) {
            overflow.remove(at: i)
            return Effects(changed: true)
        }
        guard let i = slotIndex(of: event.sessionId) else { return Effects() }
        if rebind {
            let s = slots[i].session!
            slots[i].rebinding = Rebinding(cwd: s.cwd, claudePid: s.claudePid,
                                           until: now.addingTimeInterval(config.rebindWindowSec))
            return Effects(changed: true)
        }
        return free(i, now: now)
    }

    private mutating func occupy(_ i: Int, with record: SessionRecord) {
        slots[i] = Slot()
        slots[i].session = record
    }

    /// Free the slot, shift the occupied slots left (no gaps between traffic lights)
    /// and let the most recent overflow session into the first free one.
    private mutating func free(_ i: Int, now: Date) -> Effects {
        slots[i] = Slot()
        let taken = slots.filter { !$0.isFree }
        slots = taken + Array(repeating: Slot(), count: slots.count - taken.count)
        guard let j = overflow.indices.max(by: { overflow[$0].lastEventAt < overflow[$1].lastEventAt }) else {
            return Effects(changed: true)
        }
        occupy(taken.count, with: overflow.remove(at: j))
        return Effects(welcome: [taken.count], changed: true)
    }
}
