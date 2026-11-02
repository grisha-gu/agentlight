import Darwin
import Foundation

/// Сбор идентичности терминала в `agentlight hook` (docs/05-host-macos.md §5.5).
/// Хук — дочерний процесс Claude Code: env и дерево процессов — его.
public enum TerminalCapture {
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "agentlight", "env"]

    public static func extras(environment env: [String: String] = ProcessInfo.processInfo.environment) -> HookExtras {
        let pid = claudePid()
        var term = terminalRef(environment: env, tty: controllingTTY())
        if term.tty == nil, let pid { term.tty = tty(of: pid) }
        // фоновая сессия под демоном Claude Code: её pty не окно — берём терминал вкладки,
        // где её смотрят (кнопка всё равно пересчитает это в момент нажатия)
        if let pid, let viewer = ClaudeSessions.viewer(of: pid, scanAttach: false).terminal { term = viewer }
        return HookExtras(claudePid: pid,
                          preferSlot: env["AGENTLIGHT_PREFER_SLOT"].flatMap { Int($0) },
                          terminal: term)
    }

    static func terminalRef(environment env: [String: String], tty: String?) -> TerminalRef {
        TerminalRef(
            termProgram: env["TERM_PROGRAM"],
            appBundleId: env["__CFBundleIdentifier"],
            itermSessionId: env["ITERM_SESSION_ID"],
            tmuxPane: env["TMUX_PANE"],
            tmuxSocket: env["TMUX"].map { String($0.split(separator: ",").first ?? "") },
            weztermPane: env["WEZTERM_PANE"],
            kittyWindowId: env["KITTY_WINDOW_ID"],
            tty: tty
        )
    }

    static func controllingTTY() -> String? {
        let fd = open("/dev/tty", O_RDONLY | O_NOCTTY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard let name = ttyname(fd) else { return nil }
        return String(cString: name)
    }

    /// Первый предок, который не оболочка: Claude Code запускает command-хук через `sh -c`.
    /// Имя процесса claude ненадёжно (нативная сборка называется версией, «2.1.3»).
    public static func claudePid() -> Int32? {
        var pid = getppid()
        for _ in 0..<8 {
            guard pid > 1, let info = procInfo(pid) else { return nil }
            if !shells.contains(info.name) { return pid }
            pid = info.ppid
        }
        return nil
    }

    static func tty(of pid: Int32) -> String? {
        guard let dev = procInfo(pid)?.tdev, dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    struct ProcInfo {
        var name: String
        var ppid: Int32
        var tdev: dev_t
        var start: Date
    }

    public static func startTime(of pid: Int32) -> Date? {
        procInfo(pid)?.start
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    static func procInfo(_ pid: Int32) -> ProcInfo? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let t = info.kp_proc.p_starttime
        return ProcInfo(name: name.hasPrefix("-") ? String(name.dropFirst()) : name,
                        ppid: info.kp_eproc.e_ppid, tdev: info.kp_eproc.e_tdev,
                        start: Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1e6))
    }

    /// Сессия без SessionStart (стартовала раньше демона или хуков): ищем процесс `claude`,
    /// запущенный в cwd сессии или в его ближайшем предке. Неоднозначно — не угадываем.
    public static func locateClaude(cwd: String) -> (pid: Int32, tty: String?, cwd: String)? {
        let found: [(pid: Int32, cwd: String)] = allPids().compactMap { pid in
            guard isClaude(pid), let dir = Self.cwd(of: pid),
                  cwd == dir || cwd.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/") else { return nil }
            return (pid, dir)
        }
        guard let deepest = found.map(\.cwd.count).max() else { return nil }
        let best = found.filter { $0.cwd.count == deepest }
        guard best.count == 1 else { return nil }
        return (best[0].pid, tty(of: best[0].pid), best[0].cwd)
    }

    static func allPids() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return pids.prefix(Int(max(n, 0))).filter { $0 > 0 }
    }

    /// Нативная сборка называется версией («2.1.295»), поэтому смотрим argv[0] и путь бинарника.
    static func isClaude(_ pid: Int32) -> Bool {
        if procInfo(pid)?.name == "claude" { return true }
        if let path = executablePath(pid), path.contains("/claude/versions/") || path.hasSuffix("/claude") {
            return true
        }
        return argv0(pid).map { ($0 as NSString).lastPathComponent == "claude" } ?? false
    }

    static func argv0(_ pid: Int32) -> String? {
        arguments(of: pid)?.first
    }

    public static func arguments(of pid: Int32) -> [String]? {
        procArgs(pid)?.args
    }

    /// Окружение чужого процесса того же пользователя (лежит в KERN_PROCARGS2 после argv).
    static func environment(of pid: Int32) -> [String: String]? {
        guard let env = procArgs(pid)?.env else { return nil }
        var out: [String: String] = [:]
        for kv in env {
            guard let eq = kv.firstIndex(of: "=") else { continue }
            out[String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
        }
        return out
    }

    static func procArgs(_ pid: Int32) -> (args: [String], env: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        // argc (int32), затем путь exec, нули, потом argv[0..argc), затем env до пустой строки
        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }
        while i < size && buf[i] == 0 { i += 1 }
        func next() -> String {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            defer { i += 1 }
            return String(decoding: buf[start..<i], as: UTF8.self)
        }
        var args: [String] = []
        while args.count < argc && i < size { args.append(next()) }
        var env: [String] = []
        while i < size && buf[i] != 0 { env.append(next()) }
        return (args, env)
    }

    static func cwd(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
