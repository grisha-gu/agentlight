import Foundation

/// Claude Code process registry: `~/.claude/sessions/<pid>.json`, written by the CLI itself.
/// It shows which sessions are background ones, which tab became a shell, and which session
/// is the daemon's spare. The format is internal (checked on 2.1.309–2.1.316), so unknown
/// fields are ignored, and without a file we decide by argv.
public struct ClaudeSessions: Sendable {
    public struct Entry: Equatable, Sendable {
        public var pid: Int32
        public var sessionId: String?
        /// "interactive" — a session in its own tab, "bg" — under the Claude Code daemon
        public var kind: String?
        /// daemon background job id (8 hex), for `kind == "bg"`
        public var jobId: String?
        /// the tab was sent to the background: its session moved into job `parkedJobId`, and the
        /// process stayed as a screen (agent view / attached background session). Doesn't change when
        /// the user switches between sessions — what the tab shows right now is unknown
        public var parkedJobId: String?
        /// spare process the daemon keeps ready for the agent view input field.
        /// The flag disappears once a job is sent from agent view: from then on it's a regular background session
        public var spare: Bool
        public var name: String?
        /// Claude Code version that wrote the file
        public var version: String?
        /// when the file was last rewritten (changes with the session status)
        public var modifiedAt: Date?

        public var isParkedShell: Bool { kind == "interactive" && parkedJobId != nil }
        public var isSpare: Bool { kind == "bg" && spare }
    }

    public var entries: [Int32: Entry]

    public init(entries: [Int32: Entry] = [:]) {
        self.entries = entries
    }

    /// `AGENTLIGHT_CLAUDE_SESSIONS` — override the registry directory (to test a format change).
    public static var directory: URL {
        if let dir = ProcessInfo.processInfo.environment["AGENTLIGHT_CLAUDE_SESSIONS"] {
            return URL(fileURLWithPath: dir)
        }
        let base = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return base.appendingPathComponent("sessions")
    }

    public static func load(from dir: URL = directory) -> ClaudeSessions {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var out: [Int32: Entry] = [:]
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f), var e = parse(data) else { continue }
            e.modifiedAt = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            out[e.pid] = e
        }
        return ClaudeSessions(entries: out)
    }

    static func parse(_ data: Data) -> Entry? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (o["pid"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return Entry(pid: pid,
                     sessionId: o["sessionId"] as? String,
                     kind: o["kind"] as? String,
                     jobId: o["jobId"] as? String,
                     parkedJobId: o["parkedJobId"] as? String,
                     spare: (o["spare"] as? Bool) ?? false,
                     name: o["name"] as? String,
                     version: o["version"] as? String)
    }

    // MARK: - Decisions

    /// The registry looks like the one we know: there are entries with a recognizable `kind`. An empty or
    /// unrecognizable registry means Claude Code changed the format or location.
    public var isRecognized: Bool {
        entries.values.contains { $0.kind == "interactive" || $0.kind == "bg" }
    }

    /// This process's session gets no traffic light: the daemon's spare or a shell tab whose
    /// session moved into a background job. Without a registry file — by argv: an unclaimed spare
    /// (`--bg-spare`) doesn't write a file yet, but SessionStart already fires. But argv stays
    /// `--bg-spare` even after the spare has been given a job, so we trust it only while
    /// the registry as a whole is recognizable — otherwise an extra lamp beats hidden work.
    public func isHidden(_ pid: Int32, arguments: (Int32) -> [String]?) -> Bool {
        if let e = entries[pid] { return e.isSpare || e.isParkedShell }
        return isRecognized && arguments(pid)?.contains("--bg-spare") == true
    }

    /// The shell tab from which background session `pid` was sent to the background.
    public func parkedShell(of pid: Int32) -> Int32? {
        guard let job = entries[pid]?.jobId, entries[pid]?.kind == "bg" else { return nil }
        return entries.values.first { $0.isParkedShell && $0.parkedJobId == job }?.pid
    }

    /// Whether the `claude attach <id|name>` argument matches background session `e`
    /// (the CLI accepts a job id, a session id prefix or part of the name).
    static func attachTarget(_ arg: String, matches e: Entry) -> Bool {
        guard !arg.isEmpty else { return false }
        if arg == e.jobId { return true }
        if let sid = e.sessionId, arg.count >= 4, sid.hasPrefix(arg) { return true }
        if let name = e.name, name.localizedCaseInsensitiveContains(arg) { return true }
        return false
    }

    /// `claude attach X` → X; nil if it's not an attach.
    static func attachArgument(_ args: [String]) -> String? {
        guard args.count >= 3, args[1] == "attach" else { return nil }
        return args[2]
    }
}

// MARK: - Processes (I/O)

extension ClaudeSessions {
    /// The tab where background session `pid` is being watched: a live `claude attach` to its job,
    /// otherwise the shell tab it was sent to the background from (most likely showing it,
    /// but the user may have switched to agent view). nil — not a background session, or no window.
    /// `scanAttach: false` — without walking all processes (for the hook, which fires on every tool call).
    public static func viewer(of pid: Int32, scanAttach: Bool = true) -> (job: String?, terminal: TerminalRef?) {
        let reg = load()
        guard let e = reg.entries[pid], e.kind == "bg" else { return (nil, nil) }
        if let client = (scanAttach ? attachClient(for: e) : nil) ?? reg.parkedShell(of: pid),
           TerminalCapture.isAlive(client), let tty = TerminalCapture.tty(of: client) {
            return (e.jobId, TerminalCapture.terminalRef(environment: TerminalCapture.environment(of: client) ?? [:],
                                                         tty: tty))
        }
        return (e.jobId, nil)
    }

    static func attachClient(for e: Entry) -> Int32? {
        TerminalCapture.allPids().first { pid in
            guard let args = TerminalCapture.arguments(of: pid), let arg = attachArgument(args),
                  TerminalCapture.isClaude(pid) else { return false }
            return attachTarget(arg, matches: e)
        }
    }
}
