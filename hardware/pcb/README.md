# AgentLight PCB rev. a

The board is generated entirely by scripts — edit them, not `agentlight.kicad_pcb`
(the next build overwrites it). Circuit and parts:
[docs/02-hardware.md](../../docs/02-hardware.md).

Licensed under [CERN-OHL-P-2.0](../LICENSE).

```sh
./build.sh      # generate + route → DRC → build/jlc/ (Gerber zip, BOM, CPL) + renders + 1:1 PDFs
```

| File | What it does |
|---|---|
| `gen_board.py` | geometry (20.32 mm grid, 91 × 91 mm board), parts, nets, **tracks**, outline, mounting holes, GND pour, design rules |
| `gen_module_fp.py` | RP2040-Zero pin map and outline footprint (2 × 9 side pins + 5 on the bottom edge) |
| `drc.sh` | DRC summary, silkscreen checks excluded |
| `fab.py` | JLCPCB outputs: Gerbers + drill, BOM and CPL for the back side |
| `agentlight.pretty/` | custom footprints; the Kailh hot-swap footprint is adapted from [ebastler/marbastlib](https://github.com/ebastler/marbastlib) (CERN-OHL-P-2.0) |

Requires KiCad 10 (the scripts run with KiCad's bundled Python, `pcbnew` API).

Routing is deterministic and done by the script, not an autorouter: the bus runs as
horizontal tracks on the front side below the module; each slot has a vertical lane on
the back side to the right of its column, with short stubs to the resistors; all corners
are 45°. Details are in the comments in `gen_board.py`.

Ordering: [ORDER.md](ORDER.md).

Hand-assembled (not in the factory BOM/CPL): 12 LEDs, the module itself, mounting
hardware. The module sockets J1–J3 are through-hole parts placed by the factory
(Hong Cheng HC-PM254-5.0H, 5 mm low profile).

Expected DRC warnings:

* J1–J3 corners (`courtyards_overlap`): the bottom socket butts against the side ones,
  as the RP2040-Zero pinout requires;
* `isolated_copper`: narrow pour slivers between bus tracks, kept to avoid voids.
