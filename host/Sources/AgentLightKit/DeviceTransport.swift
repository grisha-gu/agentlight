import Foundation

/// One physical device, seen through one transport. Callbacks run on the main queue.
public protocol DeviceChannel: AnyObject {
    var name: String { get }
    var onEvent: ((DeviceEvent) -> Void)? { get set }
    func send(_ command: DeviceCommand)
}

/// A way to find devices (HID, CDC, stub). There may be several devices.
/// All callbacks run on the main queue.
public protocol DeviceTransport: AnyObject {
    var name: String { get }
    var onAttach: ((DeviceChannel) -> Void)? { get set }
    var onDetach: ((DeviceChannel) -> Void)? { get set }
    func start()
    func stop()
}

/// Heartbeat, resync and laying out slots across devices (docs/05-host-macos.md §5.8, docs/03-protocol.md §3.5).
/// Each device shows its own four slots: the first connected one 0..3, the second 4..7, and so on.
/// One device may be visible via both HID and CDC — we recognize it by the uid from READY
/// and talk to it through whichever transport comes first in the list.
public final class DeviceLink {
    public static let slotsPerDevice = 4

    /// The device commands go to.
    public struct Device: Equatable, Sendable {
        public var name: String
        public var identity: DeviceIdentity
        public var bank: Int
        /// power switch on the back wall: when "off" the firmware itself dims the lights and mutes the buttons
        public var powerOn: Bool
        public var slots: Range<Int> { bank * DeviceLink.slotsPerDevice..<(bank + 1) * DeviceLink.slotsPerDevice }
        /// slots as numbered on the buttons: "1–4", "5–8"
        public var slotRangeText: String { "\(slots.lowerBound + 1)–\(slots.upperBound)" }
    }

    private final class Attached {
        let channel: DeviceChannel
        /// transport index: lower wins
        let rank: Int
        var identity: DeviceIdentity?
        var powerOn = true

        init(channel: DeviceChannel, rank: Int) {
            self.channel = channel
            self.rank = rank
        }

        /// physical device key; without a uid every channel is a separate device
        var key: String? {
            identity.map { $0.uid.isEmpty ? "channel-\(ObjectIdentifier(channel).hashValue)" : $0.uid }
        }
    }

    public private(set) var transports: [DeviceTransport]
    public var onButton: ((Int, ButtonGesture) -> Void)?
    /// connect, READY, layout change — for the UI
    public var onStatusChange: (() -> Void)?

    public var brightness: UInt8
    public var flags: (busyPulse: Bool, idlePulse: Bool)
    private var lights: [LightState] = []
    private var attached: [Attached] = []
    /// device → bank, while it's connected
    private var banks: [String: Int] = [:]
    /// the device's previous bank: a reconnected device takes its old place if it's free
    private var lastBank: [String: Int] = [:]
    private var paused = false
    private var pingSeq: UInt32 = 0
    private var timer: Timer?

    public init(transports: [DeviceTransport], config: Config) {
        self.transports = transports
        brightness = config.brightness
        flags = (config.busyPulse, config.idlePulse)
        for (rank, t) in transports.enumerated() {
            t.onAttach = { [weak self] ch in self?.attach(ch, rank: rank) }
            t.onDetach = { [weak self] ch in self?.detach(ch) }
        }
    }

    /// connected devices, by ascending bank
    public var devices: [Device] {
        primaries.compactMap { a in
            guard let id = a.identity, let key = a.key, let bank = banks[key] else { return nil }
            return Device(name: a.channel.name, identity: id, bank: bank, powerOn: a.powerOn)
        }
        .sorted { $0.bank < $1.bank }
    }

    public var isConnected: Bool { !attached.isEmpty }

    /// connected, and no device is switched off
    public var isActive: Bool { isConnected && devices.allSatisfy(\.powerOn) }

    /// What the device line in the UI and in `/status` says.
    public enum Status: Equatable, Sendable {
        case disconnected
        /// a channel is open, READY hasn't arrived yet
        case connecting(String)
        /// one device, switched off with the power switch
        case switchedOff(Device)
        case single(Device)
        /// several devices, or one that isn't in bank 0
        case several([Device])
    }

    public var status: Status {
        let ds = devices
        switch ds.count {
        case 0:
            guard let a = attached.first else { return .disconnected }
            return .connecting(a.channel.name)
        case 1 where ds[0].bank == 0 && !ds[0].powerOn:
            return .switchedOff(ds[0])
        case 1 where ds[0].bank == 0:
            return .single(ds[0])
        default:
            return .several(ds)
        }
    }

    /// `status` in English — for `/status` and the CLI; the menu bar localizes `status` itself.
    public var statusText: String {
        switch status {
        case .disconnected: return "device not connected"
        case .connecting(let name): return "\(name): connected"
        case .switchedOff(let d): return "\(d.name): switched off"
        case .single(let d): return "\(d.name): fw \(d.identity.firmware), uid \(d.identity.uid)"
        case .several(let ds):
            let list = ds.map { "\($0.name) \($0.slotRangeText)" + ($0.powerOn ? "" : " (off)") }
            return "devices: \(ds.count) — " + list.joined(separator: ", ")
        }
    }

    public func start() {
        transports.forEach { $0.start() }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.heartbeat() }
    }

    public func stop() {
        timer?.invalidate()
        broadcast(.setAll(Self.dark))
        transports.forEach { $0.stop() }
    }

    /// Lights for all of the app's slots; each device gets its own four.
    public func show(_ lights: [LightState]) {
        guard lights != self.lights else { return }
        self.lights = lights
        guard !paused else { return }
        for a in primaries { a.channel.send(.setAll(slice(for: a))) }
    }

    /// nil — wave on all devices
    public func welcome(slot: Int?) {
        guard !paused else { return }
        guard let slot else { return broadcast(.welcome(slot: nil)) }
        let n = Self.slotsPerDevice
        for a in primaries where bank(of: a) == slot / n {
            a.channel.send(.welcome(slot: slot % n))
        }
    }

    /// Command to all connected devices.
    public func broadcast(_ cmd: DeviceCommand) {
        for a in primaries { a.channel.send(cmd) }
    }

    /// Sleep: turn everything off and stop sending PING — the hardware honestly stays dark.
    public func pause() {
        broadcast(.setAll(Self.dark))
        paused = true
    }

    public func resume() {
        paused = false
        resync()
    }

    public func resync() {
        primaries.forEach(resync)
    }

    // MARK: - Internals

    private static let dark = Array(repeating: LightState.off, count: slotsPerDevice)

    /// one channel per device — via the highest-priority transport
    private var primaries: [Attached] {
        var best: [String: Attached] = [:]
        for a in attached {
            guard let key = a.key else { continue }
            if let b = best[key], b.rank <= a.rank { continue }
            best[key] = a
        }
        return attached.filter { a in a.key.map { best[$0] === a } ?? false }
    }

    private func isPrimary(_ a: Attached) -> Bool { primaries.contains { $0 === a } }

    private func bank(of a: Attached) -> Int? { a.key.flatMap { banks[$0] } }

    private func slice(for a: Attached) -> [LightState] {
        guard let bank = bank(of: a) else { return Self.dark }
        return (0..<Self.slotsPerDevice).map { i in
            let g = bank * Self.slotsPerDevice + i
            return lights.indices.contains(g) ? lights[g] : .off
        }
    }

    private func resync(_ a: Attached) {
        guard !paused else { return }
        a.channel.send(.brightness(brightness))
        a.channel.send(.config(busyPulse: flags.busyPulse, idlePulse: flags.idlePulse))
        a.channel.send(.setAll(slice(for: a)))
    }

    private func heartbeat() {
        guard !paused else { return }
        pingSeq &+= 1
        broadcast(.ping(seq: pingSeq))
    }

    private func attach(_ ch: DeviceChannel, rank: Int) {
        guard !attached.contains(where: { $0.channel === ch }) else { return }
        Log.info("\(ch.name): connected")
        let a = Attached(channel: ch, rank: rank)
        attached.append(a)
        ch.onEvent = { [weak self, weak a] e in
            guard let self, let a else { return }
            self.handle(e, from: a)
        }
        // slots are assigned to a device by the uid from READY
        ch.send(.hello)
        onStatusChange?()
    }

    private func detach(_ ch: DeviceChannel) {
        guard let i = attached.firstIndex(where: { $0.channel === ch }) else { return }
        Log.info("\(ch.name): disconnected")
        let key = attached.remove(at: i).key
        ch.onEvent = nil
        if let key {
            if let next = primaries.first(where: { $0.key == key }) {
                resync(next)  // the same device is still there on another transport
            } else {
                banks.removeValue(forKey: key)
            }
        }
        onStatusChange?()
    }

    private func assignBank(_ key: String) -> Int {
        if let b = banks[key] { return b }
        let used = Set(banks.values)
        let b = lastBank[key].flatMap { used.contains($0) ? nil : $0 }
            ?? (0...).first { !used.contains($0) }!
        banks[key] = b
        lastBank[key] = b
        return b
    }

    private func handle(_ e: DeviceEvent, from a: Attached) {
        let t = a.channel
        switch e {
        case .ready(let id, let powerOn):
            if id.proto > DeviceEvent.supportedProto {
                Log.error("\(t.name): firmware says proto=\(id.proto), host only knows \(DeviceEvent.supportedProto) — update agentlight")
            }
            let isNew = a.identity != id
            a.identity = id
            a.powerOn = powerOn
            let bank = assignBank(a.key!)
            if isNew {
                let n = Self.slotsPerDevice
                Log.info("\(t.name): READY fw=\(id.firmware) uid=\(id.uid) slots=\(id.slots) power=\(powerOn ? "on" : "off") → slots \(bank * n)..\(bank * n + n - 1)")
            }
            if isPrimary(a) { resync(a) }
            onStatusChange?()
        case .button(let slot, let g):
            guard isPrimary(a), let bank = bank(of: a), (0..<Self.slotsPerDevice).contains(slot) else { return }
            onButton?(bank * Self.slotsPerDevice + slot, g)
        case .pong(_, _, let tripped):
            if tripped, isPrimary(a) { resync(a) }
        case .watchdogTrip:
            guard isPrimary(a) else { return }
            Log.warn("\(t.name): hardware watchdog tripped, resync")
            resync(a)
        case .power(let on):
            // The firmware itself dims lights and mutes buttons, and keeps accepting states — no resync needed.
            guard a.powerOn != on else { return }
            a.powerOn = on
            Log.info("\(t.name): power switch — \(on ? "on" : "off")")
            onStatusChange?()
        case .log(let s):
            Log.info("fw: \(s)")
        }
    }
}
