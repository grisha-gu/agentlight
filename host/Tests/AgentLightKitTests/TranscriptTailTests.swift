import Foundation
import XCTest
@testable import AgentLightKit

final class TranscriptTailTests: XCTestCase {
    // формы строк — из настоящего transcript-а Claude Code 2.1.295
    let interruptTool = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]},"sessionId":"s"}"#
    let interruptPlain = #"{"type":"user","message":{"role":"user","content":"[Request interrupted by user]"},"sessionId":"s"}"#
    let toolOutput = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"grep: [Request interrupted by user for tool use]"}]}}"#
    let assistant = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"[Request interrupted by user"}]}}"#

    func testFindsInterruptLines() {
        var t = TranscriptTail()
        XCTAssertTrue(t.feed(Data((interruptTool + "\n").utf8)))
        XCTAssertTrue(t.feed(Data((interruptPlain + "\n").utf8)))
    }

    func testIgnoresMarkerInsideToolOutputAndAssistantText() {
        var t = TranscriptTail()
        XCTAssertFalse(t.feed(Data((toolOutput + "\n" + assistant + "\n").utf8)))
    }

    func testLineSplitAcrossWrites() {
        var t = TranscriptTail()
        let bytes = Data((interruptTool + "\n").utf8)
        let cut = bytes.count / 2
        XCTAssertFalse(t.feed(bytes.prefix(cut)))
        XCTAssertTrue(t.feed(bytes.suffix(from: cut)))
    }
}
