import Foundation
import XCTest
@testable import AgentLightKit

final class HookInstallerTests: XCTestCase {
    let installer = HookInstaller(port: 48879, cliPath: "/Applications/AgentLight.app/Contents/MacOS/agentlight")

    let foreign: [String: Any] = [
        "model": "opus",
        "hooks": [
            "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "~/bin/guard.sh"]]]],
        ],
    ]

    func testInstallKeepsForeignHooksAndIsIdempotent() throws {
        let once = installer.install(into: foreign)
        let twice = installer.install(into: once)
        XCTAssertEqual(NSDictionary(dictionary: once), NSDictionary(dictionary: twice))
        XCTAssertEqual(once["model"] as? String, "opus")

        let pre = (once["hooks"] as! [String: Any])["PreToolUse"] as! [[String: Any]]
        XCTAssertEqual(pre.count, 2)
        XCTAssertEqual(pre[0]["matcher"] as? String, "Bash")
        XCTAssertEqual(HookInstaller.installedEvents(in: once), Set(HookInstaller.httpEvents + ["SessionStart"]))

        let start = (once["hooks"] as! [String: Any])["SessionStart"] as! [[String: Any]]
        let cmd = (start[0]["hooks"] as! [[String: Any]])[0]
        XCTAssertEqual(cmd["command"] as? String, "'/Applications/AgentLight.app/Contents/MacOS/agentlight' hook")
    }

    func testUninstallRestoresOriginal() {
        let back = installer.uninstall(from: installer.install(into: foreign))
        XCTAssertEqual(NSDictionary(dictionary: back), NSDictionary(dictionary: foreign))
        XCTAssertNil(installer.uninstall(from: installer.install(into: [:]))["hooks"])
    }

    func testUninstallRemovesOldPortToo() {
        let old = HookInstaller(port: 50000, cliPath: "/old/agentlight").install(into: foreign)
        XCTAssertEqual(NSDictionary(dictionary: installer.uninstall(from: old)), NSDictionary(dictionary: foreign))
    }
}

final class HTTPParseTests: XCTestCase {
    func testPipelinedRequests() {
        var buf = Data("POST /hook HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}GET /status HTTP/1.1\r\nHost: x\r\n\r\nPOST /hook HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\"".utf8)
        let a = HTTPServer.parse(&buf)
        XCTAssertEqual(a?.path, "/hook")
        XCTAssertEqual(a?.body, Data("{}".utf8))
        XCTAssertEqual(HTTPServer.parse(&buf)?.path, "/status")
        XCTAssertNil(HTTPServer.parse(&buf), "the body hasn't fully arrived yet")
        buf.append(Data(":true}".utf8))
        XCTAssertEqual(HTTPServer.parse(&buf)?.body.count, 10)
        XCTAssertTrue(buf.isEmpty)
    }
}
