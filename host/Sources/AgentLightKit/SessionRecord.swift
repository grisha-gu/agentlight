import Foundation

public struct SessionRecord: Codable, Equatable, Sendable {
    public var sessionId: String
    public var cwd: String?
    public var transcriptPath: String?
    public var claudePid: Int32?
    public var terminal: TerminalRef?
    public var state: LightState
    public var lastEventAt: Date
    /// when the state last changed — for the BUSY timeout
    public var stateSince: Date

    public init(sessionId: String, cwd: String?, state: LightState, at now: Date) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.state = state
        self.lastEventAt = now
        self.stateSince = now
    }

    /// Project name for the caption under the traffic light.
    public var projectName: String {
        guard let cwd, !cwd.isEmpty else { return "—" }
        return (cwd as NSString).lastPathComponent
    }

    mutating func absorb(_ event: HookEvent, at now: Date) {
        lastEventAt = now
        // cwd in hooks is the agent shell's current directory, it wanders with `cd`; the project is where the agent was started
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

/// A slot holds a session for 15 s after `/clear` so the new session of the same window lands in it.
public struct Rebinding: Codable, Equatable, Sendable {
    public var cwd: String?
    public var claudePid: Int32?
    public var until: Date
}

public struct Slot: Codable, Equatable, Sendable {
    public var session: SessionRecord?
    public var rebinding: Rebinding?
    /// long press: the traffic light stays dark until another long press
    public var muted = false

    public init() {}

    public var isFree: Bool { session == nil }

    public var light: LightState {
        guard let s = session, !muted else { return .off }
        return s.state
    }
}
