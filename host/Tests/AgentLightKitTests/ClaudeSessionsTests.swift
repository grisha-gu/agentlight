import Foundation
import XCTest
@testable import AgentLightKit

final class ClaudeSessionsTests: XCTestCase {
    // как в ~/.claude/sessions на 2.1.316 (лишние поля урезаны)
    let parked = #"{"pid":93193,"sessionId":"afcf5dfd-d44e","kind":"interactive","status":"idle","parkedJobId":"d662e5ff"}"#
    let fork = #"{"pid":76609,"sessionId":"2748614f-ca8e","kind":"bg","name":"Публикация проекта в brew","jobId":"d662e5ff","status":"idle"}"#
    let spare = #"{"pid":81348,"sessionId":"9a8cdd56-f8ea","kind":"bg","name":"9a8cdd56","jobId":"9a8cdd56","spare":true}"#
    let plain = #"{"pid":77507,"sessionId":"64e1ad2d-6c1b","kind":"interactive","status":"busy"}"#

    func registry() throws -> ClaudeSessions {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        for (name, body) in [("93193", parked), ("76609", fork), ("81348", spare), ("77507", plain), ("1", "{oops")] {
            try Data(body.utf8).write(to: dir.appendingPathComponent(name + ".json"))
        }
        try Data("x".utf8).write(to: dir.appendingPathComponent("77507.abc.key"))
        return ClaudeSessions.load(from: dir)
    }

    func testLoadSkipsGarbage() throws {
        let r = try registry()
        XCTAssertEqual(Set(r.entries.keys), [93193, 76609, 81348, 77507])
        XCTAssertEqual(r.entries[76609]?.jobId, "d662e5ff")
        XCTAssertTrue(r.entries[81348]?.spare ?? false)
    }

    func testHidden() throws {
        let r = try registry()
        let noArgs: (Int32) -> [String]? = { _ in nil }
        XCTAssertTrue(r.isHidden(93193, arguments: noArgs), "вкладка-оболочка")
        XCTAssertTrue(r.isHidden(81348, arguments: noArgs), "заготовка в agent view")
        XCTAssertFalse(r.isHidden(76609, arguments: noArgs), "фоновая сессия с задачей")
        XCTAssertFalse(r.isHidden(77507, arguments: noArgs))
        // заготовка ещё не занята: файла нет, решает argv
        XCTAssertTrue(r.isHidden(500, arguments: { _ in ["claude", "bg-spare", "--bg-spare", "/tmp/x.sock"] }))
        XCTAssertFalse(r.isHidden(500, arguments: { _ in ["claude"] }))
        // занятая и отданная под задачу заготовка: argv прежний, но файл решает
        var e = r.entries[81348]!
        e.spare = false
        let dispatched = ClaudeSessions(entries: [e.pid: e])
        XCTAssertFalse(dispatched.isHidden(81348, arguments: { _ in ["claude", "--bg-spare"] }))
    }

    func testParkedShell() throws {
        let r = try registry()
        XCTAssertEqual(r.parkedShell(of: 76609), 93193)
        XCTAssertNil(r.parkedShell(of: 81348))
        XCTAssertNil(r.parkedShell(of: 77507))
        XCTAssertNil(r.parkedShell(of: 4242))
    }

    func testAttachTarget() throws {
        let e = try XCTUnwrap(try registry().entries[76609])
        XCTAssertEqual(ClaudeSessions.attachArgument(["/x/claude", "attach", "d662e5ff"]), "d662e5ff")
        XCTAssertNil(ClaudeSessions.attachArgument(["claude", "agents"]))
        XCTAssertNil(ClaudeSessions.attachArgument(["claude", "attach"]))
        XCTAssertTrue(ClaudeSessions.attachTarget("d662e5ff", matches: e))
        XCTAssertTrue(ClaudeSessions.attachTarget("2748614f", matches: e))
        XCTAssertTrue(ClaudeSessions.attachTarget("публикация", matches: e))
        XCTAssertFalse(ClaudeSessions.attachTarget("9a8cdd56", matches: e))
        XCTAssertFalse(ClaudeSessions.attachTarget("", matches: e))
    }

    func testAttachCommand() {
        XCTAssertEqual(TerminalFocus.attachCommand(cwd: "/p/it's", job: "d662e5ff"),
                       #"cd '/p/it'\''s' && claude attach 'd662e5ff'"#)
        XCTAssertEqual(TerminalFocus.attachCommand(cwd: nil, job: "d662e5ff"), "claude attach 'd662e5ff'")
    }
}
