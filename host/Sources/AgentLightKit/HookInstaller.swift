import Foundation

/// Merges our hooks into `~/.claude/settings.json` and removes them (docs/05-host-macos.md §5.4).
/// Other hooks are left alone; ours are recognized by the daemon URL and the `agentlight hook` command.
public struct HookInstaller {
    /// Everything except SessionStart is http: forking a process on every PreToolUse is too expensive.
    public static let httpEvents = [
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "PermissionDenied", "Notification", "Elicitation",
        "SubagentStart", "SubagentStop", "Stop", "StopFailure", "SessionEnd",
    ]

    public var url: String
    public var command: String

    public init(port: UInt16, cliPath: String) {
        url = "http://127.0.0.1:\(port)/hook"
        command = "'\(cliPath)' hook"
    }

    public func install(into settings: [String: Any]) -> [String: Any] {
        var s = uninstall(from: settings)
        var hooks = s["hooks"] as? [String: Any] ?? [:]
        func add(_ event: String, _ hook: [String: Any]) {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [hook]])
            hooks[event] = groups
        }
        // command, because SessionStart needs the terminal env (tty, TERM_PROGRAM, claude pid)
        add("SessionStart", ["type": "command", "command": command, "async": true, "timeout": 5])
        for e in Self.httpEvents {
            add(e, ["type": "http", "url": url, "async": true, "timeout": 2])
        }
        s["hooks"] = hooks
        return s
    }

    public func uninstall(from settings: [String: Any]) -> [String: Any] {
        var s = settings
        guard var hooks = s["hooks"] as? [String: Any] else { return s }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let list = group["hooks"] as? [[String: Any]] else { return group }
                let rest = list.filter { !isOurs($0) }
                if rest.isEmpty { return nil }
                var g = group
                g["hooks"] = rest
                return g
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        s["hooks"] = hooks.isEmpty ? nil : hooks
        return s
    }

    /// Events our hooks are installed on.
    public static func installedEvents(in settings: [String: Any]) -> Set<String> {
        guard let hooks = settings["hooks"] as? [String: Any] else { return [] }
        var found: Set<String> = []
        for (event, value) in hooks {
            for group in value as? [[String: Any]] ?? [] {
                for h in group["hooks"] as? [[String: Any]] ?? [] where isAgentLight(h) {
                    found.insert(event)
                }
            }
        }
        return found
    }

    private func isOurs(_ hook: [String: Any]) -> Bool {
        Self.isAgentLight(hook) || (hook["url"] as? String) == url
    }

    static func isAgentLight(_ hook: [String: Any]) -> Bool {
        if let u = hook["url"] as? String, u.hasPrefix("http://127.0.0.1:"), u.hasSuffix("/hook") {
            return true
        }
        if let c = hook["command"] as? String {
            let trimmed = c.trimmingCharacters(in: .whitespaces)
            return trimmed.hasSuffix("agentlight' hook") || trimmed.hasSuffix("agentlight hook")
        }
        return false
    }

    // MARK: - File

    public static func load(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [:] }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return obj
    }

    /// With a backup next to it: settings.json is someone else's file, it must not get corrupted.
    public static func save(_ settings: [String: Any], to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("agentlight-backup")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: url, to: backup)
        }
        var data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try AtomicFile.write(data, to: url)
    }
}
