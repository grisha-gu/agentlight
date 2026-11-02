import Foundation

/// Публичный список сессий Claude Code: `claude agents --json` (в справке — «for scripting»).
/// В нём ровно настоящие сессии — интерактивные, `-p` и фоновые; вкладок-оболочек и заготовок
/// agent view нет (проверено на 2.1.316). Процесс на каждый вызов (~0,3 с), поэтому снимок
/// берётся раз в полминуты и служит сверкой для внутреннего реестра `ClaudeSessions`.
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

    /// nil — вывод не похож на список сессий (формат поменялся).
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
            case .noBinary: return "не нашёл бинарник claude"
            case .failed(let s): return "claude agents --json: \(s)"
            case .badOutput(let s): return "claude agents --json вернул не список сессий: \(s.prefix(120))"
            }
        }
    }

    /// Запустить `claude agents --json`. Блокирует до 10 с — звать не с главной очереди.
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
        guard p.terminationStatus == 0 else { return .failure(.failed("код выхода \(p.terminationStatus)")) }
        // снимок относится к моменту запуска: всё, что поменялось позже, он мог не увидеть
        guard let list = parse(data, takenAt: started) else {
            return .failure(.badOutput(String(decoding: data, as: UTF8.self)))
        }
        return .success(list)
    }

    /// Под launchd PATH минимальный: смотрим типовые места установки, потом бинарник
    /// любого живого процесса из реестра (нативная сборка — сам CLI).
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

/// Решение «положен ли сессии светофор» по двум источникам: внутренний реестр (быстрый, подробный,
/// но формат может смениться в любой версии) и публичный список (медленный, без деталей).
/// Где оба что-то знают и расходятся, побеждает публичный, а расхождение — сигнал, что реестр
/// поменялся (`problems`).
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

    /// Что про процесс говорит снимок списка; nil — снимок о нём судить не может.
    func hiddenByList(_ pid: Int32) -> Bool? {
        guard let l = listed else { return nil }
        // процесс появился или его запись переписали после снимка (отдал задачу, ушёл в фон)
        guard let start = startedAt(pid), start < l.takenAt else { return nil }
        if let m = registry.entries[pid]?.modifiedAt, m >= l.takenAt { return nil }
        if l.items[pid] != nil { return false }
        // прятать по списку — только процессы Claude Code, которые и так могли быть скрытыми:
        // с записью в реестре или заготовку. Остальное (чужой SDK, что-то новое) — показываем
        guard registry.entries[pid] != nil || arguments(pid)?.contains("--bg-spare") == true else { return nil }
        return true
    }

    public func isHidden(_ pid: Int32) -> Bool {
        hiddenByList(pid) ?? hiddenByRegistry(pid)
    }

    /// Вкладка-оболочка фоновой сессии — только из реестра (в списке этого нет), и только
    /// если сверка согласна, что та вкладка правда оболочка.
    public func parkedShell(of pid: Int32) -> Int32? {
        registry.parkedShell(of: pid).flatMap { isHidden($0) ? $0 : nil }
    }

    public func roles(isAlive: @escaping (Int32) -> Bool = TerminalCapture.isAlive) -> SlotAllocator.Roles {
        SlotAllocator.Roles(isHidden: isHidden,
                            parkedShell: { parkedShell(of: $0).flatMap { isAlive($0) ? $0 : nil } })
    }

    /// Признаки того, что реестр разошёлся с публичным списком, по процессам `pids`.
    public func problems(among pids: [Int32]) -> [String] {
        guard let l = listed else { return [] }
        var out: [String] = []
        let unregistered = l.items.keys.filter { pid in
            registry.entries[pid] == nil && (startedAt(pid).map { $0 < l.takenAt } ?? false)
        }
        if !unregistered.isEmpty {
            out.append("в реестре ~/.claude/sessions нет \(unregistered.count) из \(l.items.count) сессий, "
                + "которые видит claude agents (pid \(unregistered.sorted().map(String.init).joined(separator: ", ")))")
        }
        for pid in Set(pids).sorted() {
            guard let byList = hiddenByList(pid) else { continue }
            let byRegistry = hiddenByRegistry(pid)
            guard byList != byRegistry else { continue }
            let what = registry.entries[pid].map { "kind=\($0.kind ?? "?")" } ?? "без записи в реестре"
            out.append(byRegistry
                ? "pid \(pid) (\(what)): реестр прячет, а claude agents её видит — показываю"
                : "pid \(pid) (\(what)): реестр показывает, а claude agents её не видит — прячу")
        }
        return out
    }
}
