import Foundation

/// Stub device: draws 4 traffic lights in ANSI colors in the terminal (the first device,
/// slots 0..3), keys 1–4 — short button press, Shift+1–4 (!@#$) — long press.
/// docs/05-host-macos.md §5.11.
public final class FakeTransport: DeviceTransport, DeviceChannel {
    public let name = "fake"
    public var onEvent: ((DeviceEvent) -> Void)?
    public var onAttach: ((DeviceChannel) -> Void)?
    public var onDetach: ((DeviceChannel) -> Void)?
    /// captions under the columns — project names
    public var labels: () -> [String] = { [] }

    private var lights: [LightState] = Array(repeating: .off, count: DeviceLink.slotsPerDevice)
    private var welcomeUntil: [Date] = Array(repeating: .distantPast, count: DeviceLink.slotsPerDevice)
    private var brightness: UInt8 = 255
    private var savedTermios = termios()
    private var stdinSource: DispatchSourceRead?
    private var drawn = false
    private var lastPing = Date()
    private var redrawTimer: Timer?

    public init() {}

    public func start() {
        if isatty(STDIN_FILENO) != 0 {
            tcgetattr(STDIN_FILENO, &savedTermios)
            var raw = savedTermios
            raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
            let src = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
            src.setEventHandler { [weak self] in self?.readKeys() }
            src.resume()
            stdinSource = src
        }
        print("\u{1B}[?25l", terminator: "")  // hide the cursor
        onAttach?(self)
        onEvent?(.ready(DeviceIdentity(proto: 1, slots: 4, firmware: "fake", uid: "FAKE"), powerOn: true))
        redrawTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.draw() }
    }

    public func stop() {
        redrawTimer?.invalidate()
        stdinSource?.cancel()
        if isatty(STDIN_FILENO) != 0 { tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios) }
        print("\u{1B}[?25h", terminator: "")
        fflush(stdout)
    }

    public func send(_ command: DeviceCommand) {
        switch command {
        case .setAll(let s) where s.count == lights.count: lights = s
        case .setState(let slot, let s) where lights.indices.contains(slot): lights[slot] = s
        case .welcome(let slot):
            let until = Date().addingTimeInterval(1.2)
            if let slot, welcomeUntil.indices.contains(slot) { welcomeUntil[slot] = until }
            if slot == nil { welcomeUntil = welcomeUntil.map { _ in until } }
        case .brightness(let b): brightness = b
        case .ping(let seq):
            lastPing = Date()
            onEvent?(.pong(seq: seq, uptimeMs: 0, watchdogTripped: false))
        case .hello:
            onEvent?(.ready(DeviceIdentity(proto: 1, slots: 4, firmware: "fake", uid: "FAKE"), powerOn: true))
        default: break
        }
        draw()
    }

    private func readKeys() {
        var buf = [UInt8](repeating: 0, count: 16)
        let n = read(STDIN_FILENO, &buf, buf.count)
        guard n > 0 else { return }
        for b in buf[0..<n] {
            switch Character(UnicodeScalar(b)) {
            case "1", "2", "3", "4": onEvent?(.button(slot: Int(b) - 0x31, .press))
            case "!": onEvent?(.button(slot: 0, .long))
            case "@": onEvent?(.button(slot: 1, .long))
            case "#": onEvent?(.button(slot: 2, .long))
            case "$": onEvent?(.button(slot: 3, .long))
            default: break
            }
        }
    }

    private func draw() {
        let now = Date()
        // like the real hardware: no PING for > 3 s — everything goes dark
        let watchdog = now.timeIntervalSince(lastPing) > 3
        let colors = ["31", "33", "32"]  // R Y G
        let lit: [LightState] = [.attn, .busy, .idle]
        var out = drawn ? "\u{1B}[8A" : ""
        out += "  " + String(repeating: "┌────┐ ", count: 4) + "\u{1B}[K\n"
        for row in 0..<3 {
            out += "  "
            for slot in 0..<4 {
                var on = !watchdog && lights[slot] == lit[row]
                if welcomeUntil[slot] > now {
                    // a wave top to bottom, ~0.4 s per light
                    on = Int((1.2 - welcomeUntil[slot].timeIntervalSince(now)) / 0.4) == row
                }
                out += on ? "│ \u{1B}[\(colors[row])m●\u{1B}[0m  │ " : "│ ○  │ "
            }
            out += "  " + ["R", "Y", "G"][row] + "\u{1B}[K\n"
        }
        out += "  " + String(repeating: "└────┘ ", count: 4) + "\u{1B}[K\n"
        out += "  " + lights.map { pad(watchdog ? "wd" : $0.name, 7) }.joined() + "\u{1B}[K\n"
        let l = labels()
        out += "  " + (0..<4).map { pad(l.indices.contains($0) ? l[$0] : "—", 7) }.joined() + "\u{1B}[K\n"
        out += "  [1]    [2]    [3]    [4]    ← digit = button, Shift = long press\u{1B}[K\n"
        print(out, terminator: "")
        fflush(stdout)
        drawn = true
    }

    private func pad(_ s: String, _ n: Int) -> String {
        let t = String(s.prefix(n - 1))
        return t + String(repeating: " ", count: n - t.count)
    }
}
