import Foundation

/// `~/.agentlight/config.json`, docs/01-architecture.md §1.4. Any field may be omitted.
public struct Config: Codable, Equatable, Sendable {
    public var port: UInt16 = 48879
    public var brightness: UInt8 = 120
    /// how many traffic lights the app has; one device shows 4 of them,
    /// the second one the next 4, and so on (docs/05-host-macos.md §5.8)
    public var slotCount = 4
    /// cwd (or an ancestor) → slot index
    public var pins: [String: Int] = [:]
    public var busyTimeoutSec: Double = 900
    public var sessionTTLSec: Double = 8 * 3600
    public var rebindWindowSec: Double = 15
    public var idlePulse = false
    public var busyPulse = false
    public var emptySlotButtonLaunches: String?
    public var terminalFocusOrder: [String] = ["tmux", "native", "new_window"]
    /// `/dev/cu.usbmodem…` for the CDC transport; nil — autodetect
    public var cdcPort: String?

    public static let slotCountRange = 1...16

    public init() {}

    enum CodingKeys: String, CodingKey {
        case port, brightness, pins
        case slotCount = "slot_count"
        case busyTimeoutSec = "busy_timeout_sec"
        case sessionTTLSec = "session_ttl_sec"
        case rebindWindowSec = "rebind_window_sec"
        case idlePulse = "idle_pulse"
        case busyPulse = "busy_pulse"
        case emptySlotButtonLaunches = "empty_slot_button_launches"
        case terminalFocusOrder = "terminal_focus_order"
        case cdcPort = "cdc_port"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? d.port
        brightness = try c.decodeIfPresent(UInt8.self, forKey: .brightness) ?? d.brightness
        let slots = try c.decodeIfPresent(Int.self, forKey: .slotCount) ?? d.slotCount
        slotCount = min(max(slots, Self.slotCountRange.lowerBound), Self.slotCountRange.upperBound)
        pins = try c.decodeIfPresent([String: Int].self, forKey: .pins) ?? d.pins
        busyTimeoutSec = try c.decodeIfPresent(Double.self, forKey: .busyTimeoutSec) ?? d.busyTimeoutSec
        sessionTTLSec = try c.decodeIfPresent(Double.self, forKey: .sessionTTLSec) ?? d.sessionTTLSec
        rebindWindowSec = try c.decodeIfPresent(Double.self, forKey: .rebindWindowSec) ?? d.rebindWindowSec
        idlePulse = try c.decodeIfPresent(Bool.self, forKey: .idlePulse) ?? d.idlePulse
        busyPulse = try c.decodeIfPresent(Bool.self, forKey: .busyPulse) ?? d.busyPulse
        emptySlotButtonLaunches = try c.decodeIfPresent(String.self, forKey: .emptySlotButtonLaunches)
        terminalFocusOrder = try c.decodeIfPresent([String].self, forKey: .terminalFocusOrder) ?? d.terminalFocusOrder
        cdcPort = try c.decodeIfPresent(String.self, forKey: .cdcPort)
    }

    /// Slot pinned to cwd or its nearest ancestor.
    public func pinnedSlot(for cwd: String?) -> Int? {
        guard let cwd else { return nil }
        var best: (len: Int, slot: Int)?
        for (path, slot) in pins {
            let p = path.hasSuffix("/") ? String(path.dropLast()) : path
            guard cwd == p || cwd.hasPrefix(p + "/") else { continue }
            if best == nil || p.count > best!.len { best = (p.count, slot) }
        }
        return best?.slot
    }
}

public enum Paths {
    public static var home: URL {
        if let override = ProcessInfo.processInfo.environment["AGENTLIGHT_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agentlight", isDirectory: true)
    }
    public static var config: URL { home.appendingPathComponent("config.json") }
    public static var state: URL { home.appendingPathComponent("state.json") }
    public static var log: URL { home.appendingPathComponent("agentlightd.log") }
}

public extension Config {
    static func load(from url: URL = Paths.config) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
    }

    func save(to url: URL = Paths.config) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFile.write(enc.encode(self), to: url)
    }
}

public enum AtomicFile {
    /// temp + rename in the same directory
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        try data.write(to: tmp)
        if rename(tmp.path, url.path) != 0 {
            let err = errno
            try? FileManager.default.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
    }
}
