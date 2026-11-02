# 03. USB protocol

## 3.1. A composite USB device

One device, two interfaces:

| Interface | Purpose |
|---|---|
| **Vendor HID** (usage page `0xFF00`, usage `0x01`), 64-byte IN/OUT reports | main channel: commands and events |
| **CDC-ACM** (`/dev/cu.usbmodem*`) | firmware logs + the same command set in ASCII, for debugging |

Why HID is the main channel rather than CDC:

* there is no `/dev/cu.*` node that `screen`, an IDE or another process can grab;
* no driver and, for a vendor-defined usage page, no macOS privacy permission
  (unlike HID keyboards, which require Input Monitoring);
* fixed-size packets — no stream parsing, no merged lines;
* clean hot-plug: `IOHIDManager` reports matched/removed devices itself.

CDC is kept because typing commands into `screen /dev/cu.usbmodem101 115200` is the
fastest debugging tool there is.

### Identification

| Field | Value |
|---|---|
| VID:PID | currently `2E8A:000A` (the Raspberry Pi Pico SDK default), to be replaced by a dedicated PID under the [pid.codes](https://pid.codes) VID `1209` |
| Manufacturer / product string | `AgentLight` |
| Serial number | the RP2040 flash unique ID (`pico_get_unique_board_id`), hex |
| `bcdDevice` | `0x0100` |

The host matches devices by VID (`1209` or `2E8A`) together with the vendor usage
page `0xFF00`, so both IDs work. The serial number lets the host tell several devices apart.

## 3.2. Enumerations

```c
typedef enum {            // slot state
  ST_OFF   = 0,
  ST_IDLE  = 1,           // green
  ST_BUSY  = 2,           // yellow
  ST_ATTN  = 3,           // red
} slot_state_t;

typedef enum {            // button gestures
  BTN_PRESS  = 1,         // press: sent right after debouncing
  BTN_LONG   = 2,         // reserved, not sent by the firmware
  BTN_DOUBLE = 3,         // reserved
} btn_gesture_t;
```

## 3.3. Binary protocol (HID, 64-byte reports)

All reports are exactly 64 bytes; unused bytes are zero. Multi-byte values are
little-endian.

### Host → device (OUT report)

| Byte 0 (opcode) | Name | Payload |
|---|---|---|
| `0x01` | `SET_STATE` | `[1]=slot (0..3)`, `[2]=state` |
| `0x02` | `SET_ALL` | `[1..4]=state` for slots 0..3 — one frame, no tearing |
| `0x03` | `WELCOME` | `[1]=slot` (`0xFF` = a wave across all slots) |
| `0x04` | `BRIGHTNESS` | `[1]=0..255` |
| `0x05` | `PING` | `[1..4]=seq (u32)` — heartbeat, every 1000 ms |
| `0x06` | `HELLO` | — identification request |
| `0x07` | `SELFTEST` | — run the full test animation |
| `0x08` | `CONFIG` | `[1]=flags`: bit1 `busy_pulse`, bit2 `idle_pulse`; bit0 reserved |
| `0x09` | `RAW` | `[1..12]` = level 0..255 for each of the 12 LEDs — direct output (debugging / calibration) |

### Device → host (IN report)

| Byte 0 (opcode) | Name | Payload |
|---|---|---|
| `0x81` | `READY` | `[1]=proto_ver`, `[2]=slots`, `[3..5]=fw major/minor/patch`, `[6..13]=uid`, `[14]=power (1 on / 0 off)` |
| `0x82` | `BUTTON` | `[1]=slot`, `[2]=gesture`, `[3..6]=timestamp_ms (u32)` |
| `0x83` | `PONG` | `[1..4]=seq`, `[5..8]=uptime_ms`, `[9]=watchdog_tripped (0/1)` |
| `0x84` | `LOG` | `[1]=len`, `[2..]` = ASCII |
| `0x85` | `POWER` | `[1]=1` on / `0` off — the rear power switch ([02-hardware.md §2.5](02-hardware.md#25-power-switch)) |

`READY` is sent once after USB enumeration. It tells the host that the device has
rebooted, and the host re-sends `SET_ALL` + `BRIGHTNESS` + `CONFIG`.

## 3.4. ASCII protocol (CDC, same command set)

Lines are `\n`-terminated; commands are case-insensitive. Replies to a command start
with `OK` or `ERR`; asynchronous events start with `!`.

```
→ HELLO
← OK agentlight proto=1 fw=0.6.0 slots=4 uid=E66038B7132F4C23 power=on

→ SET 2 busy                  # slot state (off|idle|busy|attn)
← OK

→ SETALL idle busy attn off
← OK

→ WELCOME 0                   # WELCOME ALL — a wave across all slots
← OK

→ BRIGHT 120
← OK

→ PING 42
← OK PONG 42 uptime=135022 wd=0

→ SELFTEST
← OK

→ CONFIG busy_pulse=1 idle_pulse=0
← OK

→ RAW ff 00 00 00 ff 00 00 00 ff 80 80 80   # 12 levels 0..255 (hex), order = GP0..GP11
← OK

→ SET 9 busy
← ERR bad slot
```

Asynchronous, at any time:

```
← !READY proto=1 fw=0.6.0 slots=4 uid=E66038B7132F4C23 power=on
← !POWER off                  # rear switch: lights off, buttons muted
← !BTN 2 press t=135022
← !WD trip                    # the heartbeat watchdog fired, everything is off
← !LOG leds: frame overrun 3
```

One command parser, two transports: both HID and CDC decode into the same `cmd_t`
structure and push it into a shared queue.

## 3.5. Invariants

1. **The device knows nothing about sessions.** It only knows 4 slots and 4 states.
   All "who is in which slot" logic lives on the host. The device can be driven by
   hand through `screen`, and the host can be rewritten without touching the
   firmware. The protocol does not know the LED type either: switching to
   addressable LEDs would only change `leds.c` and widen `RAW` to 12 RGB triplets.
2. **The heartbeat is mandatory.** No `PING` for more than 3000 ms → the device turns
   everything off and sends `!WD trip`. On `!WD trip` or a reconnect the host
   re-sends the full state (`SET_ALL` + `BRIGHTNESS` + `CONFIG`).
3. **Idempotence.** `SET_STATE` with the current state restarts neither the
   animation nor the pulse. The host may resend state freely.
4. **Prefer `SET_ALL` over 4 × `SET_STATE`** — it avoids flashing intermediate
   combinations.
5. **Buttons do not depend on the host.** Debouncing is in the firmware; if the host
   is gone, presses are simply lost (and the lights are already off via the
   watchdog).
6. **The power switch is handled in the firmware.** With `power=off` the device
   turns the lights off and mutes the buttons by itself; it keeps accepting state
   commands and applies them when switched back on. The host only displays "off".
   The `power` field and the `POWER` event were added without bumping `proto_ver`:
   older hosts ignore them.
7. **Versioning.** `proto_ver` is reported in `READY`. The host refuses to talk to a
   `proto_ver` newer than it knows and logs a clear error.

## 3.6. Testing the protocol without the host

```bash
# connect to CDC
screen /dev/cu.usbmodem101 115200
# then type: HELLO, SET 0 busy, WELCOME ALL, SELFTEST, BRIGHT 40

# or one line at a time
printf 'SETALL idle busy attn off\n' > /dev/cu.usbmodem101

# full test suite (stop the daemon first so it releases the port)
python3 tools/proto_test.py --stop-daemon
```

`tools/proto_test.py` covers every command, invalid arguments, heartbeat loss →
`!WD trip`, reconnects, a 200 switches/s stress test and all 4 buttons; see
[04-firmware.md §4.9](04-firmware.md#49-test-checklist).
