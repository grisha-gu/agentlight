import AgentLightKit
import Foundation

let usage = """
agentlight — управление AgentLight

  install-hooks [--settings PATH]   дописать хуки в ~/.claude/settings.json (чужие не трогаются)
  uninstall-hooks [--settings PATH] убрать ровно свои хуки
  install-daemon                    LaunchAgent для AgentLight.app, запуск
  uninstall-daemon                  остановить и убрать LaunchAgent
  status                            слоты, состояния, проекты, pid, терминалы
  doctor                            проверить демон, хуки, устройство
  test                              прогнать все состояния на устройстве и в строке меню
  selftest                          анимация самопроверки устройства
  focus <slot>                      то же, что короткое нажатие кнопки
  mute <slot>                       то же, что долгое нажатие
  release <slot>                    освободить слот
  pin <slot> [path]                 закрепить проект (по умолчанию текущий каталог) за слотом
  unpin [path]
  brightness <0-255>
  replay <file.jsonl> [--live] [--speed N]
                                    прогнать записанные хуки через стейт-машину (или в живой демон)
  logs [-f]
  hook                              внутреннее: SessionStart-хук, stdin → демон

Слоты нумеруются с 0 (кнопки на устройстве — с 1). Слотов `slot_count` из config.json
(по умолчанию 4): первое устройство показывает 0..3, второе — 4..7 и т. д.
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
        fail("нужен номер слота 0..\(count - 1)")
    }
    argv.removeFirst()
    return s
}

// MARK: - Демон по HTTP

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
        // фокус может ждать диалог TCC «AgentLight хочет управлять Terminal»
        guard let data = request("POST", "/control", body: try! JSONEncoder().encode(c), timeout: 30) else {
            fail("демон не отвечает (agentlight doctor)")
        }
        let reply = try? JSONDecoder().decode(ControlReply.self, from: data)
        print(reply?.message ?? "ok")
        if reply?.ok == false { exit(1) }
    }
}

// MARK: - Пути

/// Путь к самому CLI, с раскрытыми симлинками (/usr/local/bin/agentlight → бандл).
/// argv[0] не годится: при запуске через PATH там просто «agentlight».
var cliPath: String {
    let url = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    return url.resolvingSymlinksInPath().path
}

var settingsURL: URL {
    if let p = option("--settings") { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
}

let agentLabel = "com.agentlight.daemon"
var launchAgentURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
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

// MARK: - Команды

func hook() {
    // никогда не падать и не шуметь: любая ошибка здесь — шум в логе агента
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
    print("хуки записаны в \(url.path) (резервная копия: settings.json.agentlight-backup)")
    print("SessionStart → \(installer.command)")
    print("ещё \(HookInstaller.httpEvents.count) событий → \(installer.url)")
    print("Claude Code подхватит их на лету, перезапуск сессий не нужен.")
    if !cliPath.contains(".app/Contents/MacOS/") {
        print("⚠️  CLI запущен не из AgentLight.app — путь в SessionStart поменяется после пересборки.")
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
    print("хуки AgentLight убраны из \(url.path)")
}

func installDaemon() {
    let cli = URL(fileURLWithPath: cliPath)
    let daemon = cli.deletingLastPathComponent().appendingPathComponent("agentlightd")
    guard cli.path.contains(".app/Contents/MacOS/"), FileManager.default.isExecutableFile(atPath: daemon.path) else {
        fail("запускай из AgentLight.app (host/scripts/build-app.sh --install), сейчас: \(cli.path)")
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
        try FileManager.default.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: launchAgentURL)
    } catch {
        fail("\(launchAgentURL.path): \(error)")
    }
    let domain = "gui/\(getuid())"
    run("/bin/launchctl", ["bootout", "\(domain)/\(agentLabel)"], quiet: true)
    guard run("/bin/launchctl", ["bootstrap", domain, launchAgentURL.path]) == 0 else {
        fail("launchctl bootstrap не прошёл")
    }
    print("LaunchAgent установлен: \(launchAgentURL.path)")
    print("демон: \(daemon.path), лог: \(Paths.log.path)")
}

func uninstallDaemon() {
    run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(agentLabel)"], quiet: true)
    try? FileManager.default.removeItem(at: launchAgentURL)
    print("LaunchAgent убран")
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
        print("демон не отвечает. Последнее сохранённое состояние (\(Paths.state.path)):")
        guard let a = StateStore().load() else { return print("  нет") }
        for (i, s) in a.slots.enumerated() {
            print("  \(i)  \(lightGlyph[s.light]!)  \(s.session.map(describe) ?? "—")")
        }
        exit(1)
    }
    print("agentlightd \(st.version), pid \(st.pid) — \(st.device)")
    for s in st.slots {
        var line = "  \(s.slot)  \(lightGlyph[s.light]!)  \(s.session.map(describe) ?? "—")"
        if s.muted { line += "  [заглушен]" }
        if s.rebinding { line += "  [ждёт /clear]" }
        print(line)
    }
    for s in st.overflow {
        print("  ·  без светофора: \(describe(s))  (\(s.state.name))")
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
    check(st != nil, "демон отвечает на 127.0.0.1:\(config.port) (v\(st?.version ?? ""), pid \(st?.pid ?? 0))",
          "демон не отвечает на 127.0.0.1:\(config.port) — `agentlight install-daemon` или запусти agentlightd руками")

    let agentInstalled = FileManager.default.fileExists(atPath: launchAgentURL.path)
    let agentLoaded = run("/bin/launchctl", ["print", "gui/\(getuid())/\(agentLabel)"], quiet: true) == 0
    check(agentInstalled && agentLoaded, "LaunchAgent установлен и загружен",
          agentInstalled ? "LaunchAgent есть, но не загружен — `agentlight install-daemon`"
                         : "LaunchAgent не установлен — `agentlight install-daemon` (демон не стартует при входе)")

    let settings = (try? HookInstaller.load(settingsURL)) ?? [:]
    let installed = HookInstaller.installedEvents(in: settings)
    let expected = Set(HookInstaller.httpEvents + ["SessionStart"])
    let missing = expected.subtracting(installed).sorted()
    check(missing.isEmpty, "хуки на все \(expected.count) событий в \(settingsURL.path)",
          installed.isEmpty ? "хуков нет — `agentlight install-hooks`" : "нет хуков на: \(missing.joined(separator: ", ")) — `agentlight install-hooks`")
    let wantURL = HookInstaller(port: config.port, cliPath: cliPath).url
    let urls = Set(((settings["hooks"] as? [String: Any]) ?? [:]).values
        .flatMap { ($0 as? [[String: Any]]) ?? [] }
        .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
        .compactMap { $0["url"] as? String }
        .filter { $0.hasPrefix("http://127.0.0.1:") })
    if !urls.isEmpty {
        check(urls == [wantURL], "хуки смотрят на \(wantURL)", "хуки смотрят на \(urls.sorted().joined(separator: ", ")), а демон — на \(wantURL)")
    }

    if let st {
        check(st.deviceConnected, st.device, "\(st.device) — подключи пульт (без него работает строка меню)")
    }
    let ports = ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []).filter { $0.hasPrefix("cu.usbmodem") }
    print("ℹ️  CDC-порты: \(ports.isEmpty ? "нет" : ports.map { "/dev/" + $0 }.joined(separator: ", "))")
    print("ℹ️  CLI: \(cliPath)")
    print("ℹ️  Automation → Terminal понадобится на M5 (фокус по кнопке)")
    exit(problems == 0 ? 0 : 1)
}

func pin(_ slot: Int, path: String?) {
    var c = loadConfig()
    let p = URL(fileURLWithPath: (path.map { ($0 as NSString).expandingTildeInPath }) ?? FileManager.default.currentDirectoryPath)
        .standardizedFileURL.path
    c.pins = c.pins.filter { $0.value != slot }
    c.pins[p] = slot
    save(c)
    print("\(p) → слот \(slot)")
}

func unpin(path: String?) {
    var c = loadConfig()
    let p = URL(fileURLWithPath: path ?? FileManager.default.currentDirectoryPath).standardizedFileURL.path
    guard c.pins.removeValue(forKey: p) != nil else { fail("\(p) не закреплён") }
    save(c)
    print("\(p) откреплён")
}

func save(_ c: Config) {
    do { try c.save() } catch { fail("config.json: \(error)") }
    if Daemon.request("POST", "/control", body: try! JSONEncoder().encode(ControlRequest(cmd: .reload))) == nil {
        print("(демон не запущен — применится при старте)")
    }
}

func replay(_ path: String, live: Bool, speed: Double) {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("не читается \(path)") }
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
    guard let b = argv.first.flatMap({ UInt8($0) }) else { fail("нужна яркость 0..255") }
    var c = loadConfig()
    c.brightness = b
    save(c)
    print("яркость \(b)")
case "replay":
    let live = flag("--live")
    let speed = option("--speed").flatMap(Double.init) ?? 1
    guard let path = argv.first else { fail("нужен файл .jsonl") }
    replay(path, live: live, speed: speed)
case "logs": logs(follow: flag("-f"))
case "-h", "--help", "help": print(usage)
default: fail("неизвестная команда \(command)\n\n\(usage)", code: 64)
}
