import AgentLightKit
import Foundation

let usage = """
agentlight — control AgentLight

  install-hooks [--settings PATH]   add hooks to ~/.claude/settings.json (other hooks are left alone)
  uninstall-hooks [--settings PATH] remove exactly our own hooks
  install-daemon                    LaunchAgent for AgentLight.app, start it
  uninstall-daemon                  stop and remove the LaunchAgent
  status                            slots, states, projects, pids, terminals
  doctor                            check the daemon, hooks, device
  test                              run through all states on the device and in the menu bar
  selftest                          device self-test animation
  focus <slot>                      same as a short button press
  mute <slot>                       same as a long press
  release <slot>                    free the slot
  pin <slot> [path]                 pin a project (current directory by default) to a slot
  unpin [path]
  brightness <0-255>
  replay <file.jsonl> [--live] [--speed N]
                                    run recorded hooks through the state machine (or into the live daemon)
  logs [-f]
  hook                              internal: SessionStart hook, stdin → daemon

Slots are numbered from 0 (device buttons from 1). There are `slot_count` slots from config.json
(4 by default): the first device shows 0..3, the second 4..7, and so on.
"""

func fail(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("agentlight: \(msg)\n".utf8))
    exit(code)
}

func loadConfig() -> Config {
    do { return try Config.load() } catch { fail("~/.agentlight/config.json: \(error)") }
}

var argv = Array(CommandLine.arguments.dropFirst())
guard !argv.isEmpty else {
    print(usage)
    exit(0)
}
let command = argv.removeFirst()

func option(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    let v = argv[i + 1]
    argv.removeSubrange(i...(i + 1))
    return v
}

func flag(_ name: String) -> Bool {
    guard let i = argv.firstIndex(of: name) else { return false }
    argv.remove(at: i)
    return true
}

func slotArg() -> Int {
    let count = loadConfig().slotCount
    guard let s = argv.first.flatMap({ Int($0) }), (0..<count).contains(s) else {
        fail("slot number 0..\(count - 1) required")
    }
    argv.removeFirst()
    return s
}

// MARK: - Daemon over HTTP

enum Daemon {
    static func request(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 2) -> Data? {
        let port = loadConfig().port
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, timeoutInterval: timeout)
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Data?
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                result = data ?? Data()
            }
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }

    static func status() -> StatusReport? {
        request("GET", "/status").flatMap { try? StateStore.decoder.decode(StatusReport.self, from: $0) }
    }

    static func control(_ c: ControlRequest) {
        // focus may be waiting on the TCC dialog "AgentLight wants to control Terminal"
        guard let data = request("POST", "/control", body: try! JSONEncoder().encode(c), timeout: 30) else {
            fail("daemon isn't responding (agentlight doctor)")
        }
        let reply = try? JSONDecoder().decode(ControlReply.self, from: data)
        print(reply?.message ?? "ok")
        if reply?.ok == false { exit(1) }
    }
}

// MARK: - Paths

/// Path to the CLI itself, with symlinks resolved (/usr/local/bin/agentlight → bundle).
/// argv[0] won't do: when run via PATH it's just "agentlight".
var cliPath: String {
    let url = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    return url.resolvingSymlinksInPath().path
}

var settingsURL: URL {
    if let p = option("--settings") { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
}

let agentLabel = "dev.grisha-gu.agentlight.daemon"
/// before 0.2.0 (bundle id com.agentlight.app); install-daemon removes it
let legacyAgentLabel = "com.agentlight.daemon"

func launchAgentURL(_ label: String = agentLabel) -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
}

@discardableResult
func run(_ tool: String, _ args: [String], quiet: Bool = false) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    if quiet {
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
    }
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

// MARK: - Commands

func hook() {
    // never fail and never make noise: any error here is noise in the agent's log
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard var obj = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else { exit(0) }
    let extras = TerminalCapture.extras()
    if let data = try? JSONEncoder().encode(extras), let x = try? JSONSerialization.jsonObject(with: data) {
        obj["agentlight"] = x
    }
    if let body = try? JSONSerialization.data(withJSONObject: obj) {
        _ = Daemon.request("POST", "/hook", body: body, timeout: 1)
    }
    exit(0)
}

func installHooks() {
    let url = settingsURL
    let installer = HookInstaller(port: loadConfig().port, cliPath: cliPath)
    do {
        let s = try HookInstaller.load(url)
        try HookInstaller.save(installer.install(into: s), to: url)
    } catch {
        fail("\(url.path): \(error)")
    }
    print("hooks written to \(url.path) (backup: settings.json.agentlight-backup)")
    print("SessionStart → \(installer.command)")
    print("\(HookInstaller.httpEvents.count) more events → \(installer.url)")
    print("Claude Code picks them up on the fly, no need to restart sessions.")
    if !cliPath.contains(".app/Contents/MacOS/") {
        print("⚠️  CLI isn't running from AgentLight.app — the SessionStart path will change after a rebuild.")
    }
}

func uninstallHooks() {
    let url = settingsURL
    let installer = HookInstaller(port: loadConfig().port, cliPath: cliPath)
    do {
        try HookInstaller.save(installer.uninstall(from: HookInstaller.load(url)), to: url)
    } catch {
        fail("\(url.path): \(error)")
    }
    print("AgentLight hooks removed from \(url.path)")
}

func installDaemon() {
    let cli = URL(fileURLWithPath: cliPath)
    let daemon = cli.deletingLastPathComponent().appendingPathComponent("agentlightd")
    guard cli.path.contains(".app/Contents/MacOS/"), FileManager.default.isExecutableFile(atPath: daemon.path) else {
        fail("run it from AgentLight.app (host/scripts/build-app.sh --install), now: \(cli.path)")
    }
    try? FileManager.default.createDirectory(at: Paths.home, withIntermediateDirectories: true)
    let plist: [String: Any] = [
        "Label": agentLabel,
        "ProgramArguments": [daemon.path],
        "RunAtLoad": true,
        "KeepAlive": ["SuccessfulExit": false],
        "ProcessType": "Interactive",
        "StandardOutPath": Paths.log.path,
        "StandardErrorPath": Paths.log.path,
    ]
    do {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: launchAgentURL().deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: launchAgentURL())
    } catch {
        fail("\(launchAgentURL().path): \(error)")
    }
    let domain = "gui/\(getuid())"
    if FileManager.default.fileExists(atPath: launchAgentURL(legacyAgentLabel).path) {
        run("/bin/launchctl", ["bootout", "\(domain)/\(legacyAgentLabel)"], quiet: true)
        try? FileManager.default.removeItem(at: launchAgentURL(legacyAgentLabel))
        print("old LaunchAgent \(legacyAgentLabel) removed")
    }
    run("/bin/launchctl", ["bootout", "\(domain)/\(agentLabel)"], quiet: true)
    guard run("/bin/launchctl", ["bootstrap", domain, launchAgentURL().path]) == 0 else {
        fail("launchctl bootstrap failed")
    }
    print("LaunchAgent installed: \(launchAgentURL().path)")
    print("daemon: \(daemon.path), log: \(Paths.log.path)")
}

func uninstallDaemon() {
    run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"], quiet: true)
    try? FileManager.default.removeItem(at: launchAgentURL())
    print("LaunchAgent removed")
}

let lightGlyph: [LightState: String] = [
    .off: "⚫ off ", .idle: "🟢 idle", .busy: "🟡 busy", .attn: "🔴 attn",
]

func describe(_ s: SessionRecord) -> String {
    var parts = [s.projectName, String(s.sessionId.prefix(8))]
    if let pid = s.claudePid { parts.append("pid \(pid)") }
    if let t = s.terminal {
        parts.append([t.termProgram, t.tty, t.tmuxPane.map { "tmux \($0)" }].compactMap { $0 }.joined(separator: " "))
    }
    return parts.joined(separator: "  ")
}

func status() {
    guard let st = Daemon.status() else {
        print("daemon isn't responding. Last saved state (\(Paths.state.path)):")
        guard let a = StateStore().load() else { return print("  none") }
        for (i, s) in a.slots.enumerated() {
            print("  \(i)  \(lightGlyph[s.light]!)  \(s.session.map(describe) ?? "—")")
        }
        exit(1)
    }
    print("agentlightd \(st.version), pid \(st.pid) — \(st.device)")
    for s in st.slots {
        var line = "  \(s.slot)  \(lightGlyph[s.light]!)  \(s.session.map(describe) ?? "—")"
        if s.muted { line += "  [muted]" }
        if s.rebinding { line += "  [waiting for /clear]" }
        print(line)
    }
    for s in st.overflow {
        print("  ·  no traffic light: \(describe(s))  (\(s.state.name))")
    }
    for s in st.background ?? [] {
        print("  ·  hidden (spare or shell tab): \(describe(s))  (\(s.state.name))")
    }
}

func doctor() {
    var problems = 0
    func check(_ ok: Bool, _ good: String, _ bad: String) {
        print(ok ? "✅ \(good)" : "❌ \(bad)")
        if !ok { problems += 1 }
    }
    let config = loadConfig()

    let st = Daemon.status()
    check(st != nil, "daemon responds on 127.0.0.1:\(config.port) (v\(st?.version ?? ""), pid \(st?.pid ?? 0))",
          "daemon doesn't respond on 127.0.0.1:\(config.port) — `agentlight install-daemon` or start agentlightd by hand")

    let agentInstalled = FileManager.default.fileExists(atPath: launchAgentURL().path)
    let agentLoaded = run("/bin/launchctl", ["print", "gui/\(getuid())/\(agentLabel)"], quiet: true) == 0
    check(agentInstalled && agentLoaded, "LaunchAgent installed and loaded",
          agentInstalled ? "LaunchAgent exists but isn't loaded — `agentlight install-daemon`"
                         : "LaunchAgent not installed — `agentlight install-daemon` (the daemon won't start at login)")

    let settings = (try? HookInstaller.load(settingsURL)) ?? [:]
    let installed = HookInstaller.installedEvents(in: settings)
    let expected = Set(HookInstaller.httpEvents + ["SessionStart"])
    let missing = expected.subtracting(installed).sorted()
    check(missing.isEmpty, "hooks on all \(expected.count) events in \(settingsURL.path)",
          installed.isEmpty ? "no hooks — `agentlight install-hooks`" : "no hooks on: \(missing.joined(separator: ", ")) — `agentlight install-hooks`")
    let wantURL = HookInstaller(port: config.port, cliPath: cliPath).url
    let urls = Set(((settings["hooks"] as? [String: Any]) ?? [:]).values
        .flatMap { ($0 as? [[String: Any]]) ?? [] }
        .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
        .compactMap { $0["url"] as? String }
        .filter { $0.hasPrefix("http://127.0.0.1:") })
    if !urls.isEmpty {
        check(urls == [wantURL], "hooks point at \(wantURL)", "hooks point at \(urls.sorted().joined(separator: ", ")), but the daemon is on \(wantURL)")
    }

    if let st {
        check(st.deviceConnected, st.device, "\(st.device) — plug in the device (the menu bar works without it)")
    }
    let ports = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []).filter { $0.hasPrefix("cu.usbmodem") }
    print("ℹ️  CDC ports: \(ports.isEmpty ? "none" : ports.map { "/dev/" + $0 }.joined(separator: ", "))")
    print("ℹ️  CLI: \(cliPath)")
    claudeRegistryCheck(check)
    switch st?.automation {
    case .granted:
        check(true, "Automation → Terminal allowed (focus from a button)", "")
    case .denied:
        check(false, "", "Automation → Terminal denied — System Settings → Privacy & Security → Automation → AgentLight → Terminal")
    case .notAsked:
        print("ℹ️  Automation → Terminal not asked yet — press a device button or `agentlight focus 0` and allow it")
    case .unknown:
        print("ℹ️  Automation → Terminal can't be checked: Terminal isn't running")
    case nil:
        break  // daemon doesn't respond, or it's an old one
    }
    exit(problems == 0 ? 0 : 1)
}

/// Cross-checks Claude Code's internal registry (`~/.claude/sessions`) against the public `claude agents --json`:
/// the registry is how traffic lights recognize shell tabs and agent view spares, and its format may change.
func claudeRegistryCheck(_ check: (Bool, String, String) -> Void) {
    let registry = ClaudeSessions.load()
    let version = registry.entries.values
        .max { ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }?.version ?? "?"
    let list: ClaudeAgentsList
    switch ClaudeAgentsList.fetch() {
    case .success(let l): list = l
    case .failure(.noBinary):
        print("ℹ️  claude not found — skipping the Claude Code registry cross-check")
        return
    case .failure(let e):
        check(false, "", "\(e) — background sessions are decided by the registry alone, without a cross-check")
        return
    }
    let live = registry.entries.keys.filter(TerminalCapture.isAlive)
    guard !list.items.isEmpty || !live.isEmpty else {
        print("ℹ️  no Claude Code sessions — nothing to cross-check the registry against")
        return
    }
    let census = ClaudeCensus(registry: registry, listed: list)
    let problems = census.problems(among: Array(live) + Array(list.items.keys))
    let hidden = live.filter(census.isHidden).count
    check(problems.isEmpty,
          "Claude Code \(version) registry matches claude agents (\(list.items.count) sessions, \(hidden) hidden)",
          "Claude Code \(version) registry diverged from claude agents — the format may have changed:\n"
            + problems.map { "     • \($0)" }.joined(separator: "\n"))
}

func pin(_ slot: Int, path: String?) {
    var c = loadConfig()
    let p = URL(fileURLWithPath: (path.map { ($0 as NSString).expandingTildeInPath }) ?? FileManager.default.currentDirectoryPath)
        .standardizedFileURL.path
    c.pins = c.pins.filter { $0.value != slot }
    c.pins[p] = slot
    save(c)
    print("\(p) → slot \(slot)")
}

func unpin(path: String?) {
    var c = loadConfig()
    let p = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath).standardizedFileURL.path
    guard c.pins.removeValue(forKey: p) != nil else { fail("\(p) isn't pinned") }
    save(c)
    print("\(p) unpinned")
}

func save(_ c: Config) {
    do { try c.save() } catch { fail("config.json: \(error)") }
    if Daemon.request("POST", "/control", body: try! JSONEncoder().encode(ControlRequest(cmd: .reload))) == nil {
        print("(daemon isn't running — will apply at startup)")
    }
}

func replay(_ path: String, live: Bool, speed: Double) {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("can't read \(path)") }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let local = DateFormatter()
    local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
    let config = loadConfig()
    var allocator = SlotAllocator(slotCount: config.slotCount)
    var prev: Date?
    var start = Date()
    for line in text.split(separator: "\n") {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
        let bodyObj = obj["body_json"] ?? obj
        guard let body = try? JSONSerialization.data(withJSONObject: bodyObj),
              let event = try? HookEvent.decode(body) else { continue }
        let atStr = obj["at"] as? String
        let at = atStr.flatMap { iso.date(from: $0) ?? local.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        let now = at ?? (prev ?? Date()).addingTimeInterval(1)
        if live {
            if let prev { Thread.sleep(forTimeInterval: max(0, now.timeIntervalSince(prev)) / speed) }
            _ = Daemon.request("POST", "/hook", body: body)
        } else if prev == nil {
            start = now
        }
        prev = now
        let before = allocator.lights
        let fx = allocator.handle(event, config: config, now: now)
        let t = String(format: "%7.1fs", now.timeIntervalSince(start))
        let detail = event.notificationType.map { "(\($0))" } ?? ""
        let lights = allocator.lights.map { lightGlyph[$0]!.prefix(1) }.joined(separator: " ")
        let mark = before != allocator.lights || !fx.welcome.isEmpty ? "→" : " "
        print("\(t)  \(lights) \(mark) \(event.name)\(detail) \(event.sessionId.prefix(8))")
    }
}

func logs(follow: Bool) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
    p.arguments = (follow ? ["-n", "50", "-F"] : ["-n", "100"]) + [Paths.log.path]
    try? p.run()
    p.waitUntilExit()
}

switch command {
case "hook": hook()
case "install-hooks": installHooks()
case "uninstall-hooks": uninstallHooks()
case "install-daemon": installDaemon()
case "uninstall-daemon": uninstallDaemon()
case "status": status()
case "doctor": doctor()
case "test": Daemon.control(ControlRequest(cmd: .test))
case "selftest": Daemon.control(ControlRequest(cmd: .selftest))
case "focus": Daemon.control(ControlRequest(cmd: .press, slot: slotArg()))
case "mute": Daemon.control(ControlRequest(cmd: .long, slot: slotArg()))
case "release": Daemon.control(ControlRequest(cmd: .release, slot: slotArg()))
case "pin":
    let s = slotArg()
    pin(s, path: argv.first)
case "unpin": unpin(path: argv.first)
case "brightness":
    guard let b = argv.first.flatMap({ UInt8($0) }) else { fail("brightness 0..255 required") }
    var c = loadConfig()
    c.brightness = b
    save(c)
    print("brightness \(b)")
case "replay":
    let live = flag("--live")
    let speed = option("--speed").flatMap(Double.init) ?? 1
    guard let path = argv.first else { fail("a .jsonl file required") }
    replay(path, live: live, speed: speed)
case "logs": logs(follow: flag("-f"))
case "-h", "--help", "help": print(usage)
default: fail("unknown command \(command)\n\n\(usage)", code: 64)
}
