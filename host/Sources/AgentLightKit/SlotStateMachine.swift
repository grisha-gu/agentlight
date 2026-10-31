/// Видимое состояние светофора. Коды совпадают с `slot_state_t` прошивки (docs/03-protocol.md §3.2).
public enum LightState: UInt8, Sendable, CaseIterable {
    case off = 0
    case idle = 1   // зелёный
    case busy = 2   // жёлтый
    case attn = 3   // красный

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

/// В JSON — по имени: state.json и /status читаются глазами.
extension LightState: Codable {
    public init(from decoder: Decoder) throws {
        let name = try decoder.singleValueContainer().decode(String.self)
        guard let s = LightState(name: name) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "неизвестное состояние \(name)"))
        }
        self = s
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
    }
}

/// Что событие делает со слотом агента.
public enum Transition: Equatable, Sendable {
    /// занять слот (если ещё не занят) и перейти в состояние
    case start
    case set(LightState)
    /// освободить слот; `rebind` — подержать его для следующей сессии того же окна
    case end(rebind: Bool)
    /// состояние не меняется, событие лишь продлевает жизнь сессии
    case ignore
}

/// Маппинг хуков → состояния, docs/01-architecture.md §1.3.
public enum SlotStateMachine {
    static let attnNotifications: Set<String> = [
        "permission_prompt", "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog",
    ]
    /// `/clear` и `/resume` заводят новую сессию в том же окне — слот не отпускаем.
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
            // Не красят: Claude Code сам запускает форк-агентов, пока ты ничего не делаешь
            // (away_summary через ~3 мин простоя, prompt_suggestion, agent_summary) и сжимает
            // контекст в простое (idleCompaction). Настоящий субагент идёт внутри хода,
            // когда слот уже жёлтый от UserPromptSubmit/PreToolUse. Вывод по коду Claude Code
            // 2026-10-16; подтвердить по ~/.agentlight/hooks.jsonl после следующего away_summary.
            return .ignore
        case "PermissionRequest", "Elicitation", "StopFailure":
            return .set(.attn)
        case "Stop":
            return .set(.idle)
        case "Notification":
            // idle_prompt — таймер бездействия через 60 с после Stop, не блокировка (§1.3)
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
