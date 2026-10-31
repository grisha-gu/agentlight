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
        XCTAssertEqual(a.lights[0], .idle, "idle_prompt не должен красить в красный")
    }

    func testCapturedTrafficEndsBusy() throws {
        for body in try captureSamples() {
            _ = a.handle(try HookEvent.decode(body), config: config, now: now)
        }
        // последний образец — PreToolUse; сессия без SessionStart всё равно заехала в слот 0
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
        send("PreToolUse", "e")  // e свежее f
        XCTAssertEqual(a.overflow.map(\.sessionId), ["e", "f"])

        let fx = send("SessionEnd", "b", reason: "other")
        XCTAssertEqual(fx.welcome, [3])
        XCTAssertEqual(a.slots.map { $0.session?.sessionId }, ["a", "c", "d", "e"])
        XCTAssertEqual(a.lights[3], .busy, "из overflow приезжает с актуальным состоянием")
        XCTAssertEqual(a.overflow.map(\.sessionId), ["f"])
    }

    func testClearKeepsSlotWithoutWelcome() {
        send("SessionStart", "a")
        send("SessionStart", "b", cwd: "/p/y", pid: 200)
        send("SessionEnd", "b", reason: "clear")
        XCTAssertEqual(a.lights[1], .idle, "во время rebinding светофор не гаснет")
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
        send("SessionStart", "c", cwd: "/p/pinned")  // пин занят → первый свободный
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
        XCTAssertEqual(a.lights, [.idle, .busy, .off, .off], "сдвинутый слот хранит состояние")
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
        XCTAssertEqual(a.lights[0], .idle, "агент жив — молчание не повод гасить")
        alive = []
        _ = sweep(after: 5)
        XCTAssertEqual(a.lights[0], .off)
    }

    func testSleepDoesNotCountTowardsTTL() {
        send("SessionStart", "a")  // без pid — живость только по TTL
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
    /// 2026-10-16: away_summary через 3 мин после Stop покрасил простаивающий слот в жёлтый.
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

    /// Лишние сессии ждут в overflow.
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
}
