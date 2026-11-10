import Foundation

/// `GET /status` — daemon snapshot for `agentlight status` and `doctor`.
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
    /// an older daemon doesn't send these fields
    public var automation: TerminalFocus.Automation?
    /// hidden sessions (Claude Code daemon spare, shell tab) — they get no traffic light
    public var background: [SessionRecord]?

    public init(version: String, pid: Int32, device: String, deviceConnected: Bool,
                slots: [SlotInfo], overflow: [SessionRecord], automation: TerminalFocus.Automation?,
                background: [SessionRecord]? = nil) {
        self.version = version
        self.pid = pid
        self.device = device
        self.deviceConnected = deviceConnected
        self.slots = slots
        self.overflow = overflow
        self.automation = automation
        self.background = background
    }
}

/// `POST /control` — CLI commands to the daemon.
public struct ControlRequest: Codable, Sendable {
    public enum Command: String, Codable, Sendable {
        /// re-read config.json
        case reload
        /// same as a hardware button
        case press, long
        case release
        /// run through all states on the device and in the menu bar
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
    public static let string = "0.3.0"
}
