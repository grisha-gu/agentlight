# Ordering the board from JLCPCB

All files are generated into `build/jlc/` by `./build.sh`:

| File | Where it goes |
|---|---|
| `agentlight-gerbers.zip` | step 1, "Add gerber file" |
| `agentlight-bom.csv` | step 3, BOM |
| `agentlight-cpl.csv` | step 3, CPL (pick & place) |

Stock changes; the order page shows what is actually available.

## 1. Board

On jlcpcb.com → **Order now** → upload `agentlight-gerbers.zip`. Size (91 × 91 mm) and
2 layers are detected automatically. Then:

* **PCB Qty** — 5 (the minimum).
* **PCB Thickness** — 1.6 mm. **Surface Finish** — HASL lead-free.
* **PCB Color** — any; the board is hidden behind the panel.
* **Mark on PCB** — **Remove Mark**, otherwise the order number may land on top of the
  silkscreen labels.

## 2. Assembly

Enable **PCB Assembly**:

* **PCBA Type** — **Standard** (Economic does not place the Kailh sockets or the
  through-hole module sockets).
* **Assembly Side** — **Bottom Side** (every factory part is on the back).
* **PCBA Qty** — 2 or more.
* **Tooling holes** — Added by JLCPCB.

## 3. BOM and CPL

Upload `agentlight-bom.csv` and `agentlight-cpl.csv`. On the parts page check:

* **10 lines, all matched.** If a part is out of stock, pick an equivalent with the
  same footprint.
* **Extended parts** — the Kailh sockets, the slide switch (C431540) and the module
  sockets carry a one-off feeder fee each; that is expected.
* **Kailh sockets SW1–SW4** — C41430893 (CPG151101S11-16).
* **Module sockets J1–J3** — Hong Cheng HC-PM254-5.0H: 1 × 8 C27985233 (J1, J2),
  1 × 7 C27985232 (J3), 5 mm high. The module's header pins must later be trimmed to
  ~4 mm.

## 4. Placement check

The factory shows the parts over the board. Centres and rotations in the CPL are
already corrected for JLCPCB's footprints (`JLC_FIX` in `fab.py`), but check by eye:

* **Transistors Q1–Q4** (below the green LEDs): the single pin (collector) points
  **up, towards the LED**; the two pins point down.
* **Kailh sockets SW1–SW4**: the two large socket pads match the two pads on the board.
* **Slide switch SW5**: the lever points **towards the board edge**.
* **Module sockets J1–J3**: exactly on the rows of holes around the module outline.
* Resistors and capacitors have no polarity; they just need to sit on their pads.

If something is rotated, fix it in the viewer and update `JLC_FIX` in `fab.py`.

## What arrives and what is left to do

The factory places everything except:

* **12 LEDs** — soldered last, with the board screwed to the enclosure panel
  (the back side marks `+` = anode, the long leg, and the R/Y/G rows);
* **the RP2040-Zero** — plugged into the sockets (trim its header pins to ~4 mm first);
* **the MX switches** — pushed into the Kailh sockets from the front, through the panel.

Next: [docs/06-assembly.md](../../docs/06-assembly.md).
