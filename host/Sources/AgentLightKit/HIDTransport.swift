import Foundation
import IOKit.hid

/// Vendor HID (usage page 0xFF00), 64-байтные репорты, docs/03-protocol.md §3.3.
/// Hot-plug целиком на колбэках IOHIDManager — никакого опроса.
public final class HIDTransport: DeviceTransport {
    public static let usagePage = 0xFF00
    /// pid.codes 1209:AC01 и, на время разработки, VID Raspberry Pi
    public static let vendorIDs = [0x1209, 0x2E8A]

    public let name = "HID"
    public var onAttach: ((DeviceChannel) -> Void)?
    public var onDetach: ((DeviceChannel) -> Void)?

    private var manager: IOHIDManager?
    private var channels: [HIDChannel] = []

    public init() {}

    public func start() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = Self.vendorIDs.map {
            [kIOHIDVendorIDKey: $0, kIOHIDPrimaryUsagePageKey: Self.usagePage] as CFDictionary
        }
        IOHIDManagerSetDeviceMatchingMultiple(m, matching as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, dev in
            Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue().attached(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, dev in
            Unmanaged<HIDTransport>.fromOpaque(ctx!).takeUnretainedValue().removed(dev)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let r = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess {
            Log.warn("HID: IOHIDManagerOpen вернул 0x\(String(r, radix: 16)) — проверь Input Monitoring (agentlight doctor)")
        }
        manager = m
    }

    public func stop() {
        guard let m = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
        channels.forEach { $0.invalidate() }
        channels = []
    }

    private func attached(_ dev: IOHIDDevice) {
        guard !channels.contains(where: { CFEqual($0.device, dev) }) else { return }
        let ch = HIDChannel(device: dev)
        channels.append(ch)
        let product = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String ?? "?"
        Log.info("HID: найдено устройство \(product)")
        onAttach?(ch)
    }

    private func removed(_ dev: IOHIDDevice) {
        guard let i = channels.firstIndex(where: { CFEqual($0.device, dev) }) else { return }
        let ch = channels.remove(at: i)
        ch.invalidate()
        onDetach?(ch)
    }
}

/// Одно HID-устройство.
final class HIDChannel: DeviceChannel {
    let name = "HID"
    var onEvent: ((DeviceEvent) -> Void)?
    let device: IOHIDDevice
    private let inputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: DeviceCommand.reportSize)
    private var registered = false

    init(device: IOHIDDevice) {
        self.device = device
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, DeviceCommand.reportSize, { ctx, _, _, _, _, report, length in
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            Unmanaged<HIDChannel>.fromOpaque(ctx!).takeUnretainedValue().received(bytes)
        }, ctx)
        registered = true
    }

    deinit {
        invalidate()
        inputBuffer.deallocate()
    }

    /// снять колбэк до того, как канал исчезнет
    func invalidate() {
        guard registered else { return }
        registered = false
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, DeviceCommand.reportSize, nil, nil)
    }

    func send(_ command: DeviceCommand) {
        guard registered else { return }
        let report = command.hidReport
        let r = report.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, $0.count)
        }
        if r != kIOReturnSuccess {
            Log.warn("HID: SetReport 0x\(String(report[0], radix: 16)) → 0x\(String(r, radix: 16))")
        }
    }

    private func received(_ bytes: [UInt8]) {
        if let e = DeviceEvent(hidReport: bytes) { onEvent?(e) }
    }
}
