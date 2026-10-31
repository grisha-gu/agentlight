import Foundation

public struct SessionRecord: Codable, Equatable, Sendable {
    public var sessionId: String
    public var cwd: String?
    public var transcriptPath: String?
    public var claudePid: Int32?
    public var terminal: TerminalRef?
    public var state: LightState
    public var lastEventAt: Date
    /// когда последний раз менялось состояние — для таймаута BUSY
    public var stateSince: Date

    public init(sessionId: String, cwd: String?, state: LightState, at now: Date) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.state = state
        self.lastEventAt = now
        self.stateSince = now
    }

    /// Имя проекта для подписи под светофором.
    public var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "—" }
        return (cwd as NSString).lastPathComponent
    }

    mutating func absorb(_ event: HookEvent, at now: Date) {
        lastEventAt = now
        // cwd в хуках — текущий каталог шелла агента, он гуляет по `cd`; проект — где агент запущен
        if self.cwd == nil, let cwd = event.cwd { self.cwd = cwd }
        if let t = event.transcriptPath { transcriptPath = t }
        if let x = event.agentlight {
            if let pid = x.claudePid { claudePid = pid }
            if let term = x.terminal { terminal = term }
        }
    }

    mutating func set(_ s: LightState, at now: Date) {
        if s != state { stateSince = now }
        state = s
    }
}

/// Слот держит сессию 15 с после `/clear`, чтобы новая сессия того же окна заехала в него же.
public struct Rebinding: Codable, Equatable, Sendable {
    public var cwd: String?
    public var claudePid: Int32?
    public var until: Date
}

public struct Slot: Codable, Equatable, Sendable {
    public var session: SessionRecord?
    public var rebinding: Rebinding?
    /// долгое нажатие: светофор погашен, пока не нажать долго ещё раз
    public var muted = false

    public init() {}

    public var isFree: Bool { session == nil }

    public var light: LightState {
        guard let s = session, !muted else { return .off }
        return s.state
    }
}
