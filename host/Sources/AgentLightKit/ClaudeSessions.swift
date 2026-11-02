import Foundation

/// Реестр процессов Claude Code: `~/.claude/sessions/<pid>.json`, который пишет сам CLI.
/// По нему видно, какие сессии фоновые, какая вкладка стала оболочкой, а какая сессия —
/// запасная заготовка демона. Формат внутренний (проверен на 2.1.309–2.1.316), поэтому
/// неизвестные поля игнорируем, а без файла решаем по argv.
public struct ClaudeSessions: Sendable {
    public struct Entry: Equatable, Sendable {
        public var pid: Int32
        public var sessionId: String?
        /// "interactive" — сессия в своей вкладке, "bg" — под демоном Claude Code
        public var kind: String?
        /// id фоновой задачи демона (8 hex), у `kind == "bg"`
        public var jobId: String?
        /// вкладку отправили в фон: её сессия уехала в задачу `parkedJobId`, а сам процесс
        /// остался экраном (agent view / подключённая фоновая сессия). Не меняется, когда
        /// пользователь переключается между сессиями, — что вкладка показывает сейчас, неизвестно
        public var parkedJobId: String?
        /// запасной процесс, который демон держит под поле ввода в agent view.
        /// Флаг пропадает, когда из agent view отправили задачу: дальше это обычная фоновая сессия
        public var spare: Bool
        public var name: String?

        public var isParkedShell: Bool { kind == "interactive" && parkedJobId != nil }
        public var isSpare: Bool { kind == "bg" && spare }
    }

    public var entries: [Int32: Entry]

    public init(entries: [Int32: Entry] = [:]) {
        self.entries = entries
    }

    public static var directory: URL {
        let base = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        return base.appendingPathComponent("sessions")
    }

    public static func load(from dir: URL = directory) -> ClaudeSessions {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [Int32: Entry] = [:]
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f), let e = parse(data) else { continue }
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
                     name: o["name"] as? String)
    }

    // MARK: - Решения

    /// Сессии этого процесса светофор не положен: запасная заготовка демона или вкладка-оболочка,
    /// чья сессия уехала в фоновую задачу. Без файла в реестре — по argv: незанятая заготовка
    /// (`--bg-spare`) файла ещё не пишет, а SessionStart уже отрабатывает.
    public func isHidden(_ pid: Int32, arguments: (Int32) -> [String]?) -> Bool {
        if let e = entries[pid] { return e.isSpare || e.isParkedShell }
        return arguments(pid)?.contains("--bg-spare") == true
    }

    /// Вкладка-оболочка, из которой фоновую сессию `pid` отправили в фон.
    public func parkedShell(of pid: Int32) -> Int32? {
        guard let job = entries[pid]?.jobId, entries[pid]?.kind == "bg" else { return nil }
        return entries.values.first { $0.isParkedShell && $0.parkedJobId == job }?.pid
    }

    /// Совпадает ли аргумент `claude attach <id|name>` с фоновой сессией `e`
    /// (CLI принимает id задачи, начало id сессии или часть имени).
    static func attachTarget(_ arg: String, matches e: Entry) -> Bool {
        guard !arg.isEmpty else { return false }
        if arg == e.jobId { return true }
        if let sid = e.sessionId, arg.count >= 4, sid.hasPrefix(arg) { return true }
        if let name = e.name, name.localizedCaseInsensitiveContains(arg) { return true }
        return false
    }

    /// `claude attach X` → X; nil, если это не attach.
    static func attachArgument(_ args: [String]) -> String? {
        guard args.count >= 3, args[1] == "attach" else { return nil }
        return args[2]
    }
}

// MARK: - Процессы (ввод-вывод)

extension ClaudeSessions {
    /// Снимок реестра для решений аллокатора.
    public static func roles() -> SlotAllocator.Roles {
        let reg = load()
        return SlotAllocator.Roles(
            isHidden: { reg.isHidden($0, arguments: TerminalCapture.arguments(of:)) },
            parkedShell: { pid in reg.parkedShell(of: pid).flatMap { TerminalCapture.isAlive($0) ? $0 : nil } }
        )
    }

    /// Вкладка, в которой смотрят фоновую сессию `pid`: живой `claude attach` на её задачу,
    /// иначе вкладка-оболочка, из которой её отправили в фон (скорее всего показывает её же,
    /// но пользователь мог переключиться в agent view). nil — сессия не фоновая или окна нет.
    /// `scanAttach: false` — без обхода всех процессов (для хука, он дёргается на каждый инструмент).
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
