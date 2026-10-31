import Foundation

/// ASCII-протокол по CDC (`/dev/cu.usbmodem*`), docs/03-protocol.md §3.4.
/// Основной канал — HID; этот нужен, пока в прошивке нет HID, и для отладки.
/// Порт признаётся нашим, только если на HELLO пришло `OK agentlight …`.
public final class CDCTransport: DeviceTransport {
    public let name = "CDC"
    public var onAttach: ((DeviceChannel) -> Void)?
    public var onDetach: ((DeviceChannel) -> Void)?

    private let fixedPath: String?
    /// открытые порты: и уже наши, и те, что ещё отвечают на HELLO
    private var channels: [String: CDCChannel] = [:]
    private var scanTimer: Timer?
    /// чужие порты, которые не ответили на HELLO, — не дёргать их каждые 2 с
    private var rejected: [String: Date] = [:]

    public init(path: String? = nil) {
        fixedPath = path
    }

    public func start() {
        scan()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.scan() }
    }

    public func stop() {
        scanTimer?.invalidate()
        channels.values.forEach { $0.close() }
        channels = [:]
    }

    private func scan() {
        let candidates: [String]
        if let fixedPath {
            candidates = [fixedPath]
        } else {
            let all = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
            candidates = all.filter { $0.hasPrefix("cu.usbmodem") }.sorted().map { "/dev/" + $0 }
        }
        let now = Date()
        rejected = rejected.filter { now.timeIntervalSince($0.value) < 30 }
        for p in candidates where channels[p] == nil && rejected[p] == nil {
            open(p)
        }
    }

    private func open(_ p: String) {
        guard let ch = CDCChannel(path: p) else {
            rejected[p] = Date()
            return
        }
        channels[p] = ch
        ch.onReady = { [weak self, weak ch] in
            guard let self, let ch else { return }
            Log.info("CDC: \(p)")
            self.onAttach?(ch)
        }
        ch.onClose = { [weak self, weak ch] wasReady in
            guard let self, let ch else { return }
            self.channels.removeValue(forKey: p)
            if wasReady {
                self.onDetach?(ch)
            } else {
                Log.info("CDC: \(p) не ответил как agentlight, пропускаю")
                self.rejected[p] = Date()
            }
        }
        ch.probe()
    }
}

/// Один открытый CDC-порт.
final class CDCChannel: DeviceChannel {
    let name = "CDC"
    var onEvent: ((DeviceEvent) -> Void)?
    /// порт ответил как agentlight
    var onReady: (() -> Void)?
    /// порт закрыт; true — до этого был нашим
    var onClose: ((Bool) -> Void)?

    let path: String
    private var fd: Int32
    private var reader: DispatchSourceRead?
    private var buffer = Data()
    private var probeDeadline: Timer?
    private var ready = false
    private var seenErrors: Set<String> = []

    init?(path: String) {
        let f = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else { return nil }
        var t = termios()
        tcgetattr(f, &t)
        cfmakeraw(&t)
        // 1200 бод на RP2040 — сигнал «перезагрузись в BOOTSEL», держимся подальше
        cfsetspeed(&t, speed_t(B115200))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        tcsetattr(f, TCSANOW, &t)
        self.path = path
        fd = f
        let src = DispatchSource.makeReadSource(fileDescriptor: f, queue: .main)
        src.setEventHandler { [weak self] in self?.readAvailable() }
        src.setCancelHandler { Darwin.close(f) }
        src.resume()
        reader = src
    }

    func probe() {
        write(DeviceCommand.hello.asciiLine)
        probeDeadline = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            guard let self, !self.ready else { return }
            self.close(notify: true)
        }
    }

    func send(_ command: DeviceCommand) {
        guard ready else { return }
        write(command.asciiLine)
    }

    /// закрыть без колбэка (остановка транспорта)
    func close() { close(notify: false) }

    private func write(_ line: String) {
        guard fd >= 0 else { return }
        let bytes = Array((line + "\n").utf8)
        if Darwin.write(fd, bytes, bytes.count) < 0, errno != EAGAIN {
            close(notify: true)
        }
    }

    private func readAvailable() {
        guard fd >= 0 else { return }
        var chunk = [UInt8](repeating: 0, count: 512)
        let n = Darwin.read(fd, &chunk, chunk.count)
        if n <= 0 {
            if n == 0 || (errno != EAGAIN && errno != EINTR) { close(notify: true) }
            return
        }
        buffer.append(contentsOf: chunk[0..<n])
        while fd >= 0, let nl = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            if !line.isEmpty { handle(line) }
        }
    }

    private func handle(_ line: String) {
        guard let e = DeviceEvent(asciiLine: line) else {
            // ранняя прошивка отвечает ERR на ещё не реализованные команды — раз в каждую
            if line.hasPrefix("ERR"), seenErrors.insert(line).inserted { Log.warn("CDC: \(line)") }
            return
        }
        if case .ready = e, !ready {
            probeDeadline?.invalidate()
            ready = true
            onReady?()
        }
        onEvent?(e)
    }

    private func close(notify: Bool) {
        guard fd >= 0 else { return }
        probeDeadline?.invalidate()
        reader?.cancel()
        reader = nil
        fd = -1
        let was = ready
        ready = false
        if notify { onClose?(was) }
    }
}
