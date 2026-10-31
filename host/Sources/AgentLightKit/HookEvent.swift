import Foundation

/// Тело хука Claude Code. Обязательны только `hook_event_name` и `session_id`:
/// всё остальное опционально, незнакомые поля игнорируются (docs/05-host-macos.md §5.3).
public struct HookEvent: Decodable, Equatable, Sendable {
    public var name: String
    public var sessionId: String
    public var cwd: String?
    public var transcriptPath: String?
    public var notificationType: String?
    /// `SessionStart`: startup | resume | clear | compact
    public var source: String?
    /// `SessionEnd`: clear | resume | logout | prompt_input_exit | other
    public var reason: String?
    /// `PreCompact`/`PostCompact`: manual | auto
    public var trigger: String?
    /// Дописывается `agentlight hook` для `SessionStart` (command-хук).
    public var agentlight: HookExtras?

    public init(name: String, sessionId: String, cwd: String? = nil) {
        self.name = name
        self.sessionId = sessionId
        self.cwd = cwd
    }

    enum CodingKeys: String, CodingKey {
        case name = "hook_event_name"
        case sessionId = "session_id"
        case cwd
        case transcriptPath = "transcript_path"
        case notificationType = "notification_type"
        case source
        case reason
        case endReason = "end_reason"
        case trigger
        case agentlight
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        cwd = try? c.decodeIfPresent(String.self, forKey: .cwd)
        transcriptPath = try? c.decodeIfPresent(String.self, forKey: .transcriptPath)
        notificationType = try? c.decodeIfPresent(String.self, forKey: .notificationType)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        reason = (try? c.decodeIfPresent(String.self, forKey: .reason))
            ?? (try? c.decodeIfPresent(String.self, forKey: .endReason))
        trigger = try? c.decodeIfPresent(String.self, forKey: .trigger)
        agentlight = try? c.decodeIfPresent(HookExtras.self, forKey: .agentlight)
    }

    public static func decode(_ data: Data) throws -> HookEvent {
        try JSONDecoder().decode(HookEvent.self, from: data)
    }
}

/// То, чего нет в HTTP-payload, но что `agentlight hook` достаёт из окружения терминала.
public struct HookExtras: Codable, Equatable, Sendable {
    public var claudePid: Int32?
    public var preferSlot: Int?
    public var terminal: TerminalRef?

    public init(claudePid: Int32? = nil, preferSlot: Int? = nil, terminal: TerminalRef? = nil) {
        self.claudePid = claudePid
        self.preferSlot = preferSlot
        self.terminal = terminal
    }

    enum CodingKeys: String, CodingKey {
        case claudePid = "claude_pid"
        case preferSlot = "prefer_slot"
        case terminal
    }
}

/// Идентичность терминала агента — для фокуса по кнопке (docs/05-host-macos.md §5.5).
public struct TerminalRef: Codable, Equatable, Sendable {
    public var termProgram: String?
    /// `__CFBundleIdentifier` — приложение, из которого запущен шелл (com.apple.Terminal, …)
    public var appBundleId: String?
    public var itermSessionId: String?
    public var tmuxPane: String?
    public var tmuxSocket: String?
    public var weztermPane: String?
    public var kittyWindowId: String?
    public var tty: String?

    public init(termProgram: String? = nil, appBundleId: String? = nil, itermSessionId: String? = nil, tmuxPane: String? = nil,
                tmuxSocket: String? = nil, weztermPane: String? = nil, kittyWindowId: String? = nil,
                tty: String? = nil) {
        self.termProgram = termProgram
        self.appBundleId = appBundleId
        self.itermSessionId = itermSessionId
        self.tmuxPane = tmuxPane
        self.tmuxSocket = tmuxSocket
        self.weztermPane = weztermPane
        self.kittyWindowId = kittyWindowId
        self.tty = tty
    }

    enum CodingKeys: String, CodingKey {
        case termProgram = "term_program"
        case appBundleId = "app_bundle_id"
        case itermSessionId = "iterm_session_id"
        case tmuxPane = "tmux_pane"
        case tmuxSocket = "tmux_socket"
        case weztermPane = "wezterm_pane"
        case kittyWindowId = "kitty_window_id"
        case tty
    }
}
