import AgentLightKit
import AppKit

/// Runs a TerminalFocus.Step chain in the background: osascript is a separate process, so
/// the TCC dialog "AgentLight wants to control Terminal" doesn't freeze the daemon and the menu bar.
final class FocusRunner {
    private let queue = DispatchQueue(label: "agentlight.focus")
    /// under launchd PATH is minimal — find tmux ourselves
    private static let tmuxCandidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]

    func focus(_ s: SessionRecord, order: [String], done: @escaping (String) -> Void) {
        let steps = TerminalFocus.plan(for: s, order: order, isAlive: TerminalCapture.isAlive)
        let name = s.projectName
        queue.async {
            let result = Self.run(steps)
            Log.info("focus \(name): \(result)")
            DispatchQueue.main.async { done(result) }
        }
    }

    func launch(cwd: String, slot: Int) {
        let cmd = TerminalFocus.launchCommand(cwd: cwd, slot: slot)
        queue.async {
            let r = Self.osascript(TerminalFocus.terminalRunScript, [cmd])
            Log.info("new agent in slot \(slot) (\(cwd)): \(r.ok ? "ok" : r.output)")
        }
    }

    /// A background session no tab is showing: `claude attach` in a new window.
    /// A second screen on the same session is safe — attach only shows it, doesn't take it over.
    func attach(job: String, cwd: String?, name: String, done: @escaping (String) -> Void) {
        let cmd = TerminalFocus.attachCommand(cwd: cwd, job: job)
        queue.async {
            let r = Self.osascript(TerminalFocus.terminalRunScript, [cmd])
            let result = r.ok ? "background session without a window — opened claude attach \(job)" : "attach: \(r.output)"
            Log.info("focus \(name): \(result)")
            DispatchQueue.main.async { done(result) }
        }
    }

    private static func run(_ steps: [TerminalFocus.Step]) -> String {
        guard !steps.isEmpty else { return "nothing to focus: no tty and unknown terminal" }
        var clientTTY: String?
        var log: [String] = []
        for step in steps {
            switch step {
            case .tmux(let pane, let socket):
                guard let tty = tmux(pane: pane, socket: socket) else {
                    log.append("tmux: failed")
                    continue
                }
                clientTTY = tty
                log.append("tmux: \(pane) → client \(tty)")
            case .terminalTab(let tty):
                guard let tty = clientTTY ?? tty else { continue }
                let r = osascript(TerminalFocus.terminalTabScript, [tty])
                if r.ok && r.output == "ok" { return (log + ["Terminal: tab \(tty)"]).joined(separator: "; ") }
                log.append("Terminal: \(r.output.isEmpty ? "error" : r.output) (\(tty))")
            case .activateApp(let bundleId):
                if activate(bundleId) { return (log + ["brought \(bundleId) to front"]).joined(separator: "; ") }
                log.append("\(bundleId) not running")
            case .resume(let cwd, let sid):
                let r = osascript(TerminalFocus.terminalRunScript, [TerminalFocus.resumeCommand(cwd: cwd, sessionId: sid)])
                if r.ok { return (log + ["agent is dead — opened claude --resume"]).joined(separator: "; ") }
                log.append("resume: \(r.output)")
            }
        }
        return log.joined(separator: "; ")
    }

    /// Switch the tmux window and pane; return the tty of the client looking at it.
    private static func tmux(pane: String, socket: String?) -> String? {
        guard let bin = tmuxCandidates.first(where: FileManager.default.isExecutableFile) else { return nil }
        let sock = socket.map { ["-S", $0] } ?? []
        guard exec(bin, sock + ["select-window", "-t", pane]).ok,
              exec(bin, sock + ["select-pane", "-t", pane]).ok else { return nil }
        let session = exec(bin, sock + ["display-message", "-p", "-t", pane, "#{session_name}"]).output
        let clients = exec(bin, sock + ["list-clients", "-F", "#{client_tty} #{session_name}"]).output
        return clients.split(separator: "\n")
            .map { $0.split(separator: " ", maxSplits: 1).map(String.init) }
            .first { $0.count == 2 && $0[1] == session }?[0]
    }

    private static func activate(_ bundleId: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId),
              !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty else { return false }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var ok = false
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, _ in
            ok = app != nil
            sem.signal()
        }
        sem.wait()
        return ok
    }

    private static func osascript(_ script: String, _ args: [String]) -> (ok: Bool, output: String) {
        let r = exec("/usr/bin/osascript", ["-"] + args, stdin: script)
        if !r.ok, r.output.contains("-1743") {
            Log.warn("no Automation → Terminal permission: System Settings → Privacy & Security → Automation → AgentLight")
        }
        return r
    }

    private static func exec(_ tool: String, _ args: [String], stdin: String? = nil) -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let input = Pipe()
        if stdin != nil { p.standardInput = input }
        do { try p.run() } catch { return (false, "\(error)") }
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try? input.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (p.terminationStatus == 0, text)
    }
}
