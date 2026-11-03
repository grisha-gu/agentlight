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
    }

    func testEnvironmentOfOwnProcess() throws {
        // macOS doesn't expose env for platform binaries (/bin/sleep), but does for claude
        let env = try XCTUnwrap(TerminalCapture.environment(of: getpid()))
        let mine = ProcessInfo.processInfo.environment
        XCTAssertFalse(env.isEmpty)
        XCTAssertEqual(env["PATH"], mine["PATH"])
        XCTAssertEqual(env["HOME"], mine["HOME"])
    }
}
