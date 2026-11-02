# AgentLight

An open-source USB desk indicator for [Claude Code](https://code.claude.com) agents.
Four columns of traffic lights show what each running agent is doing; the button under
a column brings that agent's terminal tab to the front.

```
         ╱───────────────────────────────╲
        ╱   ●     ●     ●     ●           ╲   red    — needs your input
       ╱    ●     ●     ●     ●            ╲  yellow — working
      ╱     ●     ●     ●     ●             ╲ green  — done, ready for input
     ╱    ┌───┐ ┌───┐ ┌───┐ ┌───┐            ╲
    ╱     │ 1 │ │ 2 │ │ 3 │ │ 4 │             ╲ button — focus the agent's terminal
   ╱      └───┘ └───┘ └───┘ └───┘              ╲
  └────────────────────────────────────────────┘
```

A flat box about 97 × 97 mm with a 4 × 4 grid, like a stream deck. It connects to a Mac
over USB-C; everything sits on a single PCB built around an RP2040.

The project has three parts, all in this repository:

* **hardware** — a two-layer PCB (KiCad) with 12 through-hole LEDs, 4 MX key switches
  in hot-swap sockets and a Waveshare RP2040-Zero module; a 3D-printed enclosure;
* **firmware** — C on the Raspberry Pi Pico SDK + TinyUSB: a composite vendor HID +
  CDC device;
* **host** — a macOS menu bar app and CLI in Swift that receives Claude Code hooks and
  drives the device. It also works without the device: the same lights are shown in
  the menu bar.

## States

| Agent state | Light | Claude Code hook events |
|---|---|---|
| thinking / running tools | 🟡 yellow | `UserPromptSubmit`, `PreToolUse`, `PostToolUse` |
| needs input (permission, question) | 🔴 red | `PermissionRequest`, `Notification(permission_prompt / agent_needs_input)`, `Elicitation` |
| idle, ready for input | 🟢 green | `Stop`, `Notification(agent_completed)` |
| not connected | ⚫ off | `SessionEnd`, timeout, daemon gone |
| connected | welcome animation | `SessionStart` |

## How it works

```
┌──────────────────────┐
│  Claude Code #1..#N  │  hooks (http + command)
└──────────┬───────────┘
           │ POST http://127.0.0.1:48879/hook
┌──────────▼───────────────────────────────────┐
│  agentlightd  (Swift, LaunchAgent)           │
│   • HTTP server for hooks                    │
│   • slot allocator: session_id → slot 0..N-1 │
│   • state machine per slot                   │
│   • terminal tab focus (AppleScript)         │
└──────────┬───────────────────────────────────┘
           │ USB: vendor HID reports (+ CDC for logs)
┌──────────▼───────────────────────────────────┐
│  RP2040 firmware                             │
│   • 12 LEDs (4 × R/Y/G), 14-bit PWM          │
│   • 4 buttons, debounce                      │
│   • animations, gamma, colour calibration    │
│   • watchdog: no heartbeat → all lights off  │
└──────────────────────────────────────────────┘
```

## Getting started

Install the macOS app:

```bash
brew install --cask grisha-gu/tap/agentlight
agentlight install-daemon      # start at login
agentlight install-hooks       # add hooks to ~/.claude/settings.json (existing hooks are kept)
agentlight doctor
```

Then start `claude` in Terminal.app: the menu bar shows its light. With the device
plugged in, the same state appears on the device.

To build the device, start with [docs/06-assembly.md](docs/06-assembly.md).

## Documentation

| File | Contents |
|---|---|
| [docs/01-architecture.md](docs/01-architecture.md) | state machine, hook mapping, slot allocation |
| [docs/02-hardware.md](docs/02-hardware.md) | parts, schematic, pinout, PCB, BOM, enclosure |
| [docs/03-protocol.md](docs/03-protocol.md) | USB protocol between the host and the device |
| [docs/04-firmware.md](docs/04-firmware.md) | firmware structure, animations, building and flashing |
| [docs/05-host-macos.md](docs/05-host-macos.md) | daemon, hook installation, terminal focus, launchd |
| [docs/06-assembly.md](docs/06-assembly.md) | ordering the board, assembly, troubleshooting |
| [host/README.md](host/README.md) | building and installing the macOS app |
| [hardware/pcb/README.md](hardware/pcb/README.md) | generating the PCB; [ORDER.md](hardware/pcb/ORDER.md) — ordering from JLCPCB |

## Repository layout

```
firmware/            RP2040 firmware (C, Pico SDK)
host/                macOS daemon, menu bar app and CLI (Swift)
hardware/pcb/        KiCad PCB and the scripts that generate it
packaging/homebrew/  Homebrew cask
tools/               protocol test, flashing script, hook capture
docs/                design documentation
```

## Status

| Part | Status |
|---|---|
| Firmware | 0.6.0, tested on a breadboard prototype |
| macOS app | 0.2.0, released (Homebrew, signed and notarized) |
| PCB | rev. a, ordered |
| Enclosure | in design |

## USB identifiers

The device enumerates as a composite device (vendor-defined HID, usage page `0xFF00`,
plus CDC-ACM) with the manufacturer and product string `AgentLight`. During
development it uses the Pico SDK default VID:PID `2E8A:000A`; a dedicated PID under
the [pid.codes](https://pid.codes) VID `0x1209` will replace it.

## License

* Software (`firmware/`, `host/`, `tools/`, `packaging/`) — [MIT](LICENSE).
* Hardware (`hardware/`) — [CERN-OHL-P-2.0](hardware/LICENSE).
* Documentation (`docs/`) — [CC-BY-4.0](docs/LICENSE).

Third-party: the Kailh hot-swap footprint is adapted from
[ebastler/marbastlib](https://github.com/ebastler/marbastlib) (CERN-OHL-P-2.0);
`firmware/pico_sdk_import.cmake` comes from the Raspberry Pi Pico SDK (BSD-3-Clause).

AgentLight is an independent project and is not affiliated with Anthropic.
