import Foundation

/// `GET /status` — снимок демона для `agentlight status` и `doctor`.
public struct StatusReport: Codable, Sendable {
    public struct SlotInfo: Codable, Sendable {
        public var slot: Int
        public var light: LightState
        public var muted: Bool
        public var rebinding: Bool
        public var session: SessionRecord?

        public init(slot: Int, light: LightState, muted: Bool, rebinding: Bool, session: SessionRecord?) {
            self.slot = slot
            self.light = light
            self.muted = muted
            self.rebinding = rebinding
            self.session = session
        }
    }

    public var version: String
    public var pid: Int32
    public var device: String
    public var deviceConnected: Bool
    public var slots: [SlotInfo]
    public var overflow: [SessionRecord]
    /// у старого демона поля нет
    public var automation: TerminalFocus.Automation?

    public init(version: String, pid: Int32, device: String, deviceConnected: Bool,
                slots: [SlotInfo], overflow: [SessionRecord], automation: TerminalFocus.Automation?) {
        self.version = version
        self.pid = pid
        self.device = device
        self.deviceConnected = deviceConnected
        self.slots = slots
        self.overflow = overflow
        self.automation = automation
    }
}

/// `POST /control` — команды CLI демону.
public struct ControlRequest: Codable, Sendable {
    public enum Command: String, Codable, Sendable {
        /// перечитать config.json
        case reload
        /// то же, что кнопка
        case press, long
        case release
        /// прогнать все состояния на устройстве и в строке меню
        case test
        case selftest
    }

    public var cmd: Command
    public var slot: Int?

    public init(cmd: Command, slot: Int? = nil) {
        self.cmd = cmd
        self.slot = slot
    }
}

public struct ControlReply: Codable, Sendable {
    public var ok: Bool
    public var message: String

    public init(ok: Bool, message: String) {
        self.ok = ok
        self.message = message
    }
}

public enum AgentLightVersion {
    public static let string = "0.2.0"
}
