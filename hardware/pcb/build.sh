#!/bin/sh
# The whole board: generation (with routing) → DRC → factory files (build/jlc) and pictures (build/*.png).
set -e
cd "$(dirname "$0")"
PY=/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python3
CLI=/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli
quiet() { grep -v -E "wxApp|stdpbase| INFO | WARN " || true; }
$PY gen_module_fp.py | quiet
$PY gen_board.py 2>&1 | quiet
./drc.sh
$PY fab.py 2>&1 | quiet
for side in top bottom; do
    $CLI pcb render --side $side --width 1400 --height 1400 --quality basic -o build/$side.png agentlight.kicad_pcb >/dev/null
done
# 1:1 for checking on paper (docs/02-hardware.md §2.8): print without scaling, lay the parts on it.
$CLI pcb export pdf --layers F.Cu,F.Silkscreen,Edge.Cuts --include-border-title -o build/paper-front.pdf agentlight.kicad_pcb >/dev/null
$CLI pcb export pdf --layers B.Cu,B.Silkscreen,Edge.Cuts --mirror --include-border-title -o build/paper-back.pdf agentlight.kicad_pcb >/dev/null
