import Foundation

/// Одно физическое устройство, видимое через один транспорт. Колбэки — на главной очереди.
public protocol DeviceChannel: AnyObject {
    var name: String { get }
    var onEvent: ((DeviceEvent) -> Void)? { get set }
    func send(_ command: DeviceCommand)
}

/// Способ найти устройства (HID, CDC, заглушка). Устройств может быть несколько.
/// Все колбэки — на главной очереди.
public protocol DeviceTransport: AnyObject {
    var name: String { get }
    var onAttach: ((DeviceChannel) -> Void)? { get set }
    var onDetach: ((DeviceChannel) -> Void)? { get set }
    func start()
    func stop()
}

/// Heartbeat, ресинк и раскладка слотов по устройствам (docs/05-host-macos.md §5.8, docs/03-protocol.md §3.5).
/// Каждое устройство показывает свою четвёрку слотов: первое подключённое — 0..3, второе — 4..7 и т. д.
/// Одно устройство может быть видно сразу через HID и CDC — узнаём его по uid из READY
/// и говорим с ним через транспорт, что раньше в списке.
public final class DeviceLink {
    public static let slotsPerDevice = 4

    /// Устройство, которому идут команды.
    public struct Device: Equatable, Sendable {
        public var name: String
        public var identity: DeviceIdentity
        public var bank: Int
        /// выключатель на задней стенке: в «выкл» прошивка сама гасит огни и глушит кнопки
        public var powerOn: Bool
        public var slots: Range<Int> { bank * DeviceLink.slotsPerDevice..<(bank + 1) * DeviceLink.slotsPerDevice }
    }

    private final class Attached {
        let channel: DeviceChannel
        /// индекс транспорта: меньше — приоритетнее
        let rank: Int
        var identity: DeviceIdentity?
        var powerOn = true

        init(channel: DeviceChannel, rank: Int) {
            self.channel = channel
            self.rank = rank
        }

        /// ключ физического устройства; без uid каждый канал — отдельное устройство
        var key: String? {
            identity.map { $0.uid.isEmpty ? "channel-\(ObjectIdentifier(channel).hashValue)" : $0.uid }
        }
    }

    public private(set) var transports: [DeviceTransport]
    public var onButton: ((Int, ButtonGesture) -> Void)?
    /// подключение, READY, смена раскладки — для UI
    public var onStatusChange: (() -> Void)?

    public var brightness: UInt8
    public var flags: (busyPulse: Bool, idlePulse: Bool)
    private var lights: [LightState] = []
    private var attached: [Attached] = []
    /// устройство → банк, пока оно подключено
    private var banks: [String: Int] = [:]
    /// прошлый банк устройства: переподключённое встаёт на своё место, если оно свободно
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

    /// подключённые устройства, по возрастанию банка
    public var devices: [Device] {
        primaries.compactMap { a in
            guard let id = a.identity, let key = a.key, let bank = banks[key] else { return nil }
            return Device(name: a.channel.name, identity: id, bank: bank, powerOn: a.powerOn)
        }
        .sorted { $0.bank < $1.bank }
    }

    public var isConnected: Bool { !attached.isEmpty }

    /// подключено и ни одно устройство не выключено переключателем
    public var isActive: Bool { isConnected && devices.allSatisfy(\.powerOn) }

    public var statusText: String {
        let ds = devices
        switch ds.count {
        case 0:
            guard let a = attached.first else { return "устройство не подключено" }
            return "\(a.channel.name): подключено"
        case 1 where ds[0].bank == 0 && !ds[0].powerOn:
            return "\(ds[0].name): выключено"
        case 1 where ds[0].bank == 0:
            return "\(ds[0].name): fw \(ds[0].identity.firmware), uid \(ds[0].identity.uid)"
        default:
            let list = ds.map { "\($0.name) \($0.slots.lowerBound + 1)–\($0.slots.upperBound)" + ($0.powerOn ? "" : " (выкл)") }
            return "устройств: \(ds.count) — " + list.joined(separator: ", ")
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

    /// Огни всех слотов приложения; каждое устройство получает свою четвёрку.
    public func show(_ lights: [LightState]) {
        guard lights != self.lights else { return }
        self.lights = lights
        guard !paused else { return }
        for a in primaries { a.channel.send(.setAll(slice(for: a))) }
    }

    /// nil — волна на всех устройствах
    public func welcome(slot: Int?) {
        guard !paused else { return }
        guard let slot else { return broadcast(.welcome(slot: nil)) }
        let n = Self.slotsPerDevice
        for a in primaries where bank(of: a) == slot / n {
            a.channel.send(.welcome(slot: slot % n))
        }
    }

    /// Команда всем подключённым устройствам.
    public func broadcast(_ cmd: DeviceCommand) {
        for a in primaries { a.channel.send(cmd) }
    }

    /// Сон: погасить всё и перестать слать PING — железки честно останутся тёмными.
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

    // MARK: - Внутреннее

    private static let dark = Array(repeating: LightState.off, count: slotsPerDevice)

    /// по одному каналу на устройство — с самым приоритетным транспортом
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
        Log.info("\(ch.name): подключено")
        let a = Attached(channel: ch, rank: rank)
        attached.append(a)
        ch.onEvent = { [weak self, weak a] e in
            guard let self, let a else { return }
            self.handle(e, from: a)
        }
        // слоты устройству даём по uid из READY
        ch.send(.hello)
        onStatusChange?()
    }

    private func detach(_ ch: DeviceChannel) {
        guard let i = attached.firstIndex(where: { $0.channel === ch }) else { return }
        Log.info("\(ch.name): отключено")
        let key = attached.remove(at: i).key
        ch.onEvent = nil
        if let key {
            if let next = primaries.first(where: { $0.key == key }) {
                resync(next)  // то же устройство осталось на другом транспорте
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
                Log.error("\(t.name): прошивка говорит proto=\(id.proto), хост знает только \(DeviceEvent.supportedProto) — обнови agentlight")
            }
            let isNew = a.identity != id
            a.identity = id
            a.powerOn = powerOn
            let bank = assignBank(a.key!)
            if isNew {
                let n = Self.slotsPerDevice
                Log.info("\(t.name): READY fw=\(id.firmware) uid=\(id.uid) slots=\(id.slots) power=\(powerOn ? "on" : "off") → слоты \(bank * n)..\(bank * n + n - 1)")
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
            Log.warn("\(t.name): watchdog железки сработал, ресинк")
            resync(a)
        case .power(let on):
            // Огни и кнопки прошивка гасит сама и состояния продолжает принимать — ресинк не нужен.
            guard a.powerOn != on else { return }
            a.powerOn = on
            Log.info("\(t.name): выключатель — \(on ? "вкл" : "выкл")")
            onStatusChange?()
        case .log(let s):
            Log.info("fw: \(s)")
        }
    }
}
