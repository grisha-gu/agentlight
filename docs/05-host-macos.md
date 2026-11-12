# 05. Host: the macOS daemon

## 5.1. Why Swift and why an .app bundle

Three things are easiest to do natively on macOS:

| Task | API |
|---|---|
| driverless USB HID | `IOHIDManager` (IOKit) |
| focusing a terminal window | `NSAppleScript` |
| autostart, sleep/wake | `launchd` + `NSWorkspace` notifications |

**The daemon lives inside an .app bundle**, even though it has no regular windows
(`LSUIElement = true`). macOS privacy permissions (Automation) are tied to the bundle
identifier and signature. A bare binary is identified by its path and cdhash, so every
rebuild would reset the granted permissions.

```
AgentLight.app/
└── Contents/
    ├── Info.plist             # LSUIElement=1, CFBundleIdentifier=dev.grisha-gu.agentlight
    └── MacOS/
        ├── agentlightd        # daemon + menu bar UI
        └── agentlight         # CLI (symlinked into /usr/local/bin)
```

## 5.2. Package

```
host/
├── Package.swift
├── Sources/
│   ├── AgentLightKit/              # all logic, no UI, unit-tested
│   │   ├── SlotAllocator.swift      # claim / release / rebind / overflow
│   │   ├── SlotStateMachine.swift   # event → state
│   │   ├── HookEvent.swift          # tolerant JSON decoding of all hooks
│   │   ├── SessionRecord.swift      # session_id, cwd, pid, terminal reference
│   │   ├── StateStore.swift         # ~/.agentlight/state.json, atomic writes
│   │   ├── Config.swift
│   │   ├── DeviceProtocol.swift     # HID/ASCII encoding, DeviceLink
│   │   ├── DeviceTransport.swift    # transport protocol
│   │   ├── HIDTransport.swift       # IOHIDManager
│   │   ├── CDCTransport.swift       # termios, for debugging
│   │   ├── FakeTransport.swift      # ANSI rendering in a terminal, no hardware
│   │   ├── HTTPServer.swift         # minimal HTTP/1.1 on 127.0.0.1
│   │   ├── HookInstaller.swift      # merges hooks into ~/.claude/settings.json
│   │   ├── TerminalCapture.swift    # terminal identity on SessionStart
│   │   ├── TerminalFocus.swift      # focus strategies
│   │   └── TranscriptTail.swift     # detects Esc interrupts in the transcript
│   ├── agentlightd/                 # daemon wiring + MenuBar/ (status item, popover, settings)
│   └── agentlight/                  # CLI
├── Resources/
│   ├── Info.plist, AgentLight.entitlements, AgentLight.icns
│   └── <lang>.lproj/                # UI translations (Localizable.strings, InfoPlist.strings)
└── Tests/AgentLightKitTests/
```

The tests cover the state machine and the allocator without hardware or Claude Code,
using recorded hook traffic (`tools/hook-capture/samples.jsonl`).

## 5.3. Receiving hooks over HTTP

Claude Code supports `http` hooks: it POSTs the same JSON a `command` hook receives
on stdin. For high-frequency events this is much better than `command` hooks:
`PreToolUse`/`PostToolUse` fire on every tool call, and forking a process for each
costs 10–20 ms in the agent's hot path.

```swift
// NWListener on 127.0.0.1, minimal HTTP/1.1
// Rule: reply 204 IMMEDIATELY, process afterwards.
func handle(_ body: Data) {
    queue.async { self.router.dispatch(body) }
    respond(status: 204)
}
```

Server requirements:

* listen on `127.0.0.1` **only** (never `0.0.0.0`);
* reply `204` in < 1 ms; all work is asynchronous;
* never return 5xx — a failing hook adds noise to the agent's debug log;
* the hooks use `async: true` and `timeout: 2`, so a dead daemon does not affect the
  agent at all.

### Observed behaviour

Verified against real traffic with a logging server ([`tools/hook-capture/`](../tools/hook-capture/README.md)):

| Question | Answer |
|---|---|
| Do `http` hooks work? | yes |
| Method, headers | `POST`, `Content-Type: application/json`, `User-Agent: axios/…` |
| Body | **byte-for-byte identical** to what a `command` hook gets on stdin |
| Routing | `hook_event_name` **in the body** → one URL, `/hook`, for all events |
| `Connection` | **`keep-alive`** → the server must support persistent HTTP/1.1 connections |
| Changes to `settings.json` | picked up **live**, no session restart needed |
| Does a dead endpoint break the agent? | no: with `async: true` tool calls go through without delay or errors |

### Undocumented fields

Real payloads contain fields not described in the hooks documentation, so the decoder
must accept unknown fields:

* `scratchpad_dir` — the session's temporary directory;
* `prompt_id` — UUID of the current turn, also present in `PreToolUse`/`PostToolUse`;
* `permission_mode` — `"auto"`, `"default"`, `"plan"`, …;
* `effort: {level: "high"}`;
* on `Stop`: `stop_hook_active`, `background_tasks` (running background tasks with
  their status) and `session_crons`.

Observed field sets per event:

```
PreToolUse        cwd effort hook_event_name permission_mode prompt_id
                  scratchpad_dir session_id tool_input tool_name
                  tool_use_id transcript_path
PostToolUse       + duration_ms tool_response
UserPromptSubmit  cwd hook_event_name permission_mode prompt prompt_id
                  scratchpad_dir session_id transcript_path
Stop              cwd effort hook_event_name last_assistant_message
                  permission_mode prompt_id scratchpad_dir session_crons
                  session_id stop_hook_active transcript_path background_tasks
Notification      cwd hook_event_name message notification_type prompt_id
                  scratchpad_dir session_id transcript_path
```

`Notification` and `UserPromptSubmit` have no `effort`, and `Notification` has no
`permission_mode` either. `PostToolUse` carries `tool_response` (an object) and
`duration_ms` rather than a `tool_output` string.

Hence, in `HookEvent` **every field except `hook_event_name` and `session_id` is
optional and unknown fields are ignored**, so a format change in a new Claude Code
version does not break the lights.

### Consequences

1. One endpoint, `POST /hook`, routed by `hook_event_name` from the body.
2. The server supports keep-alive (several requests per TCP connection) and replies
   `204` with `Content-Length: 0`.
3. `agentlight install-hooks` takes effect immediately, without restarting agents.
4. `command` and `http` hooks can be mixed freely on the same event.
5. `Notification(idle_prompt)` arrives exactly 60 s after `Stop` and only means
   inactivity — see [01-architecture.md](01-architecture.md#why-idle_prompt-does-not-mean-attn).

## 5.4. Installing the hooks

`agentlight install-hooks` merges into `~/.claude/settings.json`, **keeping existing
hooks** (merge per event, not overwrite), and writes a backup next to it.
`agentlight uninstall-hooks` removes exactly its own entries.

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ {
        "type": "command",
        "command": "'/Applications/AgentLight.app/Contents/MacOS/agentlight' hook",
        "async": true,
        "timeout": 5
      } ] }
    ],
    "UserPromptSubmit":   [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "PreToolUse":         [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "PostToolUse":        [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "PostToolUseFailure": [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "PermissionRequest":  [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "PermissionDenied":   [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "Notification":       [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "Elicitation":        [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "SubagentStart":      [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "SubagentStop":       [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "Stop":               [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "StopFailure":        [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "SessionEnd":         [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ]
  }
}
```

`SessionStart` is the only `command` hook, because it needs the terminal's
environment, which the HTTP payload does not include.

## 5.5. Capturing the terminal identity

A `command` hook runs as a child of Claude Code and inherits its environment and
controlling terminal. That is enough to find the terminal tab later:

```swift
// agentlight hook — on SessionStart
struct TerminalRef: Codable {
    var termProgram: String?    // TERM_PROGRAM ("Apple_Terminal", "iTerm.app", "ghostty", "WezTerm", "vscode")
    var appBundleId: String?    // __CFBundleIdentifier — the terminal application
    var itermSessionId: String? // ITERM_SESSION_ID
    var tmuxPane: String?       // TMUX_PANE ("%3")
    var tmuxSocket: String?     // from TMUX
    var weztermPane: String?    // WEZTERM_PANE
    var kittyWindowId: String?  // KITTY_WINDOW_ID
    var tty: String?            // ttyname(open("/dev/tty")) → "/dev/ttys004"
}
// plus the claude process PID: getppid(), then up the process tree
```

* `tty` is the controlling terminal; Terminal.app's AppleScript can look up a tab by
  it. It is the most reliable identifier.
* `claudePid` walks up from `getppid()` until it reaches the `claude` process. It is
  used for focusing and for liveness checks. The native Claude Code build lives in
  `~/.local/share/claude/versions/<version>`, so its process name (`p_comm`) is the
  version number, not `claude`; the walk matches on `argv[0]` or the path instead.
* `cwd` in hooks is the agent shell's *current* directory and changes after `cd`.
  The session's project is the `cwd` of its first event and is not overwritten.

The reference is stored in the `SessionRecord` together with `session_id` and `cwd`.

## 5.6. Focusing the window on a button press

A chain of strategies; the first one that succeeds wins. The order is set by
`terminal_focus_order` in the config (default `["tmux", "native", "new_window"]`).

### 1. `tmux` (if `TMUX_PANE` is set)

Switch the tmux window and pane, then focus the client's Terminal.app tab with
strategy 2:

```bash
tmux select-window -t "$TMUX_PANE"
tmux select-pane  -t "$TMUX_PANE"
```

### 2. `native` — Terminal.app

Terminal.app is fully scriptable and can find a tab by tty, so the button focuses the
exact tab, not just the window:

```applescript
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
```

`set index of w to 1` raises the window within the app, `activate` brings the app to
the front — both are needed.

With native macOS tabs, AppleScript reports **each tab as a separate `window` with a
single `tab`** (two physical windows can show up as five `windows` with identical
`bounds`). That is why the script walks all windows and all tabs: `set index of w to
1` then switches to the right tab within the group. Classic tabs (several `tabs` in
one window) are covered by `set selected tab`.

For other terminals, `native` just brings the terminal application to the front.

### 3. `new_window` — resume in a new window (fallback)

Only if the agent process is gone and its tab could not be found:

```applescript
tell application "Terminal"
  do script "cd '<cwd>' && claude --resume '<session_id>'"
  activate
end tell
```

### Background sessions

A session hosted by Claude Code's daemon has no window of its own. Before the chain
runs, the daemon looks for a tab that shows it (see `docs/01-architecture.md` §1.4):
a `claude attach` on its job, or the parked tab it was sent from, and focuses that
tab with the chain above. If there is none, it opens `claude attach <job>` in a new
Terminal window instead.

### Other terminals

`TerminalFocus` is meant to be extended. Possible implementations:

| Terminal | How |
|---|---|
| iTerm2 | the same AppleScript approach, iterating `sessions of t` and matching `tty of s`, then `select` |
| WezTerm | `wezterm cli activate-pane --pane-id $WEZTERM_PANE` |
| Kitty | `kitty @ focus-window --match id:$KITTY_WINDOW_ID` (needs `allow_remote_control yes`) |
| Ghostty, VS Code / Cursor terminals | no scripting: Accessibility API — find the app window whose `AXTitle` contains the basename of `cwd`, then `AXRaise` + `activate` (cannot select a tab inside the window) |

### Empty slot

The button under a dark light starts a **new** agent in the directory from
`empty_slot_button_launches`, and the agent lands in that same slot: the command is
`cd <dir> && AGENTLIGHT_PREFER_SLOT=<n> claude`, and the `SessionStart` hook passes
the preferred slot on to the daemon.

## 5.7. macOS permissions

| Permission | Why | Where |
|---|---|---|
| **Automation** → Terminal | focusing a tab by tty via AppleScript — the only one needed | a prompt appears on the first button press; later: System Settings → Privacy & Security → Automation |
| Accessibility | not needed (only for a future AX fallback) | — |
| Input Monitoring | **not needed** for a vendor-defined HID device | — |

Notes:

* Prompts triggered from a launchd agent may appear behind other windows.
* Permissions are bound to the signature and the bundle id. An ad-hoc signed build
  changes its cdhash on every rebuild and loses them; sign with a stable identity
  (see [host/README.md](../host/README.md#signing-and-automation)).
* `agentlight doctor` checks the daemon, the hooks, the device and the Automation
  permission, and prints what to fix.

## 5.8. USB transport

```swift
final class HIDTransport: DeviceTransport {
    // IOHIDManager matching: VID 0x1209 or 0x2E8A + usage page 0xFF00
    // device matching callback → device attached
    // device removal callback  → device gone
    // input report callback    → BUTTON / PONG / READY / POWER
    // IOHIDDeviceSetReport(kIOHIDReportTypeOutput, …) → commands
}
```

* `PING` every 1000 ms on its own timer, otherwise the device turns the lights off.
* On `READY` (the device rebooted) — an immediate full resync: `BRIGHTNESS`,
  `CONFIG`, `SET_ALL`.
* On removal — drop the reference and wait for the matching callback; no polling.
* **Several devices**: each one gets a "bank" of 4 slots in connection order — the
  first shows slots 0..3, the second 4..7, and so on (`DeviceLink`). A device is
  recognised by the `uid` in `READY`: when it reconnects it gets its previous bank
  back if that is free, otherwise the lowest free one. A bank beyond `slot_count`
  stays dark.
* A device visible over both HID and CDC is one device: the host talks over the
  transport that comes first (HID); the other stays silent until the first one
  disappears.

### Sleep and wake

```swift
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification …)
// → SET_ALL off, stop PING
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification …)
// → re-enumerate the device, check every PID, full resync
```

Some agents may have died during sleep, so every slot gets a `kill(pid, 0)` check
before anything lights up.

## 5.9. CLI

```
agentlight install-hooks [--settings PATH]   # merge hooks into ~/.claude/settings.json (others untouched)
agentlight uninstall-hooks [--settings PATH] # remove exactly our hooks
agentlight install-daemon                    # LaunchAgent for AgentLight.app, start it
agentlight uninstall-daemon                  # stop and remove the LaunchAgent
agentlight status                            # slots, states, projects, pids, terminals
agentlight doctor                            # check the daemon, hooks, device, permissions
agentlight test                              # cycle through all states on the device and in the menu bar
agentlight selftest                          # device self-test animation
agentlight focus <slot>                      # same as a button press
agentlight mute <slot>                       # mute a slot
agentlight release <slot>                    # free a slot
agentlight pin <slot> [path]                 # pin a project (default: current directory) to a slot
agentlight unpin [path]
agentlight brightness <0-255>
agentlight replay <file.jsonl> [--live] [--speed N]   # run recorded hooks through the state machine (or the live daemon)
agentlight logs [-f]
agentlight hook                              # internal: the SessionStart hook, stdin → daemon
```

Slots are numbered from 0 (buttons on the device from 1).

## 5.10. LaunchAgent

`agentlight install-daemon` writes
`~/Library/LaunchAgents/dev.grisha-gu.agentlight.daemon.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key>                 <string>dev.grisha-gu.agentlight.daemon</string>
  <key>ProgramArguments</key>
    <array><string>/Applications/AgentLight.app/Contents/MacOS/agentlightd</string></array>
  <key>RunAtLoad</key>             <true/>
  <key>KeepAlive</key>             <dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key>           <string>Interactive</string>
  <key>StandardOutPath</key>       <string>~/.agentlight/agentlightd.log</string>
  <key>StandardErrorPath</key>     <string>~/.agentlight/agentlightd.log</string>
</dict></plist>
```

Restart after a rebuild:

```bash
launchctl kickstart -k gui/$(id -u)/dev.grisha-gu.agentlight.daemon
```

## 5.11. Development without hardware

`FakeTransport` draws the four lights with ANSI colours in the terminal and reads the
keys `1`–`4` as buttons:

```
$ agentlightd --fake-device
  ┌────┐ ┌────┐ ┌────┐ ┌────┐
  │ ●  │ │ ○  │ │ ○  │ │ ○  │   R
  │ ○  │ │ ●  │ │ ○  │ │ ○  │   Y
  │ ○  │ │ ○  │ │ ●  │ │ ○  │   G
  └────┘ └────┘ └────┘ └────┘
   attn   busy   idle    off
  [1]      [2]      [3]      [4]   ← press a digit = button
```

The menu bar icon and its popover show the same lights, so AgentLight is usable even
without the device. The icon follows the menu bar's look: when the bar switches to black
icons (a light wallpaper behind it), each group of four lights (or the leftover tail) sits
on a dark rounded plate, so yellow and green don't fade into the background.

Recording and replaying events:

```bash
agentlightd --record ~/replay.jsonl              # write every incoming hook
agentlight replay ~/replay.jsonl --speed 4        # run them through the state machine
```

### Languages

The menu bar UI (popover, settings window, the device line) follows the system
language; a per-app override lives in System Settings → General → Language & Region →
Applications. English is the source language: the strings in `agentlightd/MenuBar` are
the localization keys, and every other language is a `host/Resources/<lang>.lproj/Localizable.strings`
that `build-app.sh` copies into the bundle (also add the language to
`CFBundleLocalizations` in `Info.plist`). Logs, the CLI and `GET /status` stay in English.

To look at the UI in another language without changing the system one:

```bash
agentlightd --snapshot /tmp/ui -AppleLanguages "(ru)"   # from inside AgentLight.app
```

## 5.12. Test checklist

* [ ] one agent → welcome → green; submit a prompt → yellow; answer → green
* [ ] a command that needs permission → red; allow → yellow → green
* [ ] 4 agents at once, each in its own slot, states do not mix
* [ ] a 5th agent → overflow, no light; close the 2nd → the 5th moves into a slot with a welcome
* [ ] `/clear` → the light neither goes out nor changes slot
* [ ] `claude --resume` in the same window → same slot
* [ ] `kill -9` the agent → the slot goes dark within 5 s
* [ ] kill the daemon → all lights go dark within 3 s (device watchdog)
* [ ] restart the daemon → states restored from `state.json`
* [ ] unplug and replug USB → everything recovers without restarting the daemon
* [ ] sleep / wake → correct states, dead slots dark
* [ ] the button focuses the right Terminal.app tab: in the active window, in a background window, in a window minimised to the Dock
* [ ] the button on an empty slot starts an agent, and it lands in that slot
* [ ] latency `UserPromptSubmit` → yellow under 50 ms
