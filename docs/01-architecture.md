# 01. Architecture

## 1.1. Why a daemon

A stateless design — every hook is a short-lived process that recolours a lamp and
exits — is not enough here:

* the device has **4 independent slots**, and something has to remember which
  `session_id` lives in which slot;
* the **buttons must be read**, so something has to stay connected to the device;
* a light must **go dark when an agent dies** without sending `SessionEnd`;
* the USB device needs **a single owner** that handles hot-plug, reconnects and the
  heartbeat.

So the host side is a resident daemon, `agentlightd`, running as a LaunchAgent, plus
stateless hooks that only forward events to it.

## 1.2. Slot states

```
        SessionStart
   OFF ─────────────► WELCOME ──► IDLE (green)
    ▲                               │  ▲
    │                UserPromptSubmit│  │ Stop
    │ SessionEnd                     ▼  │ Notification(agent_completed)
    │ / watchdog                   BUSY (yellow)
    │                               │  ▲
    │          PermissionRequest    │  │ PreToolUse / PostToolUse
    │          Notification(...)    ▼  │ PermissionDenied
    └──────────────────────────── ATTN (red)
```

Four visible states plus one transient one:

| Code | Light | Meaning |
|---|---|---|
| `OFF` | dark | the slot is free, no agent |
| `WELCOME` | ~1.2 s animation | the slot has just been taken |
| `IDLE` | green | the agent is alive and waiting for your input |
| `BUSY` | yellow | the agent is thinking or running tools |
| `ATTN` | red | the agent is blocked and waiting for a decision |

## 1.3. Mapping Claude Code hooks to states

Every hook receives `session_id`, `transcript_path`, `cwd` and `hook_event_name`.
The full list of events and their fields: <https://code.claude.com/docs/en/hooks>.

| Hook | Matcher | Transition | Hook type |
|---|---|---|---|
| `SessionStart` | — | claim a slot → `WELCOME` → `IDLE` | **command** (needs the terminal's environment) |
| `UserPromptSubmit` | — | → `BUSY` | http |
| `PreToolUse` | — | → `BUSY` (keepalive) | http |
| `PostToolUse` | — | → `BUSY` (keepalive) | http |
| `PostToolUseFailure` | — | → `BUSY` | http |
| `PermissionRequest` | — | → `ATTN` | http |
| `PermissionDenied` | — | → `BUSY` | http |
| `Notification` | `permission_prompt` | → `ATTN` | http |
| `Notification` | `idle_prompt` | **ignored** (see below) | http |
| `Notification` | `agent_needs_input` | → `ATTN` | http |
| `Notification` | `elicitation_dialog`, `elicitation_url_dialog` | → `ATTN` | http |
| `Notification` | `agent_completed` | → `IDLE` | http |
| `Elicitation` | — | → `ATTN` | http |
| `Stop` | — | → `IDLE` | http |
| `StopFailure` | — | → `ATTN` (API error — a human is needed) | http |
| `SubagentStart` / `SubagentStop` | — | **no state change** (only extends the session's lifetime) | http |
| `PreCompact` / `PostCompact` | — | **no state change** | — |
| `SessionEnd` | — | release the slot → `OFF` | http |

### Why `idle_prompt` does not mean `ATTN`

`Notification(idle_prompt)` looks like "input required", but captured traffic shows
it is an **inactivity timer**: it fires exactly 60 seconds after the agent finishes
its turn.

```
17:34:19.679  Stop                        → IDLE (green)
17:35:19.695  Notification idle_prompt    exactly +60.0 s
              message: "Claude is waiting for your input"
```

It means the same thing as `Stop`: the agent is done and waiting for you. Mapping
it to `ATTN` would turn every idle agent red a minute after it answered, and red
would stop meaning "nothing happens without you".

**Rule: `ATTN` only when the agent is actually blocked on a decision** —
`PermissionRequest`, `Notification(permission_prompt)`,
`Notification(agent_needs_input)`, `Elicitation`, `StopFailure`.
`idle_prompt` does not change the state at all.

Self-healing sequences the state machine is tested against:

```
Pre(BUSY) → PermissionRequest(ATTN) → [user allows] → PostToolUse(BUSY) → Stop(IDLE)
Pre(BUSY) → PermissionRequest(ATTN) → [user denies] → PermissionDenied(BUSY) → Stop(IDLE)
Stop(IDLE) → Notification(idle_prompt, +60 s) (state does NOT change, stays IDLE)
```

### Why subagents do not turn the light yellow

Claude Code launches forked agents on its own while you are away: `away_summary`
(after ~3 minutes of inactivity), `prompt_suggestion`, `agent_summary`, and it may
compact the context while idle. If `SubagentStart`/`SubagentStop` mapped to `BUSY`,
an idle agent would turn yellow a few minutes after `Stop` and stay that way until
`busy_timeout_sec`. A real subagent runs inside a turn, when the slot is already
yellow from `UserPromptSubmit`/`PreToolUse`, so nothing is lost by ignoring them.

To debug cases like this, the daemon logs every hook (without prompts or tool
contents) to `~/.agentlight/hooks.jsonl`.

### `/clear` and `--resume`

`/clear` produces `SessionEnd(end_reason="clear")` followed by
`SessionStart(source="clear")` with a **new** `session_id`. Releasing the slot on
`SessionEnd` right away would make the light blink off and possibly move the agent
to another slot.

So on `SessionEnd` with `end_reason ∈ {clear, resume}` the slot is not released
but marked `rebinding` for 15 seconds, keyed by `(cwd, claude_pid)`. The next
`SessionStart` with the same key takes the same slot and does **not** play the
welcome animation.

## 1.4. Slot allocation

```
claim(session_id, cwd, pid):
  1. if session_id already has a slot → return it
  1a. if the claude process has no window (spare, or daemon-hosted with no live owner tab) → hidden "background" list
  2. if a slot is in `rebinding` with key (cwd, pid) → take it, no welcome
  3. if the config pins cwd (or a parent path) to a slot and that slot is free → take it
  4. otherwise → the lowest free index 0..slot_count-1
  5. if nothing is free → overflow queue (no light)
```

* **Daemon-hosted sessions** (`claude --bg`, a session forked to the background) run
  under Claude Code's own daemon: their parent is `bg-pty-host`, and their pty is
  not a terminal window. The user watches them from the tab that started the daemon
  (`claude daemon run --spawned-by {"pid":N}`). While that claude process N is alive,
  the session gets its own light, and the hook reports N's terminal (tty and env),
  so the focus button switches to that tab. A session with no live owner tab, and
  the spare `--bg-spare` process Claude Code pre-spawns (it runs `SessionStart`
  without a user), get no light: their events go to the hidden `background` list
  (shown by `agentlight status`), and the entry is dropped on `SessionEnd` or when
  the process dies. The check also runs in the 5-second sweep, which moves sessions
  between slots and `background` both ways.
* `release(slot)` happens on `SessionEnd`, on a liveness check (`kill(pid, 0)`
  every 5 s), or on a TTL (no events for 8 hours). The TTL only applies to sessions
  without a known PID, and time the Mac spends asleep does not count.
* **Esc** (interrupting a turn, dismissing a question or a permission prompt) sends
  no hook. The daemon tails the session transcript and treats the
  `[Request interrupted by user…]` line as → `IDLE`.
* When a slot is released, the occupied slots to its right shift left, so there are
  no gaps between lights (shifted slots do not replay the welcome animation; mute
  and `rebinding` move with the slot). The overflow session with the most recent
  event moves into the first free slot (and does get a welcome). Pins and the
  empty-slot button only affect where a session lands when it starts.
* The mapping is persisted in `~/.agentlight/state.json` (atomic write via a temp
  file + rename), so restarting the daemon keeps the assignments.

### Configuration

`~/.agentlight/config.json`:

```json
{
  "port": 48879,
  "brightness": 120,
  "slot_count": 4,
  "pins": {
    "/Users/me/projects/agentlight": 0,
    "/Users/me/work/backend": 1
  },
  "busy_timeout_sec": 900,
  "idle_pulse": false,
  "empty_slot_button_launches": "~/projects",
  "terminal_focus_order": ["tmux", "native", "new_window"]
}
```

`slot_count` is the number of lights in the app (1–16, default 4; also editable in
**Settings…**). One device shows 4 of them: the first connected device shows slots
0..3, the second 4..7, and so on ([§5.8](05-host-macos.md#58-usb-transport)). Slots
without a device are only visible in the menu bar. Lowering `slot_count` moves
sessions from the removed slots to overflow; raising it fills the new slots from
overflow.

## 1.5. Two-level watchdog

| Level | Condition | Action |
|---|---|---|
| host → slot | no events in `BUSY` for `busy_timeout_sec` (900 s) | degrade to `IDLE` |
| host → slot | `kill(pid, 0)` fails | `release` → `OFF` |
| device → all slots | no `PING` from the host for > 3 s | turn every light off |

The last one keeps the lights honest: if the daemon crashes or the Mac goes to
sleep, the lights go dark on their own instead of showing a stale green.

## 1.6. Buttons

| Press | Slot occupied | Slot empty |
|---|---|---|
| short | focus the agent's terminal window | start a new `claude` in the directory from `empty_slot_button_launches` |

A button has exactly one action and reacts immediately — there are no long-press or
double-press gestures, so no press is delayed waiting for a second one. Muting a
slot is available as `agentlight mute <slot>`. Debouncing happens in the firmware;
the host receives a ready `!BTN <slot> press`.

## 1.7. Repository layout

```
agentlight/
├── firmware/              # RP2040 firmware, Pico SDK + TinyUSB, C
│   └── src/               # leds, anim, buttons, power, proto, transport_hid, usb_descriptors, …
├── host/                  # macOS app: Swift package
│   ├── Sources/
│   │   ├── AgentLightKit/ # slots, state machine, transports, hooks — no UI, unit-tested
│   │   ├── agentlightd/   # the daemon + menu bar UI
│   │   └── agentlight/    # CLI: install-hooks, status, doctor, …
│   ├── Tests/
│   └── scripts/           # build-app.sh (AgentLight.app), icon generator
├── hardware/pcb/          # KiCad board, generated by Python scripts; JLCPCB fab outputs
├── packaging/homebrew/    # Homebrew cask template
├── tools/
│   ├── proto_test.py      # firmware protocol test over CDC
│   ├── flash.sh           # build + flash without pressing BOOT
│   └── hook-capture/      # HTTP hook capture server + recorded samples (test fixture)
└── docs/
```
