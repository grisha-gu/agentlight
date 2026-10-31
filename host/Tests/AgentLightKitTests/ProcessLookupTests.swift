import Foundation
import XCTest
@testable import AgentLightKit

final class ProcessLookupTests: XCTestCase {
    func testOwnProcessInfo() {
        XCTAssertEqual(TerminalCapture.cwd(of: getpid()), FileManager.default.currentDirectoryPath)
        XCTAssertNotNil(TerminalCapture.argv0(getpid()))
        XCTAssertFalse(TerminalCapture.isClaude(getpid()))
    }
}
