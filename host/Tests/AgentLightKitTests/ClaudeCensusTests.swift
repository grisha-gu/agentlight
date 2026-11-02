import Foundation
import XCTest
@testable import AgentLightKit

final class ClaudeCensusTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    // все процессы стартовали до снимка, снимок — в t0
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
        XCTAssertNil(ClaudeAgentsList.parse(Data(#"{"sessions":[]}"#.utf8), takenAt: t0), "формат сменился")
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
        // Claude Code переименовал parkedJobId и spare: реестр видит всех как обычные сессии
        let r = registry(entry(1), entry(9, kind: "bg", job: "j9"), entry(5, kind: "bg", job: "j5"))
        let c = census(r, list(9))
        XCTAssertTrue(c.isHidden(1), "оболочку прячет список")
        XCTAssertTrue(c.isHidden(5), "заготовку прячет список")
        XCTAssertNil(c.parkedShell(of: 9), "передача слота без реестра не работает — лампа займёт новый слот")
        XCTAssertEqual(c.problems(among: [1, 5, 9]).count, 2)
        XCTAssertTrue(c.problems(among: [1])[0].contains("не видит"))
    }

    func testListRevealsWhatRegistryWronglyHides() {
        let r = registry(entry(5, kind: "bg", job: "j5", spare: true))
        let c = census(r, list(5))
        XCTAssertFalse(c.isHidden(5))
        XCTAssertTrue(c.problems(among: [5])[0].contains("видит"))
    }

    func testStaleSnapshotDefersToRegistry() {
        // заготовке отдали задачу после снимка: файл переписан позже — снимок не в счёт
        let r = registry(entry(5, kind: "bg", job: "j5", modified: t0 + 3))
        let c = census(r, list())
        XCTAssertFalse(c.isHidden(5))
        XCTAssertEqual(c.problems(among: [5]), [])
        // процесс моложе снимка — тоже
        let young = ClaudeCensus(registry: registry(entry(6, kind: "bg", job: "j6", spare: true)), listed: list(6),
                                 arguments: { _ in nil }, startedAt: { [t0] _ in t0 + 1 })
        XCTAssertTrue(young.isHidden(6))
    }

    func testListNeverHidesProcessesItCannotVouchFor() {
        // процесс без записи в реестре и не заготовка (чужой SDK, новый вид сессии) — не прячем
        let c = census(registry(entry(7)), list(7))
        XCTAssertFalse(c.isHidden(42))
        // незанятая заготовка: файла нет, argv --bg-spare
        let spare = census(registry(entry(7)), list(7), argv: [43: ["claude", "--bg-spare", "/x.sock"]])
        XCTAssertTrue(spare.isHidden(43))
    }

    func testMissingRegistryDoesNotHideDispatchedSpares() {
        // реестр пропал (другое место/формат), а задача из agent view живёт в процессе с --bg-spare:
        // без сверки — показываем; со сверкой — список видит её
        let argv: [Int32: [String]] = [43: ["claude", "--bg-spare", "/x.sock"]]
        XCTAssertFalse(census(ClaudeSessions(), nil, argv: argv).isHidden(43))
        let c = census(ClaudeSessions(), list(43, 7), argv: argv)
        XCTAssertFalse(c.isHidden(43))
        XCTAssertTrue(c.problems(among: [43])[0].contains("нет 2 из 2"))
    }

    func testNoSnapshotMeansRegistryOnly() {
        let c = census(registry(entry(1, parked: "j")), nil)
        XCTAssertTrue(c.isHidden(1))
        XCTAssertEqual(c.problems(among: [1]), [])
    }
}
