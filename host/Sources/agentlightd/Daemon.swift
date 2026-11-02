import AgentLightKit
import AppKit

/// Склейка: хуки → SlotAllocator → устройство и строка меню. Всё на главной очереди.
final class Daemon {
    private(set) var config: Config
    private(set) var allocator: SlotAllocator
    let link: DeviceLink
    private let store = StateStore()
    private let server: HTTPServer
    private let focuser = FocusRunner()
    private let transcripts = TranscriptWatcher()
    private var recorder: FileHandle?
    private let hookLog = RotatingLog(url: Paths.home.appendingPathComponent("hooks.jsonl"), maxBytes: 5_000_000)
    private var sweepTimer: Timer?
    private var saveScheduled = false
    private var asleepSince: Date?

    /// временная подмена огней на время `agentlight test`
    private var override: [LightState]?
    /// слот → когда закончится welcome-анимация
    private(set) var welcomeUntil: [Int: Date] = [:]

    /// UI подписывается сюда; вызывается после любого изменения
    var onChange: (() -> Void)?

    init(config: Config, transports: [DeviceTransport], recordTo: URL?) {
        self.config = config
        var allocator = store.load() ?? SlotAllocator(slotCount: config.slotCount)
        _ = allocator.resize(to: config.slotCount, now: Date())  // slot_count правили, пока демон стоял
        self.allocator = allocator
        link = DeviceLink(transports: transports, config: config)
        server = HTTPServer(port: config.port)
        if let recordTo {
            FileManager.default.createFile(atPath: recordTo.path, contents: nil)
            recorder = try? FileHandle(forWritingTo: recordTo)
            _ = try? recorder?.seekToEnd()
        }
    }

    var lights: [LightState] { override ?? allocator.lights }

    func start() throws {
        server.onHook = { [weak self] body in
            DispatchQueue.main.async { self?.hook(body) }
        }
        server.handler = { [weak self] req, reply in
            DispatchQueue.main.async {
                guard let self else { return reply(.notFound) }
                self.route(req, reply)
            }
        }
        server.onFailure = { err in
            Log.error("HTTP: \(err) — порт \(self.config.port) занят? Второй демон?")
            DispatchQueue.main.async { exit(2) }
        }
        try server.start()
        Log.info("agentlightd \(AgentLightVersion.string): слушаю 127.0.0.1:\(config.port)")

        transcripts.onInterrupt = { [weak self] id in
            guard let self else { return }
            let fx = self.allocator.interrupted(id, now: Date())
            if fx.changed { Log.info("Esc в \(id.prefix(8)): прерван → idle") }
            self.apply(fx)
        }

        link.onButton = { [weak self] slot, g in self?.button(slot: slot, g) }
        link.onStatusChange = { [weak self] in self?.onChange?() }
        link.start()

        // после перезапуска демона часть агентов из state.json могла умереть
        apply(allocator.sweep(config: config, now: Date(), isAlive: TerminalCapture.isAlive,
                              isBackground: TerminalCapture.isBackground))
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.apply(self.allocator.sweep(config: self.config, now: Date(), isAlive: TerminalCapture.isAlive,
                                            isBackground: TerminalCapture.isBackground))
            self.transcripts.sync(self.allocator.transcripts)  // файл новой сессии мог появиться позже хука
        }

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Log.info("сон: гашу светофоры")
            self?.asleepSince = self?.asleepSince ?? Date()  // сон из DarkWake — без просыпания между ними
            self?.link.pause()
        }
        // DarkWake → FullWake (USB разбудил при закрытой крышке, потом открыли) приходит без
        // didWake — только экраны просыпаются. Без второго наблюдателя демон так и стоял на паузе.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.wake() }
        }
        link.show(lights)
        transcripts.sync(allocator.transcripts)
    }

    private func wake() {
        guard let since = asleepSince else { return }  // экраны просыпаются и без сна мака
        Log.info("просыпание: проверяю живость агентов")
        allocator.postpone(by: Date().timeIntervalSince(since))
        asleepSince = nil
        apply(allocator.sweep(config: config, now: Date(), isAlive: TerminalCapture.isAlive,
                              isBackground: TerminalCapture.isBackground))
        link.resume()
    }

    func shutdown() {
        server.stop()
        link.stop()
        try? store.save(allocator)
    }

    // MARK: - Хуки

    private func hook(_ body: Data) {
        record(body)
        let event: HookEvent
        do {
            event = try HookEvent.decode(body)
        } catch {
            Log.warn("хук не разобран: \(error)")
            return
        }
        let before = allocator.slotIndex(of: event.sessionId)
        apply(allocator.handle(event, config: config, now: Date(), isBackground: TerminalCapture.isBackground))
        if event.name == "SessionStart" || event.name == "SessionEnd" || before != allocator.slotIndex(of: event.sessionId) {
            let slot = allocator.slotIndex(of: event.sessionId).map { "слот \($0)" }
                ?? (allocator.isBackground(event.sessionId) ? "фоновая, без окна — скрыта" : "без слота")
            Log.info("\(event.name) \(event.sessionId.prefix(8)) \(event.cwd ?? "") → \(slot)")
        }
    }

    private func record(_ body: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: body) else { return }
        let at = Self.isoMillis.string(from: Date())
        if let recorder, let data = Self.jsonLine(["at": at, "body_json": json]) {
            recorder.write(data)
        }
        // постоянный журнал для разбора «почему горит не то»: без промптов и содержимого инструментов
        guard var slim = json as? [String: Any] else { return }
        for key in ["tool_input", "tool_response", "prompt", "last_assistant_message", "message"] {
            slim.removeValue(forKey: key)
        }
        if let data = Self.jsonLine(["at": at, "body_json": slim]) { hookLog.append(data) }
    }

    private static func jsonLine(_ obj: [String: Any]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
        data.append(0x0A)
        return data
    }

    private static let isoMillis: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func apply(_ fx: SlotAllocator.Effects) {
        guard fx.changed || !fx.welcome.isEmpty else { return }
        for slot in fx.welcome {
            welcomeUntil[slot] = Date().addingTimeInterval(1.2)
            link.welcome(slot: slot)
        }
        link.show(lights)
        transcripts.sync(allocator.transcripts)
        scheduleSave()
        onChange?()
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            do { try self.store.save(self.allocator) } catch { Log.error("state.json: \(error)") }
        }
    }

    // MARK: - Кнопки (физические и в popover)

    func button(slot: Int, _ g: ButtonGesture, done: @escaping (String) -> Void = { _ in }) {
        guard allocator.slots.indices.contains(slot) else { return done("нет такого слота") }
        let session = allocator.slots[slot].session
        switch (g, session) {
        case (.press, var s?):
            if s.terminal?.tty == nil, s.claudePid == nil, let cwd = s.cwd,
               let found = TerminalCapture.locateClaude(cwd: cwd) {
                allocator.adopt(slot: slot, pid: found.pid, tty: found.tty, cwd: found.cwd)
                onChange?()
                scheduleSave()
                s = allocator.slots[slot].session!
                Log.info("слот \(slot): нашёл claude pid \(found.pid) tty \(found.tty ?? "?") по cwd")
            }
            focuser.focus(s, order: config.terminalFocusOrder, done: done)
        case (.press, nil):
            let dir = config.emptySlotButtonLaunches.map { ($0 as NSString).expandingTildeInPath }
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            focuser.launch(cwd: dir, slot: slot)
            done("запускаю claude в \(dir)")
        case (.long, _?):
            apply(allocator.toggleMute(slot: slot))
            let state = allocator.slots[slot].muted ? "заглушен" : "включён"
            Log.info("кнопка \(slot): \(state)")
            done(state)
        case (.long, nil):
            link.broadcast(.selftest)
            done("selftest")
        case (.double, _):
            done("двойное нажатие пока ничего не делает")  // открыть transcript — фаза M7
        }
    }

    func release(slot: Int) {
        apply(allocator.release(slot: slot, now: Date()))
    }

    func reloadConfig() -> ControlReply {
        do {
            config = try Config.load()
            if config.slotCount != allocator.slots.count {
                Log.info("светофоров: \(allocator.slots.count) → \(config.slotCount)")
                apply(allocator.resize(to: config.slotCount, now: Date()))
            }
            link.brightness = config.brightness
            link.flags = (config.busyPulse, config.idlePulse)
            link.resync()
            return ControlReply(ok: true, message: "config.json перечитан")
        } catch {
            return ControlReply(ok: false, message: "config.json: \(error)")
        }
    }

    /// Правка настроек из UI: перечитываем файл (вдруг его правили руками), меняем, пишем, применяем.
    @discardableResult
    func updateConfig(_ mutate: (inout Config) -> Void) -> ControlReply {
        do {
            var c = try Config.load()
            mutate(&c)
            try c.save()
        } catch {
            Log.error("config.json: \(error)")
            return ControlReply(ok: false, message: "config.json: \(error)")
        }
        return reloadConfig()
    }

    /// Все состояния по кругу на всех слотах. Огни ровные, как в панели: пульс на время теста выключен.
    func runTest() {
        let n = allocator.slots.count
        let steps: [[LightState]] = [.attn, .busy, .idle].map { Array(repeating: $0, count: n) }
            + [[.attn, .busy, .idle, .off], [.off, .attn, .busy, .idle]].map { p in (0..<n).map { p[$0 % p.count] } }
        link.broadcast(.config(busyPulse: false, idlePulse: false))
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7 * Double(i)) { [weak self] in
                self?.override = step
                self?.link.show(step)
                self?.onChange?()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7 * Double(steps.count)) { [weak self] in
            guard let self else { return }
            self.override = nil
            let f = self.link.flags
            self.link.broadcast(.config(busyPulse: f.busyPulse, idlePulse: f.idlePulse))
            self.link.show(self.lights)
            self.onChange?()
        }
    }

    // MARK: - HTTP API для CLI

    private func route(_ req: HTTPRequest, _ reply: @escaping (HTTPResponse) -> Void) {
        switch (req.method, req.path) {
        case ("GET", "/status"):
            reply(.json(status()))
        case ("POST", "/control"):
            guard let c = try? JSONDecoder().decode(ControlRequest.self, from: req.body) else {
                return reply(HTTPResponse(status: 400))
            }
            control(c) { reply(.json($0)) }
        default:
            reply(.notFound)
        }
    }

    func status() -> StatusReport {
        StatusReport(
            version: AgentLightVersion.string,
            pid: getpid(),
            device: link.statusText,
            deviceConnected: link.isConnected,
            slots: allocator.slots.enumerated().map { i, s in
                .init(slot: i, light: s.light, muted: s.muted, rebinding: s.rebinding != nil, session: s.session)
            },
            overflow: allocator.overflow,
            automation: TerminalFocus.automationStatus(),
            background: allocator.background
        )
    }

    private func control(_ c: ControlRequest, reply: @escaping (ControlReply) -> Void) {
        let slotOK = c.slot.map { allocator.slots.indices.contains($0) } ?? false
        switch c.cmd {
        case .reload:
            reply(reloadConfig())
        case .test:
            runTest()
            reply(ControlReply(ok: true, message: "тест запущен (~5 с)"))
        case .selftest:
            link.broadcast(.selftest)
            reply(ControlReply(ok: link.isConnected, message: link.statusText))
        case .press, .long, .release:
            guard slotOK, let slot = c.slot else { return reply(ControlReply(ok: false, message: "нужен слот 0..\(allocator.slots.count - 1)")) }
            switch c.cmd {
            case .press: button(slot: slot, .press) { reply(ControlReply(ok: true, message: $0)) }
            case .long: button(slot: slot, .long) { reply(ControlReply(ok: true, message: $0)) }
            default:
                release(slot: slot)
                reply(ControlReply(ok: true, message: "слот \(slot) освобождён"))
            }
        }
    }
}

/// Дописываемый файл; при переполнении старый уезжает в `.1`.
final class RotatingLog {
    private let url: URL
    private let maxBytes: UInt64
    private var handle: FileHandle?

    init(url: URL, maxBytes: UInt64) {
        self.url = url
        self.maxBytes = maxBytes
    }

    func append(_ data: Data) {
        if handle == nil {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
        }
        guard let handle else { return }
        handle.write(data)
        if (try? handle.offset()) ?? 0 > maxBytes {
            try? handle.close()
            self.handle = nil
            let old = url.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
    }
}
