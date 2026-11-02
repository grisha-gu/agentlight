import Foundation
import XCTest
@testable import AgentLightKit

final class ProcessLookupTests: XCTestCase {
    func testOwnProcessInfo() {
        XCTAssertEqual(TerminalCapture.cwd(of: getpid()), FileManager.default.currentDirectoryPath)
        XCTAssertNotNil(TerminalCapture.argv0(getpid()))
        XCTAssertFalse(TerminalCapture.isClaude(getpid()))
    }

    func testArgumentsOfOwnProcess() {
        let args = TerminalCapture.arguments(of: getpid())
        XCTAssertEqual(args, CommandLine.arguments)
        XCTAssertFalse(TerminalCapture.isBackground(getpid()))
    }

    func testBackgroundByParentAndSpareFlag() throws {
        // родитель с --bg-pty-host в argv, как у демона Claude Code
        let host = Process()
        host.executableURL = URL(fileURLWithPath: "/bin/sh")
        host.arguments = ["-c", "sleep 30 & echo $!; wait", "--bg-pty-host"]
        let out = Pipe()
        host.standardOutput = out
        try host.run()
        defer { host.terminate() }
        let line = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
        let child = try XCTUnwrap(Int32(line.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(child, SIGTERM) }
        XCTAssertTrue(TerminalCapture.isBackground(child))
        XCTAssertFalse(TerminalCapture.isBackground(host.processIdentifier))

        let spare = Process()
        spare.executableURL = URL(fileURLWithPath: "/bin/sh")
        spare.arguments = ["-c", "sleep 30; :", "--bg-spare"]
        try spare.run()
        defer { spare.terminate() }
        XCTAssertTrue(TerminalCapture.isBackground(spare.processIdentifier))
    }

    func testSpawnedByFromDaemonArguments() {
        let args = ["/Users/u/.local/bin/claude", "daemon", "run", "--origin", "transient",
                    "--spawned-by", #"{"label":"claude","cwd":"/Users/u/p","pid":93193}"#]
        XCTAssertEqual(TerminalCapture.spawnedBy(args), 93193)
        XCTAssertNil(TerminalCapture.spawnedBy(["claude", "daemon", "run"]))
        XCTAssertNil(TerminalCapture.spawnedBy(["claude", "--spawned-by", "garbage"]))
        XCTAssertNil(TerminalCapture.spawnedBy(["claude", "--spawned-by"]))
    }

    func testEnvironmentOfOwnProcess() throws {
        // у платформенных бинарников (/bin/sleep) macOS env не отдаёт, у claude — отдаёт
        let env = try XCTUnwrap(TerminalCapture.environment(of: getpid()))
        let mine = ProcessInfo.processInfo.environment
        XCTAssertFalse(env.isEmpty)
        XCTAssertEqual(env["PATH"], mine["PATH"])
        XCTAssertEqual(env["HOME"], mine["HOME"])
        XCTAssertNil(TerminalCapture.windowOwner(of: getpid()))
    }
}
