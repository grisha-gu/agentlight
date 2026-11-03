import Foundation
import XCTest
@testable import AgentLightKit

final class SlotAllocatorTests: XCTestCase {
    var a = SlotAllocator()
    var config = Config()
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var alive: Set<Int32> = []

    @discardableResult
    func send(_ name: String, _ sid: String, cwd: String? = "/p/x", pid: Int32? = nil,
              prefer: Int? = nil, notification: String? = nil, source: String? = nil,
              reason: String? = nil) -> SlotAllocator.Effects {
        var e = HookEvent(name: name, sessionId: sid, cwd: cwd)
        e.notificationType = notification
        e.source = source
        e.reason = reason
        if pid != nil || prefer != nil { e.agentlight = HookExtras(claudePid: pid, preferSlot: prefer) }
        return a.handle(e, config: config, now: now)
    }

    func sweep(after seconds: Double) -> SlotAllocator.Effects {
        now += seconds
        return a.sweep(config: config, now: now) { self.alive.contains($0) }
    }

    func testBasicLifecycle() {
        XCTAssertEqual(send("SessionStart", "a").welcome, [0])
        XCTAssertEqual(a.lights, [.idle, .off, .off, .off])
        send("UserPromptSubmit", "a")
        XCTAssertEqual(a.lights[0], .busy)
        send("Stop", "a")
        XCTAssertEqual(a.lights[0], .idle)
        send("SessionEnd", "a", reason: "prompt_input_exit")
        XCTAssertEqual(a.lights, [.off, .off, .off, .off])
    }

    func testPermissionSequencesHealThemselves() {
        send("SessionStart", "a")
        send("PreToolUse", "a")
        send("PermissionRequest", "a")
        XCTAssertEqual(a.lights[0], .attn)
        send("PostToolUse", "a")
        XCTAssertEqual(a.lights[0], .busy)
        send("PermissionRequest", "a")
        send("PermissionDenied", "a")
        XCTAssertEqual(a.lights[0], .busy)
        send("Stop", "a")
        send("Notification", "a", notification: "idle_prompt")
        XCTAssertEqual(a.lights[0], .idle, "idle_prompt must not turn it red")
    }

    func testCapturedTrafficEndsBusy() throws {
        for body in try captureSamples() {
            _ = a.handle(try HookEvent.decode(body), config: config, now: now)
        }
        // the last sample is PreToolUse; a session without SessionStart still landed in slot 0
        XCTAssertEqual(a.lights, [.busy, .off, .off, .off])
        XCTAssertEqual(a.slots[0].session?.projectName, "agent-indicator")
    }

    func testUnknownSessionIsClaimedWithWelcome() {
        XCTAssertEqual(send("PreToolUse", "a").welcome, [0])
        XCTAssertEqual(a.lights[0], .busy)
        XCTAssertEqual(send("SessionEnd", "zzz").changed, false)
    }

    func testFourAgentsAndOverflow() {
        for (i, s) in ["a", "b", "c", "d"].enumerated() {
            XCTAssertEqual(send("SessionStart", s).welcome, [i])
        }
        send("UserPromptSubmit", "c")
        XCTAssertEqual(a.lights, [.idle, .idle, .busy, .idle])

        XCTAssertEqual(send("SessionStart", "e").welcome, [])
        now += 1
        send("SessionStart", "f")
        now += 1
        send("PreToolUse", "e")  // e is fresher than f
        XCTAssertEqual(a.overflow.map(\.sessionId), ["e", "f"])

        let fx = send("SessionEnd", "b", reason: "other")
        XCTAssertEqual(fx.welcome, [3])
        XCTAssertEqual(a.slots.map { $0.session?.sessionId }, ["a", "c", "d", "e"])
        XCTAssertEqual(a.lights[3], .busy, "arrives from overflow with its current state")
        XCTAssertEqual(a.overflow.map(\.sessionId), ["f"])
    }

    func testClearKeepsSlotWithoutWelcome() {
        send("SessionStart", "a")
        send("SessionStart", "b", cwd: "/p/y", pid: 200)
        send("SessionEnd", "b", reason: "clear")
        XCTAssertEqual(a.lights[1], .idle, "the traffic light doesn't go dark during rebinding")
        let fx = send("SessionStart", "b2", cwd: "/p/y", pid: 200, source: "clear")
        XCTAssertEqual(fx.welcome, [])
        XCTAssertEqual(a.slots[1].session?.sessionId, "b2")
        XCTAssertNil(a.slots[1].rebinding)
    }

    func testClearWhenStartOvertakesEnd() {
        send("SessionStart", "a", pid: 100)
        let fx = send("SessionStart", "a2", pid: 100, source: "clear")
        XCTAssertEqual(fx.welcome, [])
        XCTAssertEqual(a.slots[0].session?.sessionId, "a2")
        send("SessionEnd", "a", reason: "clear")
        XCTAssertEqual(a.lights, [.idle, .off, .off, .off])
    }

    func testRebindingExpires() {
        alive = [100]
        send("SessionStart", "a", pid: 100)
        send("SessionEnd", "a", reason: "clear")
        XCTAssertFalse(sweep(after: 5).changed)
        XCTAssertEqual(a.lights[0], .idle)
        XCTAssertTrue(sweep(after: 11).changed)
        XCTAssertEqual(a.lights[0], .off)
    }

    func testPinsAndPreferredSlot() {
        config.pins = ["/p/pinned": 3]
        send("SessionStart", "a", cwd: "/p/pinned/sub")
        XCTAssertNotNil(a.slots[3].session)
        send("SessionStart", "b", prefer: 2)
        XCTAssertNotNil(a.slots[2].session)
        send("SessionStart", "c", cwd: "/p/pinned")  // pin taken → first free one
        XCTAssertEqual(a.slotIndex(of: "c"), 0)
    }

    func testDeadPidReleasesSlotAndPullsOverflow() {
        alive = [1, 2, 3, 4, 5]
        for (i, s) in ["a", "b", "c", "d", "e"].enumerated() { send("SessionStart", s, pid: Int32(i + 1)) }
        alive.remove(2)
        let fx = sweep(after: 5)
        XCTAssertEqual(fx.welcome, [3])
        XCTAssertEqual(a.slots.map { $0.session?.sessionId }, ["a", "c", "d", "e"])
    }

    func testClosedMiddleAgentLeavesNoGap() {
        for s in ["a", "b", "c"] { send("SessionStart", s) }
        send("UserPromptSubmit", "c")
        send("SessionEnd", "b", reason: "prompt_input_exit")
        XCTAssertEqual(a.slots.map { $0.session?.sessionId }, ["a", "c", nil, nil])
        XCTAssertEqual(a.lights, [.idle, .busy, .off, .off], "a shifted slot keeps its state")
        XCTAssertEqual(send("SessionStart", "d").welcome, [2])
    }

    func testCompactionKeepsRebindingAndMute() {
        for (i, s) in ["a", "b", "c"].enumerated() { send("SessionStart", s, pid: Int32(i + 1)) }
        _ = a.toggleMute(slot: 2)
        send("SessionEnd", "b", reason: "clear")
        send("SessionEnd", "a", reason: "other")
        XCTAssertEqual(a.slots.map { $0.session?.sessionId }, ["b", "c", nil, nil])
        XCTAssertNotNil(a.slots[0].rebinding)
        XCTAssertTrue(a.slots[1].muted)
    }

    func testSweepFreesSeveralSlotsAtOnce() {
        alive = [1, 2, 3, 4]
        for (i, s) in ["a", "b", "c", "d"].enumerated() { send("SessionStart", s, pid: Int32(i + 1)) }
        alive = [1, 4]
        _ = sweep(after: 5)
        XCTAssertEqual(a.slots.map { $0.session?.sessionId }, ["a", "d", nil, nil])
    }

    func testBusyTimeoutAndTTL() {
        send("SessionStart", "a")
        send("PreToolUse", "a")
        _ = sweep(after: 600)
        XCTAssertEqual(a.lights[0], .busy)
        _ = sweep(after: 301)
        XCTAssertEqual(a.lights[0], .idle)
        _ = sweep(after: 8 * 3600)
        XCTAssertEqual(a.lights[0], .off)
    }

    func testEscOnPermissionPromptGoesIdle() {
        send("SessionStart", "a")
        send("PreToolUse", "a")
        send("PermissionRequest", "a")
        send("Notification", "a", notification: "permission_prompt")
        XCTAssertEqual(a.lights[0], .attn)
        XCTAssertTrue(a.interrupted("a", now: now).changed)
        XCTAssertEqual(a.lights[0], .idle)
        XCTAssertFalse(a.interrupted("a", now: now).changed)
        XCTAssertFalse(a.interrupted("unknown", now: now).changed)
    }

    func testLivePidOutlivesTTL() {
        alive = [7]
        send("SessionStart", "a", pid: 7)
        _ = sweep(after: 10 * 3600)
        XCTAssertEqual(a.lights[0], .idle, "the agent is alive — silence is no reason to go dark")
        alive = []
        _ = sweep(after: 5)
        XCTAssertEqual(a.lights[0], .off)
    }

    func testSleepDoesNotCountTowardsTTL() {
        send("SessionStart", "a")  // no pid — liveness by TTL only
        now += 9 * 3600
        a.postpone(by: 9 * 3600)
        _ = sweep(after: 5)
        XCTAssertEqual(a.lights[0], .idle)
    }

    func testMute() {
        send("SessionStart", "a")
        _ = a.toggleMute(slot: 0)
        send("PermissionRequest", "a")
        XCTAssertEqual(a.lights[0], .off)
        _ = a.toggleMute(slot: 0)
        XCTAssertEqual(a.lights[0], .attn)
    }

    func testStateStoreRoundTrip() throws {
        send("SessionStart", "a", pid: 7)
        send("PermissionRequest", "a")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentlight-test-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = StateStore(url: url)
        try store.save(a)
        XCTAssertEqual(store.load(), a)
    }
}

extension SlotAllocatorTests {
    func testProjectIsWhereAgentStartedNotCurrentShellDir() {
        send("SessionStart", "a", cwd: "/p/proj")
        send("PreToolUse", "a", cwd: "/p/proj/host")
        XCTAssertEqual(a.slots[0].session?.projectName, "proj")
    }
}

extension SlotAllocatorTests {
    /// 2026-10-16: away_summary 3 min after Stop turned an idle slot yellow.
    func testBackgroundForksDoNotWakeIdleSlot() {
        send("SessionStart", "a")
        send("UserPromptSubmit", "a")
        send("SubagentStart", "a")
        XCTAssertEqual(a.lights[0], .busy)
        send("Stop", "a")
        now += 183
        send("SubagentStart", "a")
        send("SubagentStop", "a")
        send("PreCompact", "a")
        send("PostCompact", "a")
        XCTAssertEqual(a.lights[0], .idle)
    }
}

extension SlotAllocatorTests {
    func testSlotCountFromInit() {
        a = SlotAllocator(slotCount: 6)
        for id in ["a", "b", "c", "d", "e", "f", "g"] { send("SessionStart", id) }
        XCTAssertEqual(a.lights.count, 6)
        XCTAssertEqual(a.slotIndex(of: "f"), 5)
        XCTAssertEqual(a.overflow.map(\.sessionId), ["g"])
    }

    /// Extra sessions wait in overflow.
    func testShrinkMovesExtraSessionsToOverflow() {
        a = SlotAllocator(slotCount: 6)
        for id in ["a", "b", "c", "d", "e", "f"] { send("SessionStart", id) }
        XCTAssertTrue(a.resize(to: 4, now: now).changed)
        XCTAssertEqual(a.slots.count, 4)
        XCTAssertEqual(a.slotIndex(of: "d"), 3)
        XCTAssertEqual(Set(a.overflow.map(\.sessionId)), ["e", "f"])
    }

    func testGrowPullsFreshestFromOverflow() {
        for id in ["a", "b", "c", "d"] { send("SessionStart", id) }
        send("SessionStart", "e")
        now += 10
        send("SessionStart", "f")
        let fx = a.resize(to: 5, now: now)
        XCTAssertEqual(fx.welcome, [4])
        XCTAssertEqual(a.slotIndex(of: "f"), 4)
        XCTAssertEqual(a.overflow.map(\.sessionId), ["e"])
        XCTAssertFalse(a.resize(to: 5, now: now).changed)
    }

    func testPinBeyondSlotCountIsIgnored() {
        config.pins = ["/p/x": 5]
        send("SessionStart", "a")
        XCTAssertEqual(a.slotIndex(of: "a"), 0)
    }

    // MARK: - Hidden sessions (bg-spare, shell tab)

    func testBackgroundSessionGetsNoSlot() {
        let bg: Set<Int32> = [77]
        func send(_ name: String, _ sid: String, pid: Int32? = nil, reason: String? = nil) {
            var e = HookEvent(name: name, sessionId: sid, cwd: "/p/x")
            e.reason = reason
            if let pid { e.agentlight = HookExtras(claudePid: pid) }
            _ = a.handle(e, config: config, now: now, roles: .init(isHidden: { bg.contains($0) }))
        }
        send("SessionStart", "spare", pid: 77)
        send("UserPromptSubmit", "spare")
        send("PreToolUse", "spare")
        XCTAssertEqual(a.lights, [.off, .off, .off, .off])
        XCTAssertTrue(a.isHidden("spare"))
        XCTAssertEqual(a.background.first?.state, .busy)

        send("SessionStart", "term", pid: 5)
        XCTAssertEqual(a.slotIndex(of: "term"), 0)

        send("SessionEnd", "spare", reason: "other")
        XCTAssertTrue(a.background.isEmpty)
        XCTAssertEqual(a.lights, [.idle, .off, .off, .off])
    }

    func testSweepHidesBackgroundSessionsAlreadyInSlots() {
        send("SessionStart", "a", pid: 1)
        send("SessionStart", "spare", pid: 2)
        send("SessionStart", "c", pid: 3)
        alive = [1, 2, 3]
        now += 1
        let fx = a.sweep(config: config, now: now, isAlive: { self.alive.contains($0) }, roles: .init(isHidden: { $0 == 2 }))
        XCTAssertTrue(fx.changed)
        XCTAssertEqual(a.slotIndex(of: "c"), 1, "slots shifted without a gap")
        XCTAssertTrue(a.isHidden("spare"))

        alive = [1, 3]
        _ = sweep(after: 5)
        XCTAssertTrue(a.background.isEmpty, "a dead background process is forgotten")
    }

    func testOldStateJSONWithoutBackgroundDecodes() throws {
        send("SessionStart", "a")
        var json = try JSONSerialization.jsonObject(with: StateStore.encoder.encode(a)) as! [String: Any]
        json.removeValue(forKey: "background")
        let data = try JSONSerialization.data(withJSONObject: json)
        let loaded = try StateStore.decoder.decode(SlotAllocator.self, from: data)
        XCTAssertEqual(loaded.slotIndex(of: "a"), 0)
        XCTAssertTrue(loaded.background.isEmpty)
    }

    func testSweepReturnsHiddenSessionThatHasAWindow() {
        let bg: Set<Int32> = [2]
        func send(_ name: String, _ sid: String, pid: Int32) {
            var e = HookEvent(name: name, sessionId: sid, cwd: "/p/x")
            e.agentlight = HookExtras(claudePid: pid)
            _ = a.handle(e, config: config, now: now, roles: .init(isHidden: { bg.contains($0) }))
        }
        send("SessionStart", "a", pid: 1)
        send("SessionStart", "fork", pid: 2)
        send("UserPromptSubmit", "fork", pid: 2)
        XCTAssertTrue(a.isHidden("fork"))

        // an agent view spare was given a job — now it's a regular background session
        alive = [1, 2]
        now += 1
        let fx = a.sweep(config: config, now: now, isAlive: { self.alive.contains($0) }, roles: .none)
        XCTAssertEqual(fx.welcome, [1])
        XCTAssertTrue(a.background.isEmpty)
        XCTAssertEqual(a.slotIndex(of: "fork"), 1)
        XCTAssertEqual(a.lights, [.idle, .busy, .off, .off])
    }

    func testDispatchedSpareShowsOnItsNextEvent() {
        var hidden: Set<Int32> = [7]
        func send(_ name: String) {
            var e = HookEvent(name: name, sessionId: "spare", cwd: "/p/x")
            e.agentlight = HookExtras(claudePid: 7)
            _ = a.handle(e, config: config, now: now, roles: .init(isHidden: { hidden.contains($0) }))
        }
        send("SessionStart")
        XCTAssertTrue(a.isHidden("spare"))
        hidden = []  // spare:true disappeared from the registry
        send("UserPromptSubmit")
        XCTAssertFalse(a.isHidden("spare"))
        XCTAssertEqual(a.lights, [.busy, .off, .off, .off])
    }

    func testForkTakesOverSlotOfItsParkedTab() {
        // tab 1 (slot 1) sent its session to the background: process 1 is the shell, the fork is pid 9
        send("SessionStart", "x", pid: 5)
        send("SessionStart", "tab", pid: 1)
        send("SessionStart", "y", pid: 6)
        let roles = SlotAllocator.Roles(isHidden: { $0 == 1 }, parkedShell: { $0 == 9 ? 1 : nil })
        var e = HookEvent(name: "SessionStart", sessionId: "fork", cwd: "/p/x")
        e.agentlight = HookExtras(claudePid: 9)
        let fx = a.handle(e, config: config, now: now, roles: roles)
        XCTAssertEqual(fx.welcome, [], "the same conversation continues — no welcome")
        XCTAssertEqual(a.slotIndex(of: "fork"), 1)
        XCTAssertTrue(a.isHidden("tab"))
        XCTAssertEqual(a.slotIndex(of: "y"), 2)
    }

    func testSweepHandsParkedTabSlotToFork() {
        // the fork took a slot before the tab wrote parkedJobId
        send("SessionStart", "tab", pid: 1)
        send("SessionStart", "x", pid: 5)
        send("SessionStart", "fork", pid: 9)
        send("UserPromptSubmit", "fork")
        _ = a.handle(HookEvent(name: "SessionStart", sessionId: "z", cwd: "/p/x"), config: config, now: now)
        _ = a.toggleMute(slot: 0)
        alive = [1, 5, 9]
        now += 1
        let roles = SlotAllocator.Roles(isHidden: { $0 == 1 }, parkedShell: { $0 == 9 ? 1 : nil })
        _ = a.sweep(config: config, now: now, isAlive: { self.alive.contains($0) }, roles: roles)
        XCTAssertEqual(a.slotIndex(of: "fork"), 0, "the tab's lamp went to the fork")
        XCTAssertTrue(a.slots[0].muted, "the tab's mute was kept")
        XCTAssertEqual(a.slotIndex(of: "x"), 1)
        XCTAssertEqual(a.slotIndex(of: "z"), 2, "slots shifted without a gap")
        XCTAssertEqual(a.lights, [.off, .idle, .idle, .off])
        XCTAssertTrue(a.isHidden("tab"))
    }
}
