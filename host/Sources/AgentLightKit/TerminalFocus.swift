import Foundation

/// Фокус терминала агента по кнопке, docs/05-host-macos.md §5.6.
/// Здесь только решения и тексты скриптов; запуск процессов — в демоне (FocusRunner).
public enum TerminalFocus {
    /// Один шаг цепочки. Первый удачный выигрывает.
    public enum Step: Equatable, Sendable {
        /// переключить окно/панель tmux; на выходе — tty клиента, по которому искать вкладку
        case tmux(pane: String, socket: String?)
        /// Terminal.app: вкладка по tty
        case terminalTab(tty: String?)
        /// терминал без скриптинга: просто вывести приложение вперёд
        case activateApp(bundleId: String)
        /// агент мёртв, а вкладки нет — открыть `claude --resume` в новом окне
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
                // живого агента не плодим вторым `--resume` — только если процесс точно умер
                let dead = s.claudePid.map { !isAlive($0) } ?? false
                if dead, let cwd = s.cwd { steps.append(.resume(cwd: cwd, sessionId: s.sessionId)) }
            default:
                continue
            }
        }
        return steps
    }

    /// Новый агент из пустого слота: `SessionStart` прочитает AGENTLIGHT_PREFER_SLOT и займёт этот слот.
    public static func launchCommand(cwd: String, slot: Int) -> String {
        "cd \(shellQuote(cwd)) && AGENTLIGHT_PREFER_SLOT=\(slot) claude"
    }

    public static func resumeCommand(cwd: String, sessionId: String) -> String {
        "cd \(shellQuote(cwd)) && claude --resume \(shellQuote(sessionId))"
    }

    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Нативные вкладки macOS Terminal отдаёт в AppleScript отдельными «окнами» с одной вкладкой
    /// (проверено 2026-10-16: 2 физических окна → 5 windows). Поэтому перебираем все окна и все
    /// вкладки, а поднимаем через `index` — это переключает и вкладку внутри группы.
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

    /// argv: команда для нового окна
    public static let terminalRunScript = """
    on run argv
      tell application "Terminal"
        do script (item 1 of argv)
        activate
      end tell
      return "ok"
    end run
    """
}
