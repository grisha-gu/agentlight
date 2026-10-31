import Foundation

/// Протокол устройства, docs/03-protocol.md. Один набор команд, два кодирования:
/// 64-байтные HID-репорты и ASCII-строки для CDC.
public enum DeviceCommand: Equatable, Sendable {
    case setState(slot: Int, LightState)
    case setAll([LightState])
    /// nil — волна по всем слотам
    case welcome(slot: Int?)
    case brightness(UInt8)
    case ping(seq: UInt32)
    case hello
    case selftest
    case config(busyPulse: Bool, idlePulse: Bool)
    case raw([UInt8])

    public static let reportSize = 64

    public var hidReport: [UInt8] {
        var r = [UInt8](repeating: 0, count: Self.reportSize)
        switch self {
        case .setState(let slot, let st):
            r[0] = 0x01; r[1] = UInt8(slot); r[2] = st.rawValue
        case .setAll(let states):
            r[0] = 0x02
            for (i, s) in states.prefix(4).enumerated() { r[1 + i] = s.rawValue }
        case .welcome(let slot):
            r[0] = 0x03; r[1] = slot.map(UInt8.init) ?? 0xFF
        case .brightness(let b):
            r[0] = 0x04; r[1] = b
        case .ping(let seq):
            r[0] = 0x05; r.writeLE(seq, at: 1)
        case .hello:
            r[0] = 0x06
        case .selftest:
            r[0] = 0x07
        case .config(let busy, let idle):
            r[0] = 0x08
            r[1] = (busy ? 2 : 0) | (idle ? 4 : 0)   // bit0 — бывший attn_blink, удалён
        case .raw(let levels):
            r[0] = 0x09
            for (i, l) in levels.prefix(12).enumerated() { r[1 + i] = l }
        }
        return r
    }

    public var asciiLine: String {
        switch self {
        case .setState(let slot, let st): "SET \(slot) \(st.name)"
        case .setAll(let states): "SETALL " + states.map(\.name).joined(separator: " ")
        case .welcome(let slot): "WELCOME " + (slot.map(String.init) ?? "ALL")
        case .brightness(let b): "BRIGHT \(b)"
        case .ping(let seq): "PING \(seq)"
        case .hello: "HELLO"
        case .selftest: "SELFTEST"
        case .config(let busy, let idle):
            "CONFIG busy_pulse=\(busy ? 1 : 0) idle_pulse=\(idle ? 1 : 0)"
        case .raw(let levels): "RAW " + levels.map { String(format: "%02x", $0) }.joined(separator: " ")
        }
    }
}

public enum ButtonGesture: UInt8, Sendable {
    case press = 1
    case long = 2
    case double = 3

    init?(name: String) {
        switch name.lowercased() {
        case "press": self = .press
        case "long": self = .long
        case "double": self = .double
        default: return nil
        }
    }
}

public struct DeviceIdentity: Equatable, Sendable {
    public var proto: Int
    public var slots: Int
    public var firmware: String
    public var uid: String
}

public enum DeviceEvent: Equatable, Sendable {
    /// powerOn — положение выключателя на задней стенке; старая прошивка его не шлёт → true
    case ready(DeviceIdentity, powerOn: Bool)
    case button(slot: Int, ButtonGesture)
    case pong(seq: UInt32, uptimeMs: UInt32, watchdogTripped: Bool)
    case watchdogTrip
    case log(String)
    case power(on: Bool)

    public static let supportedProto = 1

    public init?(hidReport r: [UInt8]) {
        guard let op = r.first else { return nil }
        switch op {
        case 0x81 where r.count >= 14:
            let uid = r[6..<14].map { String(format: "%02X", $0) }.joined()
            // fw до 0.6.0 оставляет байт 14 нулём, а выключателя у неё нет
            let fw = (Int(r[3]), Int(r[4]))
            let knowsPower = fw >= (0, 6)
            self = .ready(DeviceIdentity(proto: Int(r[1]), slots: Int(r[2]),
                                         firmware: "\(r[3]).\(r[4]).\(r[5])", uid: uid),
                          powerOn: !knowsPower || r.count < 15 || r[14] != 0)
        case 0x82 where r.count >= 3:
            guard let g = ButtonGesture(rawValue: r[2]) else { return nil }
            self = .button(slot: Int(r[1]), g)
        case 0x83 where r.count >= 10:
            self = .pong(seq: r.readLE(at: 1), uptimeMs: r.readLE(at: 5), watchdogTripped: r[9] != 0)
        case 0x84 where r.count >= 2:
            let n = min(Int(r[1]), r.count - 2)
            self = .log(String(decoding: r[2..<(2 + n)], as: UTF8.self))
        case 0x85 where r.count >= 2:
            self = .power(on: r[1] != 0)
        default:
            return nil
        }
    }

    /// Асинхронные события и ответ на HELLO (`OK agentlight …` — тот же READY).
    public init?(asciiLine raw: String) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = line.split(separator: " ").map(String.init)
        guard let head = words.first?.uppercased() else { return nil }
        func kv(_ key: String) -> String? {
            words.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
        }
        switch head {
        case "!READY",
             "OK" where words.count > 1 && words[1] == "agentlight":
            self = .ready(DeviceIdentity(proto: kv("proto").flatMap { Int($0) } ?? 0,
                                         slots: kv("slots").flatMap { Int($0) } ?? 0,
                                         firmware: kv("fw") ?? "?", uid: kv("uid") ?? ""),
                          powerOn: kv("power") != "off")
        case "!BTN":
            guard words.count >= 3, let slot = Int(words[1]), let g = ButtonGesture(name: words[2]) else { return nil }
            self = .button(slot: slot, g)
        case "OK" where words.count > 2 && words[1].uppercased() == "PONG":
            self = .pong(seq: UInt32(words[2]) ?? 0,
                         uptimeMs: kv("uptime").flatMap { UInt32($0) } ?? 0,
                         watchdogTripped: kv("wd") == "1")
        case "!POWER" where words.count >= 2:
            self = .power(on: words[1].lowercased() != "off")
        case "!WD":
            self = .watchdogTrip
        case "!LOG":
            self = .log(String(line.dropFirst(5)))
        default:
            return nil
        }
    }
}

extension Array where Element == UInt8 {
    mutating func writeLE(_ v: UInt32, at i: Int) {
        for k in 0..<4 { self[i + k] = UInt8(truncatingIfNeeded: v >> (8 * k)) }
    }

    func readLE(at i: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(self[i + $1]) << (8 * $1) }
    }
}
