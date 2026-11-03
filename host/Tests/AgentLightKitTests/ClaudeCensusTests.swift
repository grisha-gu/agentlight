import Foundation
import XCTest
@testable import AgentLightKit

final class ClaudeCensusTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    // all processes started before the snapshot, the snapshot is at t0
    lazy var before: (Int32) -> Date? = { [t0] _ in t0 - 100 }

    func entry(_ pid: Int32, kind: String? = "interactive", job: String? = nil, parked: String? = nil,
               spare: Bool = false, modified: Date? = nil) -> ClaudeSessions.Entry {
        ClaudeSessions.Entry(pid: pid, sessionId: "s\(pid)", kind: kind, jobId: job, parkedJobId: parked,
                             spare: spare, name: nil, version: "2.1.316", modifiedAt: modified ?? t0 - 50)
    }

    func registry(_ es: ClaudeSessions.Entry...) -> ClaudeSessions {
        ClaudeSessions(entries: Dictionary(uniqueKeysWithValues: es.map { ($0.pid, $0) }))
    }

    func list(_ pids: Int32...) -> ClaudeAgentsList {
        ClaudeAgentsList(items: Dictionary(uniqueKeysWithValues: pids.map { ($0, .init(pid: $0)) }), takenAt: t0)
    }

    func census(_ r: ClaudeSessions, _ l: ClaudeAgentsList?, argv: [Int32: [String]] = [:]) -> ClaudeCensus {
        ClaudeCensus(registry: r, listed: l, arguments: { argv[$0] }, startedAt: before)
    }

    func testParseAgentsJSON() {
        let json = #"[{"pid":65945,"cwd":"/p","kind":"interactive","sessionId":"7cf6","status":"idle"},{"pid":76609,"id":"d662e5ff","kind":"background","state":"blocked"}]"#
        let l = ClaudeAgentsList.parse(Data(json.utf8), takenAt: t0)
        XCTAssertEqual(l?.items.keys.sorted(), [65945, 76609])
        XCTAssertEqual(l?.items[76609]?.id, "d662e5ff")
        XCTAssertEqual(ClaudeAgentsList.parse(Data("[]".utf8), takenAt: t0)?.items.count, 0)
        XCTAssertNil(ClaudeAgentsList.parse(Data(#"{"sessions":[]}"#.utf8), takenAt: t0), "the format changed")
        XCTAssertNil(ClaudeAgentsList.parse(Data(#"[{"session":"x"}]"#.utf8), takenAt: t0))
    }

    func testAgreementKeepsRegistryDecisions() {
        let r = registry(entry(1, parked: "j9"), entry(9, kind: "bg", job: "j9"), entry(5, kind: "bg", job: "j5", spare: true),
                         entry(7))
        let c = census(r, list(9, 7))
        XCTAssertTrue(c.isHidden(1))
        XCTAssertTrue(c.isHidden(5))
        XCTAssertFalse(c.isHidden(9))
        XCTAssertFalse(c.isHidden(7))
        XCTAssertEqual(c.parkedShell(of: 9), 1)
        XCTAssertEqual(c.problems(among: [1, 5, 7, 9]), [])
    }

    func testRenamedFieldsAreCaughtByList() {
        // Claude Code renamed parkedJobId and spare: the registry sees everyone as regular sessions
        let r = registry(entry(1), entry(9, kind: "bg", job: "j9"), entry(5, kind: "bg", job: "j5"))
        let c = census(r, list(9))
        XCTAssertTrue(c.isHidden(1), "the list hides the shell")
        XCTAssertTrue(c.isHidden(5), "the list hides the spare")
        XCTAssertNil(c.parkedShell(of: 9), "slot handover doesn't work without the registry — the lamp takes a new slot")
        XCTAssertEqual(c.problems(among: [1, 5, 9]).count, 2)
        XCTAssertTrue(c.problems(among: [1])[0].contains("doesn't see"))
    }

    func testListRevealsWhatRegistryWronglyHides() {
        let r = registry(entry(5, kind: "bg", job: "j5", spare: true))
        let c = census(r, list(5))
        XCTAssertFalse(c.isHidden(5))
        XCTAssertTrue(c.problems(among: [5])[0].contains("sees it"))
    }

    func testStaleSnapshotDefersToRegistry() {
        // the spare was given a job after the snapshot: the file was rewritten later — the snapshot doesn't count
        let r = registry(entry(5, kind: "bg", job: "j5", modified: t0 + 3))
        let c = census(r, list())
        XCTAssertFalse(c.isHidden(5))
        XCTAssertEqual(c.problems(among: [5]), [])
        // a process younger than the snapshot — same
        let young = ClaudeCensus(registry: registry(entry(6, kind: "bg", job: "j6", spare: true)), listed: list(6),
                                 arguments: { _ in nil }, startedAt: { [t0] _ in t0 + 1 })
        XCTAssertTrue(young.isHidden(6))
    }

    func testListNeverHidesProcessesItCannotVouchFor() {
        // a process with no registry entry that isn't a spare (a foreign SDK, a new kind of session) — don't hide
        let c = census(registry(entry(7)), list(7))
        XCTAssertFalse(c.isHidden(42))
        // an unclaimed spare: no file, argv --bg-spare
        let spare = census(registry(entry(7)), list(7), argv: [43: ["claude", "--bg-spare", "/x.sock"]])
        XCTAssertTrue(spare.isHidden(43))
    }

    func testMissingRegistryDoesNotHideDispatchedSpares() {
        // the registry is gone (other location/format), and an agent view job lives in a --bg-spare process:
        // without a cross-check — show; with one — the list sees it
        let argv: [Int32: [String]] = [43: ["claude", "--bg-spare", "/x.sock"]]
        XCTAssertFalse(census(ClaudeSessions(), nil, argv: argv).isHidden(43))
        let c = census(ClaudeSessions(), list(43, 7), argv: argv)
        XCTAssertFalse(c.isHidden(43))
        XCTAssertTrue(c.problems(among: [43])[0].contains("missing 2 of 2"))
    }

    func testNoSnapshotMeansRegistryOnly() {
        let c = census(registry(entry(1, parked: "j")), nil)
        XCTAssertTrue(c.isHidden(1))
        XCTAssertEqual(c.problems(among: [1]), [])
    }
}
