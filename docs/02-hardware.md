# 02. Hardware

The device is a single two-layer PCB (rev. a, 91 × 91 mm) in a flat printed box.
The front side faces the panel and carries only the 12 LEDs and 4 key switches; all
other parts sit on the back and are assembled by the PCB factory.

KiCad files and generator scripts: [`hardware/pcb/`](../hardware/pcb/README.md).
Licensed under [CERN-OHL-P-2.0](../hardware/LICENSE).

## 2.1. Microcontroller

**Waveshare RP2040-Zero**: RP2040, native USB on a USB-C connector, 2 MB flash,
16 PWM channels, 20 GPIOs on the edges plus 9 on the bottom pads, ~$7.

It plugs into low-profile pin sockets on the back of the board, so it can be replaced
without soldering. Its USB-C connector sits at the rear edge of the board and is
exposed through a cut-out in the back wall of the enclosure — no extension cable.

| Alternative | Why not |
|---|---|
| Raspberry Pi Pico / Pico 2 | micro-USB |
| Seeed XIAO RP2040 / Adafruit QT Py RP2040 | too few GPIOs (16+ needed) |
| Pimoroni Tiny 2350 (RP2350) | would work; fine if you prefer RP2350 |
| ESP32-S3 | overkill, no Wi-Fi needed |
| ATmega32U4 / Pro Micro | too few PWM channels, too little memory |

## 2.2. LEDs: plain through-hole, not addressable

12 LEDs: 4 columns × red / yellow / green, each on its own PWM channel.

Why not WS2812 / SK6812 addressable LEDs:

| Argument for addressable | Why it does not matter here |
|---|---|
| 1 pin instead of 12 | RP2040 has 8 slices × 2 channels = 16 PWM outputs; `GP0–GP11` give 12 independent channels |
| no resistor matching for brightness | brightness is balanced in software via PWM |
| smooth crossfades | hardware PWM does it better: **14-bit** (`wrap = 16383`) vs 8-bit |
| colour configurable in firmware | the colours are fixed: red, yellow, green |

What plain LEDs give instead:

1. **A 10 mm diffused LED is its own lens.** No printed light guides.
2. **True spectral colours.** A 590 nm amber looks like a traffic light; WS2812
   "yellow" is a red + green mix.
3. **14-bit PWM.** A desk device runs at 10–20 % brightness, where 8 bits show
   visible steps during fades.
4. No level shifter, no PIO timing, no power limiter, no bulk capacitor.
5. **Fails per element**: a dead LED is one dark lamp, not a dead chain.
6. Lower current; the USB budget is a non-issue.
7. Debuggable with a multimeter.

The firmware hides the output method behind `led_set(index, level)`, so switching to
addressable LEDs later would only change `leds.c`.

### Which LEDs

**10 mm, diffused, round dome.** "10 mm flat top" is practically not
manufactured (flat-top and straw-hat packages are 3/5/8 mm). Avoid `water clear` —
it gives a bright dot instead of a glowing spot.

| Colour | Wavelength | Vf | Drive |
|---|---|---|---|
| red | 620–630 nm | ~2.0 V | GPIO 3.3 V → 220 Ω → LED → GND |
| yellow / amber | 585–595 nm | ~2.1 V | GPIO 3.3 V → 220 Ω → LED → GND |
| green, "pure" InGaN | 520–525 nm | ~3.0–3.4 V | 5 V → 330 Ω → LED → NPN (low-side switch), GPIO → 1 kΩ → base |

A 525 nm green has too little headroom at 3.3 V for a resistor to set a predictable
current, hence the 5 V rail and the transistor. A 565 nm yellow-green (Vf ~2.2 V)
could be driven directly from a GPIO through 180 Ω, but it looks noticeably less
green behind the diffuser.

Most 10 mm LEDs have a **flange** (~11.4 mm) at the base. It rests against the
inside of the panel, so the LED positions itself; the dome protrudes ~3.5 mm.

## 2.3. Resistors and current

Sized for ~6 mA per LED (plenty for a desk device; PWM dims further):

```
R_red    = (3.3 − 2.0) / 0.006       = 217 Ω → 220 Ω
R_yellow = (3.3 − 2.1) / 0.006       = 200 Ω → 220 Ω
R_green  = (5.0 − 3.0 − 0.1) / 0.006 = 317 Ω → 330 Ω   (0.1 V = transistor saturation)
R_base   = 1 kΩ: (3.3 − 0.7) / 1000  = 2.6 mA, enough to saturate the NPN at 6 mA
```

Perceived brightness differs per colour; the firmware balances it with per-colour
coefficients (`LED_CAL_INIT` in `firmware/src/config.h`). The resistor sets the
**maximum**; PWM only dims.

LED GPIOs use 8 mA drive strength.

### Current budget

| Mode | Current |
|---|---|
| RP2040 + USB | ~30 mA |
| normal use: one LED per column at 50 % PWM | ~12 mA |
| green transistor bases, 4 × 2.6 mA (only while lit) | ~10 mA |
| all 12 LEDs at full brightness | ~72 mA |
| **maximum** | **~115 mA** (USB 2.0 budget: 500 mA) |

## 2.4. Buttons

Four Cherry MX–compatible key switches, one under each column, in **Kailh hot-swap
sockets** on the back of the board. The switch is pushed in from the outside through
the panel; no soldering, and switches can be swapped.

Each button: GPIO (internal pull-up) → 220 Ω → switch → GND, with 100 nF from the
switch node to GND, plus a 20 ms software debounce.

## 2.5. Power switch

A side-actuated slide switch (MSK-12C02) at the rear edge, next to USB-C.
**It is a logical switch, not a power switch**: USB goes straight into the module,
and the RP2040-Zero does not expose USB data on its pins, so the 5 V rail cannot be
cut on this board.

* Closed to GND = **off**, open = on. Without the switch the device simply works.
* Same RC network as the buttons: 220 Ω in series + 100 nF to GND; 30 ms debounce.
* When off, the firmware fades out all 12 LEDs and the on-board RGB LED and mutes the
  buttons. It keeps accepting state updates, so switching back on shows the current
  picture right away. USB stays connected (~30 mA).
* The host learns about it from the `POWER` event and the `power` field of `READY`
  ([03-protocol.md](03-protocol.md)) and shows "device switched off" in the menu bar.

## 2.6. Pinout (RP2040-Zero)

RP2040's GPIO → PWM mapping is fixed: `slice = (gpio / 2) % 8`, channel `A` for even
pins, `B` for odd. `GP0–GP11` are slices 0–5: 12 fully independent channels.

| Pin | Slice/ch. | Function |
|---|---|---|
| `GP0` | 0A | column 1 — red |
| `GP1` | 0B | column 1 — yellow |
| `GP2` | 1A | column 1 — green (via NPN Q1) |
| `GP3` | 1B | column 2 — red |
| `GP4` | 2A | column 2 — yellow |
| `GP5` | 2B | column 2 — green (Q2) |
| `GP6` | 3A | column 3 — red |
| `GP7` | 3B | column 3 — yellow |
| `GP8` | 4A | column 3 — green (Q3) |
| `GP9` | 4B | column 4 — red |
| `GP10` | 5A | column 4 — yellow |
| `GP11` | 5B | column 4 — green (Q4) |
| `GP12`–`GP15` | — | buttons, columns 1–4 (pull-up, active low) |
| `GP16` | — | on-board WS2812 RGB LED — host heartbeat indicator |
| `GP26` | — | power switch (pull-up, closed = off) |
| `GP27–GP29` | — | unused |

In firmware: `led_pin(slot, color) = slot * 3 + color`, `color ∈ {RED=0, YELLOW=1,
GREEN=2}`. The LED index equals the GPIO number on purpose — no lookup tables.

## 2.7. Schematic

The board has no separate schematic file: it is generated by
[`hardware/pcb/gen_board.py`](../hardware/pcb/gen_board.py), which defines every part
and net. The circuit, per column `n = 0..3` (GPIO `g = 3n + color`):

```
RP2040-Zero
┌──────────┐
│ GP(3n)   ├──[220Ω]──► LED red    anode;  cathode → GND
│ GP(3n+1) ├──[220Ω]──► LED yellow anode;  cathode → GND
│ GP(3n+2) ├──[1kΩ]───► base of Q(n+1) (S8050, SOT-23); emitter → GND
│          │   +5V ──[330Ω]──► LED green anode; cathode → collector of Q(n+1)
│ GP(12+n) ├──[220Ω]──┬── MX switch (hot-swap socket) ── GND
│          │        [100nF]
│          │          └── GND
│ GP26     ├──[220Ω]──┬── slide switch SW5 ── GND
│          │        [100nF]
│          │          └── GND
│ 5V       ├──► +5V rail (green LEDs); 10 µF + 100 nF to GND near the module
│ GND      ├──► GND pour on both layers
└──────────┘
```

The GPIO never sees 5 V and the logic is not inverted: GPIO high = LED on.

## 2.8. PCB rev. a

| | |
|---|---|
| Size | 91 × 91 mm, 2 layers, 1.6 mm, GND pour on both sides |
| Grid | 4 × 4 cells, **20.32 mm** pitch (= 8 × 2.54 mm) |
| Tracks | 0.25 mm, 0.2 mm clearance, hand-routed by the generator script, 45° corners |
| Mounting | 4 × M3 holes in the corners |
| Front side | 12 × LED 10 mm (hand-soldered), 4 × MX switch (plugged into sockets) |
| Back side (factory) | 0805 resistors and capacitors, 4 × S8050 (SOT-23), 4 × Kailh hot-swap sockets, slide switch, module sockets |
| Module | RP2040-Zero in 5 mm low-profile sockets (2 × 1×8 + 1×7), USB-C at the rear edge |

Placement, per side:

```
                rear edge (USB-C, power switch)
   ┌────────────────────────────────────────────┐
   │      ●          ●          ●          ●    │  row 1 — red
   │      ●          ●          ●          ●    │  row 2 — yellow
   │      ●          ●          ●          ●    │  row 3 — green
   │    ┌───┐      ┌───┐      ┌───┐      ┌───┐  │
   │    │ 1 │      │ 2 │      │ 3 │      │ 4 │  │  row 4 — key switch
   │    └───┘      └───┘      └───┘      └───┘  │
   └────────────────────────────────────────────┘
        column = one agent (slot 0..3)
```

### Bill of materials

Factory-assembled (back side, JLCPCB part numbers):

| Ref | Part | Qty | LCSC |
|---|---|---|---|
| R1, R2, R4, R5, R7, R8, R10, R11, R31–R35 | 220 Ω 0805 | 13 | C17557 |
| R3, R6, R9, R12 (green) | 330 Ω 0805 | 4 | C17630 |
| R21–R24 | 1 kΩ 0805 | 4 | C17513 |
| C1–C5, C7 | 100 nF 0805 | 6 | C49678 |
| C6 | 10 µF 0805 | 1 | C15850 |
| Q1–Q4 | S8050 NPN, SOT-23 | 4 | C2146 |
| SW1–SW4 | Kailh MX hot-swap socket CPG151101S11-16 | 4 | C41430893 |
| SW5 | MSK-12C02 side slide switch | 1 | C431540 |
| J1, J2 | pin socket 1×8, 2.54 mm, 5 mm high (HC-PM254-5.0H) | 2 | C27985233 |
| J3 | pin socket 1×7, 2.54 mm, 5 mm high (HC-PM254-5.0H) | 1 | C27985232 |

The authoritative BOM and placement files are generated by `./build.sh` into
`hardware/pcb/build/jlc/`.

Hand-assembled:

| Part | Qty | Notes |
|---|---|---|
| Waveshare RP2040-Zero | 1 | trim its header pins to ~4 mm for the 5 mm sockets |
| LED 10 mm diffused, red 620–630 nm | 4 | |
| LED 10 mm diffused, yellow 585–595 nm | 4 | |
| LED 10 mm diffused, green 520–525 nm | 4 | |
| MX-compatible key switch + 1u keycap | 4 | any 3- or 5-pin switch |
| M3 screws, M3 heat-set inserts | 4 + 4 | board to panel bosses |
| USB-C ↔ USB-C cable with data | 1 | |

Order a few spare LEDs: tint and brightness vary between batches.

## 2.9. Enclosure

> The enclosure is not finished yet; this section describes the design it is built
> around. Model files will be published under `enclosure/` (CERN-OHL-P-2.0).

A flat box, like a stream deck: the panel is the lid, parallel to the board.
Two fold-out legs at the back tilt it; folded, it lies flat.

```
         ╱───────────────────────────────╲
        ╱   ●     ●     ●     ●           ╲   row 1 — red
       ╱    ●     ●     ●     ●            ╲  row 2 — yellow
      ╱     ●     ●     ●     ●             ╲ row 3 — green
     ╱    ┌───┐ ┌───┐ ┌───┐ ┌───┐            ╲
    ╱     │ 1 │ │ 2 │ │ 3 │ │ 4 │             ╲ row 4 — button
   ╱      └───┘ └───┘ └───┘ └───┘              ╲
  └────────────────────────────────────────────┘
```

| Parameter | Value |
|---|---|
| Outside | ~97 × 97 mm, height ~30 mm |
| Panel | 10 mm thick |
| Parts | box, bottom plate, 2 legs (FDM, PETG/ABS, matte black) |
| Board mounting | 4 × M3 into heat-set inserts on 3.4 mm bosses inside the panel |

Why a 10 mm panel:

* **LED cell** — a Ø10.3 mm hole through the full thickness. The LED is pushed in
  from the inside until its flange stops it; the dome protrudes ~3.5 mm. The LED body
  fills the hole, so the hole doubles as a **light well** — no light bleed between
  cells, no internal baffles.
* **Switch cell** — a 14.2 × 14.2 mm cut-out with a pocket that leaves **1.5 mm**
  of material (the standard MX plate thickness), so the switch clips into the panel.
* The board sits **3.4 mm** behind the panel (the standard MX plate-to-PCB gap); the
  base of a flange-stopped LED then lands right at the board.

Print panel-face-down: the face comes out smooth, all holes are vertical and need no
supports. Recommended tolerances for a print service (±0.3 mm): LED holes Ø10.3,
MX cut-outs 14.2 × 14.2, M3 clearance Ø3.4, inserts Ø4.2. Print a 40 × 40 mm test
coupon (one LED hole + one switch cell) in the same order to check the fit.

The power switch lever is short (1.45 mm) and does not reach the outer wall, so a
small printed cap sits on it from the inside and sticks out through a slot in the
back wall.
