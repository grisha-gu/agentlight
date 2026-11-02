import Foundation

/// Вся логика «какая сессия в каком слоте и что горит», без ввода-вывода.
/// Правила — docs/01-architecture.md §1.3–1.5. Значение целиком сохраняется в state.json.
public struct SlotAllocator: Codable, Equatable, Sendable {
    public private(set) var slots: [Slot]
    /// сессии без светофора, ждут освобождения слота
    public private(set) var overflow: [SessionRecord]
    /// скрытые сессии: запасная заготовка демона Claude Code и вкладка-оболочка, чья сессия
    /// уехала в фон. Светофор им не положен, но события поглощаем, чтобы они не заехали
    /// в слот через claim по первому же хуку. (Имя — из state.json прошлых версий.)
    public private(set) var background: [SessionRecord]

    public init(slotCount: Int = Config().slotCount) {
        slots = Array(repeating: Slot(), count: slotCount)
        overflow = []
        background = []
    }

    enum CodingKeys: String, CodingKey { case slots, overflow, background }

    /// state.json старых версий — без `background`
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slots = try c.decode([Slot].self, forKey: .slots)
        overflow = try c.decode([SessionRecord].self, forKey: .overflow)
        background = try c.decodeIfPresent([SessionRecord].self, forKey: .background) ?? []
    }

    /// Что известно о процессе claude сессии (`ClaudeSessions.roles()`; в тестах — подставное).
    public struct Roles {
        /// сессии процесса светофор не положен
        public var isHidden: (Int32) -> Bool
        /// для фоновой сессии — pid вкладки-оболочки, из которой её отправили в фон
        public var parkedShell: (Int32) -> Int32?

        public init(isHidden: @escaping (Int32) -> Bool = { _ in false },
                    parkedShell: @escaping (Int32) -> Int32? = { _ in nil }) {
            self.isHidden = isHidden
            self.parkedShell = parkedShell
        }

        public static var none: Roles { Roles() }
    }

    /// Что поменялось после события — для транспорта и UI.
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

    // MARK: - События

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
                // демон стартовал позже агента или хуки поставлены посреди сессии
                fx.merge(claim(event, config: config, now: now, roles: roles))
            }
            update(event.sessionId) { $0.set(state, at: now) }
        case .ignore:
            if !touch(event, now: now) {
                fx.merge(claim(event, config: config, now: now, roles: roles))
            }
        }
        // заготовка из agent view стала задачей: показать сразу, не ждать sweep
        fx.merge(reveal(only: event.sessionId, roles: roles))
        fx.changed = fx.changed || lights != before.lights || self != before
        return fx
    }

    /// Пользователь прервал ход по Esc (видно только по transcript): агент ждёт ввода → зелёный.
    public mutating func interrupted(_ sessionId: String, now: Date) -> Effects {
        let before = self
        update(sessionId) {
            $0.lastEventAt = now
            $0.set(.idle, at: now)
        }
        return Effects(changed: self != before)
    }

    /// Сессии с transcript-файлом — за ними следит демон.
    public var transcripts: [String: String] {
        var out: [String: String] = [:]
        for s in slots.compactMap(\.session) + overflow {
            if let p = s.transcriptPath { out[s.sessionId] = p }
        }
        return out
    }

    /// Освободить слот, в котором сидит сессия (кнопка «забыть», CLI).
    public mutating func release(slot: Int, now: Date) -> Effects {
        guard slots.indices.contains(slot), slots[slot].session != nil else { return Effects() }
        return free(slot, now: now)
    }

    /// Дописать найденные задним числом pid и терминал сессии (для сессий без SessionStart).
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

    /// Сменилось число светофоров (`slot_count`). Сессии из лишних слотов уходят
    /// в overflow, новые слоты заполняются из overflow, как при освобождении.
    public mutating func resize(to count: Int, now: Date) -> Effects {
        guard count != slots.count else { return Effects() }
        var fx = Effects(changed: true)
        if count < slots.count {
            // слот в rebinding уже закончил сессию — переносить нечего
            overflow += slots[count...].filter { $0.rebinding == nil }.compactMap(\.session)
            slots.removeSubrange(count...)
            return fx
        }
        let added = slots.count..<count
        slots += Array(repeating: Slot(), count: added.count)
        for i in added { fx.merge(free(i, now: now)) }
        return fx
    }

    // MARK: - Периодическая проверка (раз в 5 с)

    /// Таймауты BUSY, TTL, окна rebinding, живость PID и фоновые сессии, попавшие в слоты
    /// раньше (state.json прошлой версии, pid узнали позже первого события).
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

        // с конца: free(i) сдвигает влево только уже проверенные слоты
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
                // вкладку отправили в фон: её слот достаётся фоновой сессии, без прыжка лампы
                if let j = slots.indices.first(where: { j in
                    j != i && slots[j].rebinding == nil &&
                        slots[j].session?.claudePid.flatMap(roles.parkedShell) == s.claudePid
                }) {
                    slots[i].session = slots[j].session  // заглушку вкладки сохраняем
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

    /// Скрытые сессии, которым светофор теперь положен: заготовке из agent view отдали задачу,
    /// спрятанные прошлой версией (тогда любая сессия под bg-pty-host считалась безоконной).
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

    /// Мак проспал `interval`: время сна не считается молчанием агента — ни для TTL,
    /// ни для таймаута BUSY.
    public mutating func postpone(by interval: TimeInterval) {
        guard interval > 0 else { return }
        func shift(_ s: inout SessionRecord) {
            s.lastEventAt += interval
            s.stateSince += interval
        }
        for i in slots.indices where slots[i].session != nil { shift(&slots[i].session!) }
        for i in overflow.indices { shift(&overflow[i]) }
    }

    // MARK: - Внутреннее

    /// Известен PID — решает только он: агент может молчать сколько угодно (ночь у открытой
    /// крышки, сон ноута). TTL — страховка для сессий, чей процесс мы так и не нашли.
    private static func isDead(_ s: SessionRecord, config: Config, now: Date, isAlive: (Int32) -> Bool) -> Bool {
        if let pid = s.claudePid { return !isAlive(pid) }
        return now.timeIntervalSince(s.lastEventAt) > config.sessionTTLSec
    }

    private static func degradeBusy(_ s: inout SessionRecord, config: Config, now: Date) {
        if s.state == .busy, now.timeIntervalSince(s.lastEventAt) > config.busyTimeoutSec {
            s.set(.idle, at: now)
        }
    }

    /// Обновить запись сессии, где бы она ни была. false — сессия неизвестна.
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
        // 1. сессия уже известна
        if touch(event, now: now) { return Effects() }

        var record = SessionRecord(sessionId: event.sessionId, cwd: event.cwd, state: .idle, at: now)
        record.absorb(event, at: now)

        // 2. заготовка демона или вкладка-оболочка (в т.ч. /clear внутри неё) — без светофора
        if let pid = record.claudePid, roles.isHidden(pid) {
            background.append(record)
            return Effects(changed: true)
        }

        // 2a. сессию отправили в фон: форк занимает слот своей вкладки-оболочки, без welcome
        if let shell = record.claudePid.flatMap(roles.parkedShell),
           let i = slots.indices.first(where: { slots[$0].rebinding == nil && slots[$0].session?.claudePid == shell }) {
            background.append(slots[i].session!)
            slots[i].session = record
            return Effects(changed: true)
        }

        // 3. /clear, /resume: тот же терминал → тот же слот, без welcome
        if let i = rebindTarget(for: record, source: event.source, now: now) {
            if let old = slots[i].session, old.terminal != nil, record.terminal == nil {
                record.terminal = old.terminal
            }
            slots[i].session = record
            slots[i].rebinding = nil
            return Effects(changed: true)
        }

        // 4. явная просьба (кнопка пустого слота), 5. пин, 6. первый свободный
        let preferred = [event.agentlight?.preferSlot, config.pinnedSlot(for: record.cwd)]
            .compactMap { $0 }
            .filter { slots.indices.contains($0) }
        if let i = preferred.first(where: { slots[$0].isFree }) ?? slots.firstIndex(where: \.isFree) {
            occupy(i, with: record)
            return Effects(welcome: [i], changed: true)
        }

        // 7. мест нет — в overflow, без светофора
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
        // command-хук SessionStart может обогнать http-хук SessionEnd старой сессии:
        // тогда старая ещё сидит в слоте — узнаём её по PID процесса claude
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

    /// Освободить слот, сдвинуть занятые слоты влево (без дырок между светофорами)
    /// и пустить в первый свободный самую свежую сессию из overflow.
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
