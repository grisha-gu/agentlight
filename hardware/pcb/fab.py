"""Файлы для JLCPCB: Gerber + сверловка (zip), BOM и CPL для PCBA обратной стороны.

Запуск питоном из KiCad после gen_board.py. Результат — build/jlc/.
Светодиоды, модуль и крепёж помечены hand (gen_board.py) — в BOM/CPL их нет, паяются вручную.
"""
import collections
import csv
import math
import os
import re
import shutil
import subprocess

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
PCB = os.path.join(HERE, "agentlight.kicad_pcb")
OUT = os.path.join(HERE, "build", "jlc")
CLI = "/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli"

shutil.rmtree(OUT, ignore_errors=True)
gerbers = os.path.join(OUT, "gerbers")
os.makedirs(gerbers)

layers = "F.Cu,B.Cu,F.Paste,B.Paste,F.Silkscreen,B.Silkscreen,F.Mask,B.Mask,Edge.Cuts"
subprocess.run([CLI, "pcb", "export", "gerbers", "--layers", layers, "--subtract-soldermask",
                "-o", gerbers + "/", PCB], check=True, stdout=subprocess.DEVNULL)
subprocess.run([CLI, "pcb", "export", "drill", "--format", "excellon", "--excellon-separate-th",
                "--generate-map", "--map-format", "gerberx2", "-o", gerbers + "/", PCB],
               check=True, stdout=subprocess.DEVNULL)
shutil.make_archive(os.path.join(OUT, "agentlight-gerbers"), "zip", gerbers)

board = pcbnew.LoadBoard(PCB)

def natural(ref):
    """R2 перед R10 — чтобы позиции на странице завода было легко сверять."""
    m = re.match(r"([A-Z]+)(\d+)", ref)
    return (m.group(1), int(m.group(2)))


parts = sorted((fp for fp in board.GetFootprints() if not fp.IsExcludedFromBOM()),
               key=lambda f: natural(f.GetReference()))

# BOM: одна строка на номинал + футпринт.
groups = collections.OrderedDict()
for fp in parts:
    lcsc = fp.GetFieldText("LCSC") if fp.HasField("LCSC") else ""
    key = (fp.GetValue(), fp.GetFPID().GetLibItemName().wx_str(), lcsc)
    groups.setdefault(key, []).append(fp.GetReference())
with open(os.path.join(OUT, "agentlight-bom.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["Comment", "Designator", "Footprint", "LCSC Part #"])
    for (value, footprint, lcsc), refs in groups.items():
        w.writerow([value, ",".join(refs), footprint, lcsc])

# Футпринты JLC (EasyEDA) центрированы и повёрнуты не так, как наши: центр детали в локальных
# координатах нашего футпринта (до переворота на обратную сторону) и добавка к повороту.
# Найдено подгонкой площадок из EasyEDA к площадкам на плате (2026-10-28); SOT-23, 0805 совпадают и так.
JLC_FIX = {
    "PinSocket_1x08_P2.54mm_Vertical": ((0, 3.5 * 2.54), -90),
    "PinSocket_1x07_P2.54mm_Vertical": ((0, 3 * 2.54), -90),
    "SW_MX_HS_CPG151101S11_1u": ((0.641, -3.81), 0),
    "SW_SPDT_Shouhan_MSK12C02": ((0, -0.25), 180),
}


def jlc_place(fp):
    """Центр и поворот детали так, как их понимает JLCPCB."""
    (lx, ly), drot = JLC_FIX.get(fp.GetFPID().GetLibItemName().wx_str(), ((0, 0), 0))
    if fp.IsFlipped():
        ly = -ly
    a = math.radians(fp.GetOrientationDegrees())
    p = fp.GetPosition()
    x = pcbnew.ToMM(p.x) + lx * math.cos(a) + ly * math.sin(a)
    y = pcbnew.ToMM(p.y) - lx * math.sin(a) + ly * math.cos(a)
    return x, y, (fp.GetOrientationDegrees() + drot) % 360


# CPL: координаты от левого нижнего угла платы, Y вверх (как ждёт JLCPCB).
bb = board.GetBoardEdgesBoundingBox()
x0, y0 = bb.GetLeft(), bb.GetBottom()
with open(os.path.join(OUT, "agentlight-cpl.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["Designator", "Mid X", "Mid Y", "Layer", "Rotation"])
    for fp in parts:
        x, y, rot = jlc_place(fp)
        w.writerow([fp.GetReference(), f"{x - pcbnew.ToMM(x0):.3f}mm", f"{pcbnew.ToMM(y0) - y:.3f}mm",
                    "Bottom" if fp.IsFlipped() else "Top", f"{rot:.0f}"])

print(OUT)
for name in sorted(os.listdir(OUT)):
    print(" ", name)
print(" ", len(parts), "деталей в PCBA,", len(groups), "позиций BOM")
