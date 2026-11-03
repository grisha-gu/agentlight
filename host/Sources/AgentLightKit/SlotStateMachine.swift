/// Visible traffic light state. Codes match the firmware's `slot_state_t` (docs/03-protocol.md §3.2).
public enum LightState: UInt8, Sendable, CaseIterable {
    case off = 0
    case idle = 1   // green
    case busy = 2   // yellow
    case attn = 3   // red

    public var name: String {
        switch self {
        case .off: "off"
        case .idle: "idle"
        case .busy: "busy"
        case .attn: "attn"
        }
    }

    public init?(name: String) {
        guard let s = Self.allCases.first(where: { $0.name == name.lowercased() }) else { return nil }
        self = s
    }
}

/// In JSON — by name: state.json and /status are meant to be human-readable.
extension LightState: Codable {
    public init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        guard let s = LightState(name: name) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown state \(name)"))
        }
        self = s
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
    }
}

/// What an event does to the agent's slot.
public enum Transition: Equatable, Sendable {
    /// claim a slot (if not claimed yet) and switch to the state
    case start
    case set(LightState)
    /// free the slot; `rebind` — hold it for the next session of the same window
    case end(rebind: Bool)
    /// state doesn't change, the event only extends the session's lifetime
    case ignore
}

/// Hook → state mapping, docs/01-architecture.md §1.3.
public enum SlotStateMachine {
    static let attnNotifications: Set<String> = [
        "permission_prompt", "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog",
    ]
    /// `/clear` and `/resume` start a new session in the same window — keep the slot.
    static let rebindReasons: Set<String> = ["clear", "resume"]

    public static func transition(for event: HookEvent) -> Transition {
        switch event.name {
        case "SessionStart":
            return .start
        case "SessionEnd":
            return .end(rebind: event.reason.map(rebindReasons.contains) ?? false)
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
             "PermissionDenied", "ElicitationResult":
            return .set(.busy)
        case "SubagentStart", "SubagentStop", "PreCompact", "PostCompact":
            // These don't color: Claude Code launches fork agents on its own while you're idle
            // (away_summary after ~3 min idle, prompt_suggestion, agent_summary) and compacts
            // context when idle (idleCompaction). A real subagent runs inside a turn,
            // when the slot is already yellow from UserPromptSubmit/PreToolUse. Inferred from Claude Code's code
            // 2026-10-16; confirm via ~/.agentlight/hooks.jsonl after the next away_summary.
            return .ignore
        case "PermissionRequest", "Elicitation", "StopFailure":
            return .set(.attn)
        case "Stop":
            return .set(.idle)
        case "Notification":
            // idle_prompt — an inactivity timer 60 s after Stop, not a block (§1.3)
            if let type = event.notificationType {
                if attnNotifications.contains(type) { return .set(.attn) }
                if type == "agent_completed" { return .set(.idle) }
            }
            return .ignore
        default:
            return .ignore
        }
    }
}
