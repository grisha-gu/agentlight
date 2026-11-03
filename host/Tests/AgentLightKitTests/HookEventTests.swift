import Foundation
import XCTest
@testable import AgentLightKit

/// Real hook bodies captured 2026-10-05 (tools/hook-capture/samples.jsonl).
func captureSamples() throws -> [Data] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("tools/hook-capture/samples.jsonl")
    let text = try String(contentsOf: url, encoding: .utf8)
    return try text.split(separator: "\n").map { line in
        let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        return try JSONSerialization.data(withJSONObject: obj["body_json"]!)
    }
}

final class HookEventTests: XCTestCase {
    func testDecodesAllCapturedBodies() throws {
        let bodies = try captureSamples()
        XCTAssertEqual(bodies.count, 23)
        let events = try bodies.map(HookEvent.decode)
        XCTAssertEqual(Set(events.map(\.name)),
                       ["PreToolUse", "PostToolUse", "Stop", "Notification", "UserPromptSubmit"])
        XCTAssertTrue(events.allSatisfy { $0.sessionId == "a8d8ac92-2300-4423-b75d-7eadcf2fafcb" })
        XCTAssertEqual(events.first { $0.name == "Notification" }?.notificationType, "idle_prompt")
        XCTAssertEqual(events[0].cwd, "$HOME/projects/agent-indicator")
    }

    func testOnlyNameAndSessionAreRequired() throws {
        let e = try HookEvent.decode(Data(#"{"hook_event_name":"Stop","session_id":"s","cwd":42,"new_field":[1]}"#.utf8))
        XCTAssertEqual(e.name, "Stop")
        XCTAssertNil(e.cwd)
        XCTAssertThrowsError(try HookEvent.decode(Data(#"{"hook_event_name":"Stop"}"#.utf8)))
    }

    func testSessionEndReasonAndExtras() throws {
        let e = try HookEvent.decode(Data("""
        {"hook_event_name":"SessionStart","session_id":"s","source":"clear",
         "agentlight":{"claude_pid":123,"prefer_slot":2,"terminal":{"tty":"/dev/ttys004","term_program":"Apple_Terminal"}}}
        """.utf8))
        XCTAssertEqual(e.source, "clear")
        XCTAssertEqual(e.agentlight?.claudePid, 123)
        XCTAssertEqual(e.agentlight?.preferSlot, 2)
        XCTAssertEqual(e.agentlight?.terminal?.tty, "/dev/ttys004")

        let end = try HookEvent.decode(Data(#"{"hook_event_name":"SessionEnd","session_id":"s","end_reason":"clear"}"#.utf8))
        XCTAssertEqual(end.reason, "clear")
    }

    func testTransitions() {
        func t(_ name: String, notification: String? = nil, reason: String? = nil) -> Transition {
            var e = HookEvent(name: name, sessionId: "s")
            e.notificationType = notification
            e.reason = reason
            return SlotStateMachine.transition(for: e)
        }
        XCTAssertEqual(t("UserPromptSubmit"), .set(.busy))
        XCTAssertEqual(t("PreToolUse"), .set(.busy))
        XCTAssertEqual(t("PermissionDenied"), .set(.busy))
        XCTAssertEqual(t("PermissionRequest"), .set(.attn))
        XCTAssertEqual(t("StopFailure"), .set(.attn))
        XCTAssertEqual(t("Stop"), .set(.idle))
        XCTAssertEqual(t("Notification", notification: "permission_prompt"), .set(.attn))
        XCTAssertEqual(t("Notification", notification: "agent_completed"), .set(.idle))
        XCTAssertEqual(t("Notification", notification: "idle_prompt"), .ignore)
        XCTAssertEqual(t("SessionEnd", reason: "clear"), .end(rebind: true))
        XCTAssertEqual(t("SessionEnd", reason: "logout"), .end(rebind: false))
        XCTAssertEqual(t("SomethingNew"), .ignore)
    }
}

final class DeviceProtocolTests: XCTestCase {
    func testHIDEncoding() {
        XCTAssertEqual(DeviceCommand.setAll([.idle, .busy, .attn, .off]).hidReport.prefix(6), [0x02, 1, 2, 3, 0, 0])
        XCTAssertEqual(DeviceCommand.ping(seq: 0x0403_0201).hidReport.prefix(5), [0x05, 1, 2, 3, 4])
        XCTAssertEqual(DeviceCommand.welcome(slot: nil).hidReport.prefix(2), [0x03, 0xFF])
        XCTAssertEqual(DeviceCommand.config(busyPulse: false, idlePulse: true).hidReport[1], 0b100)
        XCTAssertEqual(DeviceCommand.config(busyPulse: true, idlePulse: false).asciiLine, "CONFIG busy_pulse=1 idle_pulse=0")
        XCTAssertEqual(DeviceCommand.hello.hidReport.count, 64)
    }

    func testASCIIEncoding() {
        XCTAssertEqual(DeviceCommand.setAll([.idle, .busy, .attn, .off]).asciiLine, "SETALL idle busy attn off")
        XCTAssertEqual(DeviceCommand.welcome(slot: nil).asciiLine, "WELCOME ALL")
        XCTAssertEqual(DeviceCommand.raw([255, 0, 128]).asciiLine, "RAW ff 00 80")
    }

    func testHIDEvents() {
        var ready = [UInt8](repeating: 0, count: 64)
        ready[0...14] = [0x81, 1, 4, 1, 0, 2, 0xE6, 0x65, 0x54, 0xA1, 0x4B, 0x61, 0x0F, 0x23, 1]
        XCTAssertEqual(DeviceEvent(hidReport: ready),
                       .ready(DeviceIdentity(proto: 1, slots: 4, firmware: "1.0.2", uid: "E66554A14B610F23"), powerOn: true))
        ready[14] = 0
        XCTAssertEqual(DeviceEvent(hidReport: ready),
                       .ready(DeviceIdentity(proto: 1, slots: 4, firmware: "1.0.2", uid: "E66554A14B610F23"), powerOn: false))
        // fw before 0.6.0 doesn't fill byte 14 — it has no power switch
        ready[3...5] = [0, 5, 0]
        XCTAssertEqual(DeviceEvent(hidReport: ready),
                       .ready(DeviceIdentity(proto: 1, slots: 4, firmware: "0.5.0", uid: "E66554A14B610F23"), powerOn: true))
        XCTAssertEqual(DeviceEvent(hidReport: [0x85, 0]), .power(on: false))
        XCTAssertEqual(DeviceEvent(hidReport: [0x85, 1]), .power(on: true))
        XCTAssertEqual(DeviceEvent(hidReport: [0x82, 2, 2, 0, 0, 0, 0]), .button(slot: 2, .long))
        var pong = [UInt8](repeating: 0, count: 64)
        pong[0...9] = [0x83, 42, 0, 0, 0, 0x10, 0x27, 0, 0, 1]
        XCTAssertEqual(DeviceEvent(hidReport: pong), .pong(seq: 42, uptimeMs: 10000, watchdogTripped: true))
    }

    func testASCIIEvents() {
        // this is how the current firmware answers (firmware/src/main.c)
        XCTAssertEqual(DeviceEvent(asciiLine: "OK agentlight proto=1 fw=0.6.0 slots=4 uid=E66554A14B610F23 power=off\r"),
                       .ready(DeviceIdentity(proto: 1, slots: 4, firmware: "0.6.0", uid: "E66554A14B610F23"), powerOn: false))
        XCTAssertEqual(DeviceEvent(asciiLine: "OK agentlight proto=1 fw=0.1.0 slots=4 uid=E66554A14B610F23"),
                       .ready(DeviceIdentity(proto: 1, slots: 4, firmware: "0.1.0", uid: "E66554A14B610F23"), powerOn: true))
        XCTAssertEqual(DeviceEvent(asciiLine: "!POWER off"), .power(on: false))
        XCTAssertEqual(DeviceEvent(asciiLine: "!POWER on"), .power(on: true))
        XCTAssertEqual(DeviceEvent(asciiLine: "!READY proto=1 fw=1.0.0 slots=4 uid=AB")?.isReady, true)
        XCTAssertEqual(DeviceEvent(asciiLine: "!BTN 2 press t=135022"), .button(slot: 2, .press))
        XCTAssertEqual(DeviceEvent(asciiLine: "OK PONG 42 uptime=135022 wd=0"),
                       .pong(seq: 42, uptimeMs: 135022, watchdogTripped: false))
        XCTAssertEqual(DeviceEvent(asciiLine: "!WD trip"), .watchdogTrip)
        XCTAssertNil(DeviceEvent(asciiLine: "OK"))
        XCTAssertNil(DeviceEvent(asciiLine: "ERR unknown command"))
    }
}

extension DeviceEvent {
    var isReady: Bool { if case .ready = self { true } else { false } }
}
