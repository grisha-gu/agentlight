import XCTest
@testable import AgentLightKit

private final class TestChannel: DeviceChannel {
    let name: String
    var onEvent: ((DeviceEvent) -> Void)?
    var sent: [DeviceCommand] = []
    let uid: String

    init(_ name: String, uid: String) {
        self.name = name
        self.uid = uid
    }

    func send(_ command: DeviceCommand) {
        sent.append(command)
        if command == .hello { ready() }
    }

    func ready() {
        onEvent?(.ready(DeviceIdentity(proto: 1, slots: 4, firmware: "1.0.0", uid: uid), powerOn: true))
    }

    var lastSetAll: [LightState]? {
        for c in sent.reversed() { if case .setAll(let l) = c { return l } }
        return nil
    }
}

private final class TestTransport: DeviceTransport {
    let name: String
    var onAttach: ((DeviceChannel) -> Void)?
    var onDetach: ((DeviceChannel) -> Void)?
    init(_ name: String) { self.name = name }
    func start() {}
    func stop() {}
}

final class DeviceLinkTests: XCTestCase {
    private let hid = TestTransport("HID")
    private let cdc = TestTransport("CDC")
    private var link: DeviceLink!
    private var pressed: [Int] = []

    override func setUp() {
        link = DeviceLink(transports: [hid, cdc], config: Config())
        link.onButton = { [unowned self] slot, _ in pressed.append(slot) }
    }

    private let lights: [LightState] = [.attn, .busy, .idle, .off, .idle, .attn, .busy]

    func testSecondDeviceGetsNextFourSlots() {
        let a = TestChannel("CDC", uid: "A"), b = TestChannel("CDC", uid: "B")
        cdc.onAttach?(a)
        cdc.onAttach?(b)
        link.show(lights)
        XCTAssertEqual(a.lastSetAll, [.attn, .busy, .idle, .off])
        // 7 слотов: у второго устройства последний светофор лишний
        XCTAssertEqual(b.lastSetAll, [.idle, .attn, .busy, .off])
        XCTAssertEqual(link.devices.map(\.bank), [0, 1])

        b.onEvent?(.button(slot: 2, .press))
        a.onEvent?(.button(slot: 1, .press))
        XCTAssertEqual(pressed, [6, 1])

        link.welcome(slot: 5)
        XCTAssertEqual(b.sent.last, .welcome(slot: 1))
        XCTAssertNotEqual(a.sent.last, .welcome(slot: 1))
    }

    func testReconnectedDeviceKeepsItsBankAndFreedBankIsReused() {
        let a = TestChannel("CDC", uid: "A"), b = TestChannel("CDC", uid: "B")
        cdc.onAttach?(a)
        cdc.onAttach?(b)
        cdc.onDetach?(a)
        XCTAssertEqual(link.devices.map(\.bank), [1])
        cdc.onAttach?(a)
        XCTAssertEqual(link.devices.map(\.bank), [0, 1])

        cdc.onDetach?(a)
        let c = TestChannel("CDC", uid: "C")
        cdc.onAttach?(c)
        XCTAssertEqual(link.devices.first { $0.identity.uid == "C" }?.bank, 0)
    }

    /// Одна железка видна и по HID, и по CDC — это одно устройство, говорим через HID.
    func testSameDeviceOnTwoTransportsIsOneDevice() {
        let viaCDC = TestChannel("CDC", uid: "A"), viaHID = TestChannel("HID", uid: "A")
        cdc.onAttach?(viaCDC)
        hid.onAttach?(viaHID)
        XCTAssertEqual(link.devices.count, 1)
        XCTAssertEqual(link.devices[0].name, "HID")
        XCTAssertEqual(link.devices[0].bank, 0)

        viaCDC.sent = []
        link.show(lights)
        XCTAssertTrue(viaCDC.sent.isEmpty)
        viaCDC.onEvent?(.button(slot: 0, .press))
        XCTAssertEqual(pressed, [])

        hid.onDetach?(viaHID)
        XCTAssertEqual(viaCDC.lastSetAll, [.attn, .busy, .idle, .off])
        XCTAssertEqual(link.devices.map(\.name), ["CDC"])
    }

    /// Выключатель: прошивка гасит огни сама, хост только показывает «выключено» и ничего не шлёт.
    func testPowerSwitchIsShownWithoutResync() {
        let a = TestChannel("HID", uid: "A")
        hid.onAttach?(a)
        XCTAssertTrue(link.isActive)
        a.sent = []
        a.onEvent?(.power(on: false))
        XCTAssertFalse(link.isActive)
        XCTAssertTrue(link.isConnected)
        XCTAssertEqual(link.statusText, "HID: выключено")
        XCTAssertTrue(a.sent.isEmpty)

        a.onEvent?(.power(on: true))
        XCTAssertTrue(link.isActive)
        // READY после перезагрузки приносит положение заново
        a.onEvent?(.ready(DeviceIdentity(proto: 1, slots: 4, firmware: "1.0.0", uid: "A"), powerOn: false))
        XCTAssertFalse(link.devices[0].powerOn)
    }

    func testNoButtonsBeforeReady() {
        let silent = SilentChannel()
        hid.onAttach?(silent)
        silent.onEvent?(.button(slot: 0, .press))
        XCTAssertEqual(pressed, [])
        XCTAssertTrue(link.devices.isEmpty)
        XCTAssertTrue(link.isConnected)
    }
}

private final class SilentChannel: DeviceChannel {
    let name = "HID"
    var onEvent: ((DeviceEvent) -> Void)?
    func send(_ command: DeviceCommand) {}
}
