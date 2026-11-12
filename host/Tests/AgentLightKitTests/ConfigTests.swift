import XCTest
@testable import AgentLightKit

final class ConfigTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentlight-config-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Settings from the UI are written via load → edit → save: hand-edited fields must not get lost.
    func testSaveKeepsOtherFields() throws {
        try Data(#"{"port": 48880, "pins": {"~/work": 2}, "brightness": 40}"#.utf8).write(to: url)
        var c = try Config.load(from: url)
        c.emptySlotButtonLaunches = "~/projects/agent-indicator"
        try c.save(to: url)

        let back = try Config.load(from: url)
        XCTAssertEqual(back.emptySlotButtonLaunches, "~/projects/agent-indicator")
        XCTAssertEqual(back.port, 48880)
        XCTAssertEqual(back.brightness, 40)
        XCTAssertEqual(back.pins, ["~/work": 2])
    }

    func testResetLaunchDirDropsKey() throws {
        var c = Config()
        c.emptySlotButtonLaunches = "~/x"
        try c.save(to: url)
        c.emptySlotButtonLaunches = nil
        try c.save(to: url)

        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("empty_slot_button_launches"))
        XCTAssertNil(try Config.load(from: url).emptySlotButtonLaunches)
    }

    func testSlotCountDefaultsToFourAndIsClamped() throws {
        XCTAssertEqual(Config().slotCount, 4)
        try Data(#"{"slot_count": 7}"#.utf8).write(to: url)
        XCTAssertEqual(try Config.load(from: url).slotCount, 7)
        try Data(#"{"slot_count": 0}"#.utf8).write(to: url)
        XCTAssertEqual(try Config.load(from: url).slotCount, 1)
        try Data(#"{"slot_count": 100}"#.utf8).write(to: url)
        XCTAssertEqual(try Config.load(from: url).slotCount, Config.slotCountRange.upperBound)
    }

    func testMenuBarIconStyleRoundTripsAndFallsBackToAuto() throws {
        XCTAssertEqual(Config().menuBarIcon, .auto)
        var c = Config()
        c.menuBarIcon = .plates
        try c.save(to: url)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains(#""menu_bar_icon" : "plates""#))
        XCTAssertEqual(try Config.load(from: url).menuBarIcon, .plates)
        try Data(#"{"menu_bar_icon": "neon"}"#.utf8).write(to: url)
        XCTAssertEqual(try Config.load(from: url).menuBarIcon, .auto)
    }
}
