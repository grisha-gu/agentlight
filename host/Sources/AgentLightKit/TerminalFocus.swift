import CoreServices
import Foundation

/// Focusing the agent's terminal from a button, docs/05-host-macos.md §5.6.
/// Only decisions and script texts here; process launching lives in the daemon (FocusRunner).
public enum TerminalFocus {
    /// One step of the chain. The first successful one wins.
    public enum Step: Equatable, Sendable {
        /// switch tmux window/pane; outputs the client tty to look the tab up by
        case tmux(pane: String, socket: String?)
        /// Terminal.app: tab by tty
        case terminalTab(tty: String?)
        /// terminal without scripting: just bring the app to the front
        case activateApp(bundleId: String)
        /// the agent is dead and there's no tab — open `claude --resume` in a new window
        case resume(cwd: String, sessionId: String)
    }

    public static let terminalBundleId = "com.apple.Terminal"

    public static func plan(for s: SessionRecord, order: [String], isAlive: (Int32) -> Bool) -> [Step] {
        let t = s.terminal
        var steps: [Step] = []
        for name in order {
            switch name {
            case "tmux":
                if let pane = t?.tmuxPane { steps.append(.tmux(pane: pane, socket: t?.tmuxSocket)) }
            case "native":
                let app = t?.appBundleId ?? (t?.termProgram == "Apple_Terminal" ? terminalBundleId : nil)
                if app == terminalBundleId || (app == nil && t?.tty != nil) {
                    steps.append(.terminalTab(tty: t?.tty))
                } else if let app {
                    steps.append(.activateApp(bundleId: app))
                }
            case "new_window":
                // don't spawn a second `--resume` of a live agent — only if the process is definitely dead
                let dead = s.claudePid.map { !isAlive($0) } ?? false
                if dead, let cwd = s.cwd { steps.append(.resume(cwd: cwd, sessionId: s.sessionId)) }
            default:
                continue
            }
        }
        return steps
    }

    /// New agent from an empty slot: `SessionStart` reads AGENTLIGHT_PREFER_SLOT and takes this slot.
    public static func launchCommand(cwd: String, slot: Int) -> String {
        "cd \(shellQuote(cwd)) && AGENTLIGHT_PREFER_SLOT=\(slot) claude"
    }

    public static func resumeCommand(cwd: String, sessionId: String) -> String {
        "cd \(shellQuote(cwd)) && claude --resume \(shellQuote(sessionId))"
    }

    public static func attachCommand(cwd: String?, job: String) -> String {
        (cwd.map { "cd \(shellQuote($0)) && " } ?? "") + "claude attach \(shellQuote(job))"
    }

    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// macOS Terminal exposes native tabs to AppleScript as separate one-tab "windows"
    /// (checked 2026-10-16: 2 physical windows → 5 windows). So we go through all windows and all
    /// tabs, and raise via `index` — which also switches the tab within the group.
    public static let terminalTabScript = """
    on run argv
      set theTTY to item 1 of argv
      tell application "Terminal"
        repeat with w in windows
          repeat with t in tabs of w
            if tty of t is theTTY then
              if miniaturized of w then set miniaturized of w to false
              set selected tab of w to t
              set index of w to 1
              activate
              return "ok"
            end if
          end repeat
        end repeat
      end tell
      return "notfound"
    end run
    """

    /// argv: command for the new window
    public static let terminalRunScript = """
    on run argv
      tell application "Terminal"
        do script (item 1 of argv)
        activate
      end tell
      return "ok"
    end run
    """

    /// Automation → Terminal permission of the current process, without a TCC dialog.
    /// Only meaningful in the daemon: a CLI run from a terminal would check the terminal's own rights.
    public enum Automation: String, Codable, Sendable {
        case granted, denied
        /// no dialog yet — it will appear on the first press
        case notAsked
        /// Terminal isn't running — TCC doesn't answer about an app that isn't running
        case unknown
    }

    public static func automationStatus() -> Automation {
        var target = AEAddressDesc()
        let id = Array(terminalBundleId.utf8)
        guard AECreateDesc(DescType(typeApplicationBundleID), id, id.count, &target) == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }
        switch AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return .unknown
        }
    }
}
