import Foundation
import XCTest
@testable import AgentLightKit

final class TerminalFocusTests: XCTestCase {
    let order = ["tmux", "native", "new_window"]

    func session(_ term: TerminalRef?, pid: Int32? = 42) -> SessionRecord {
        var s = SessionRecord(sessionId: "sid", cwd: "/p/it's", state: .idle, at: Date())
        s.terminal = term
        s.claudePid = pid
        return s
    }

    func testTerminalAppByTTY() {
        let s = session(TerminalRef(termProgram: "Apple_Terminal", appBundleId: "com.apple.Terminal", tty: "/dev/ttys004"))
        XCTAssertEqual(TerminalFocus.plan(for: s, order: order) { _ in true }, [.terminalTab(tty: "/dev/ttys004")])
    }

    func testTmuxGoesFirstThenTerminalTab() {
        let s = session(TerminalRef(termProgram: "tmux", appBundleId: "com.apple.Terminal", tmuxPane: "%3",
                                    tmuxSocket: "/tmp/tmux-501/default", tty: "/dev/ttys009"))
        XCTAssertEqual(TerminalFocus.plan(for: s, order: order) { _ in true },
                       [.tmux(pane: "%3", socket: "/tmp/tmux-501/default"), .terminalTab(tty: "/dev/ttys009")])
    }

    func testOtherTerminalIsJustActivated() {
        let s = session(TerminalRef(termProgram: "ghostty", appBundleId: "com.mitchellh.ghostty", tty: "/dev/ttys001"))
        XCTAssertEqual(TerminalFocus.plan(for: s, order: order) { _ in true }, [.activateApp(bundleId: "com.mitchellh.ghostty")])
    }

    func testResumeOnlyWhenAgentIsDead() {
        let s = session(TerminalRef(appBundleId: "com.apple.Terminal", tty: "/dev/ttys004"))
        XCTAssertEqual(TerminalFocus.plan(for: s, order: order) { _ in false },
                       [.terminalTab(tty: "/dev/ttys004"), .resume(cwd: "/p/it's", sessionId: "sid")])
        XCTAssertEqual(TerminalFocus.plan(for: session(nil, pid: nil), order: order) { _ in false }, [])
    }

    func testShellQuoting() {
        XCTAssertEqual(TerminalFocus.launchCommand(cwd: "/p/it's here", slot: 2),
                       "cd '/p/it'\\''s here' && AGENTLIGHT_PREFER_SLOT=2 claude")
    }
}
