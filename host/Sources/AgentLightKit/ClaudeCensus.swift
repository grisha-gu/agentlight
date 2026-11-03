import Foundation

/// Public list of Claude Code sessions: `claude agents --json` (the help says "for scripting").
/// It holds exactly the real sessions — interactive, `-p` and background; no shell tabs or agent view
/// spares (checked on 2.1.316). One process per call (~0.3 s), so the snapshot is taken
/// every half minute and serves as a cross-check for the internal `ClaudeSessions` registry.
public struct ClaudeAgentsList: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var pid: Int32
        public var kind: String?
        public var id: String?
        public var sessionId: String?
    }

    public var items: [Int32: Item]
    public var takenAt: Date

    public init(items: [Int32: Item], takenAt: Date) {
        self.items = items
        self.takenAt = takenAt
    }

    /// nil — the output doesn't look like a session list (the format changed).
    public static func parse(_ data: Data, takenAt: Date) -> ClaudeAgentsList? {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var items: [Int32: Item] = [:]
        for o in arr {
            guard let pid = (o["pid"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
            items[pid] = Item(pid: pid, kind: o["kind"] as? String, id: o["id"] as? String,
                              sessionId: o["sessionId"] as? String)
        }
        return ClaudeAgentsList(items: items, takenAt: takenAt)
    }

    public enum FetchError: Error, CustomStringConvertible {
        case noBinary
        case failed(String)
        case badOutput(String)

        public var description: String {
            switch self {
            case .noBinary: return "claude binary not found"
            case .failed(let s): return "claude agents --json: \(s)"
            case .badOutput(let s): return "claude agents --json returned something other than a session list: \(s.prefix(120))"
            }
        }
    }

    /// Run `claude agents --json`. Blocks for up to 10 s — don't call it on the main queue.
    public static func fetch() -> Result<ClaudeAgentsList, FetchError> {
        guard let bin = claudeBinary() else { return .failure(.noBinary) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["agents", "--json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let started = Date()
        do { try p.run() } catch { return .failure(.failed("\(error)")) }
        let killer = DispatchWorkItem { p.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else { return .failure(.failed("exit code \(p.terminationStatus)")) }
        // the snapshot is as of launch time: anything that changed later it may have missed
        guard let list = parse(data, takenAt: started) else {
            return .failure(.badOutput(String(decoding: data, as: UTF8.self)))
        }
        return .success(list)
    }

    /// Under launchd PATH is minimal: check the usual install locations, then the binary
    /// of any live process from the registry (in the native build that's the CLI itself).
    static func claudeBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fm = FileManager.default
        if let found = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                        "\(home)/.claude/local/claude"].first(where: fm.isExecutableFile) {
            return found
        }
        return ClaudeSessions.load().entries.keys.lazy.compactMap(TerminalCapture.executablePath).first
    }
}

/// Deciding "does this session get a traffic light" from two sources: the internal registry (fast, detailed,
/// but the format may change in any version) and the public list (slow, no details).
/// Where both know something and disagree, the public one wins, and the disagreement is a sign that
/// the registry has changed (`problems`).
public struct ClaudeCensus {
    public var registry: ClaudeSessions
    public var listed: ClaudeAgentsList?
    var arguments: (Int32) -> [String]?
    var startedAt: (Int32) -> Date?

    public init(registry: ClaudeSessions, listed: ClaudeAgentsList?,
                arguments: @escaping (Int32) -> [String]? = TerminalCapture.arguments(of:),
                startedAt: @escaping (Int32) -> Date? = TerminalCapture.startTime(of:)) {
        self.registry = registry
        self.listed = listed
        self.arguments = arguments
        self.startedAt = startedAt
    }

    func hiddenByRegistry(_ pid: Int32) -> Bool {
        registry.isHidden(pid, arguments: arguments)
    }

    /// What the list snapshot says about the process; nil — the snapshot can't judge it.
    func hiddenByList(_ pid: Int32) -> Bool? {
        guard let l = listed else { return nil }
        // the process appeared, or its entry was rewritten after the snapshot (gave away a job, went to background)
        guard let start = startedAt(pid), start < l.takenAt else { return nil }
        if let m = registry.entries[pid]?.modifiedAt, m >= l.takenAt { return nil }
        if l.items[pid] != nil { return false }
        // hide by the list only Claude Code processes that could have been hidden anyway:
        // with a registry entry, or a spare. Everything else (a foreign SDK, something new) — show
        guard registry.entries[pid] != nil || arguments(pid)?.contains("--bg-spare") == true else { return nil }
        return true
    }

    public func isHidden(_ pid: Int32) -> Bool {
        hiddenByList(pid) ?? hiddenByRegistry(pid)
    }

    /// Shell tab of a background session — only from the registry (the list doesn't have it), and only
    /// if the cross-check agrees that tab really is a shell.
    public func parkedShell(of pid: Int32) -> Int32? {
        registry.parkedShell(of: pid).flatMap { isHidden($0) ? $0 : nil }
    }

    public func roles(isAlive: @escaping (Int32) -> Bool = TerminalCapture.isAlive) -> SlotAllocator.Roles {
        SlotAllocator.Roles(isHidden: isHidden,
                            parkedShell: { parkedShell(of: $0).flatMap { isAlive($0) ? $0 : nil } })
    }

    /// Signs that the registry has diverged from the public list, for processes `pids`.
    public func problems(among pids: [Int32]) -> [String] {
        guard let l = listed else { return [] }
        var out: [String] = []
        let unregistered = l.items.keys.filter { pid in
            registry.entries[pid] == nil && (startedAt(pid).map { $0 < l.takenAt } ?? false)
        }
        if !unregistered.isEmpty {
            out.append("~/.claude/sessions registry is missing \(unregistered.count) of \(l.items.count) sessions "
                + "that claude agents sees (pid \(unregistered.sorted().map(String.init).joined(separator: ", ")))")
        }
        for pid in Set(pids).sorted() {
            guard let byList = hiddenByList(pid) else { continue }
            let byRegistry = hiddenByRegistry(pid)
            guard byList != byRegistry else { continue }
            let what = registry.entries[pid].map { "kind=\($0.kind ?? "?")" } ?? "no registry entry"
            out.append(byRegistry
                ? "pid \(pid) (\(what)): registry hides it, but claude agents sees it — showing"
                : "pid \(pid) (\(what)): registry shows it, but claude agents doesn't see it — hiding")
        }
        return out
    }
}
