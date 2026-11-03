"""agentlight board generator (docs/02-hardware.md §2.5, §2.7, §2.8).

The whole board is described here: parts, nets, outline, mounting and tracks. Routing is done by hand
from the schematic (no autorouter), so every build produces the same board:

* bus — horizontal tracks on the front side (F) in the free band between the module and the yellow
  row, 0.7 mm pitch;
* each slot has its own "lane" — vertical tracks on the back side (B) to the right of the column
  (column + 9…11 mm), with short stubs from it to the cell resistors;
* layer change — a via at the end of a bus row; all corners chamfered at 45°.

Run with KiCad's python:
  /Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python3 gen_board.py

Coordinates: board center = center of the 4 × 4 grid, Y axis down (as in KiCad).
The top edge is the back (the case feet are there): the module's USB-C and the power switch face it.
Front side (F) — toward the panel: only 12 LEDs and 4 switches (in sockets, from outside).
Everything else is on the back (B), assembled by the factory; the socketed module and the LEDs are hand-soldered.
"""
import math
import os

import pcbnew

HERE = os.path.dirname(os.path.abspath(__file__))
KICAD_FP = "/Applications/KiCad/KiCad.app/Contents/SharedSupport/footprints"
OUT = os.path.join(HERE, "agentlight.kicad_pcb")

# --- geometry -------------------------------------------------------------------

PITCH = 20.32            # grid pitch = 8 × 2.54, matches the panel (§2.9)
BOARD = 91.0             # box ~97 outside, wall ~2.4, clearance ~0.75 per side
HOLE_INSET = 4.0         # M3 mounting holes from the edges
ORIGIN = (100.0, 100.0)  # board center on the sheet

COLS = [(-1.5 + i) * PITCH for i in range(4)]
ROW_RED, ROW_YELLOW, ROW_GREEN, ROW_SW = [(-1.5 + i) * PITCH for i in range(4)]
EDGE_TOP = -BOARD / 2

# Module: socket rows at x = column 1 ± 7.62 — that way they pass between the LED legs
# (6.35 mm to the nearest LED pad). Pin 1 (5V, USB side) is 1.5 mm from the back edge,
# so the end of the USB-C sticks ~2 mm past the board edge, into the back wall cutout.
MODULE_X = COLS[1]
MODULE_Y = EDGE_TOP + 1.5 + 10.16

# Power switch: on the back edge, right of the USB (a plug with its overmold is ~12 mm wide).
POWER_SW_X = COLS[2] + 4.0
# Case mounting pads (±1.1 from center) — no closer than 0.5 mm to the edge; the lever (1.45 mm)
# then sticks ~0.9 mm past the board edge. How it reaches the slot is solved in the case.
POWER_SW_Y = EDGE_TOP + 2.0

# Routing
TRACK = 0.25
# Pitch of parallel tracks: GND pour must fit between them (clearance 0.2 + 0.15 + 0.2),
# otherwise the bus leaves dark copper-free voids.
STEP = 0.85
CHAMFER = 0.6            # 45° corner chamfer
LANE = [8.76 + STEP * i for i in range(4)]   # offsets of a slot lane's tracks from its column
BUS_TOP = -21.3          # first bus row; module bottom −22.8, top of the yellow pads −11.1
RAIL_5V = 7.4            # 5 V horizontal on the front side, above the green row
ROW_BTN_PARTS = ROW_SW + 3.52                # button R and C under the socket

# --- parts (LCSC — JLCPCB basic library where available) ------------------------

R_0805 = ("Resistor_SMD", "R_0805_2012Metric")
C_0805 = ("Capacitor_SMD", "C_0805_2012Metric")
SOT23 = ("Package_TO_SOT_SMD", "SOT-23")
LED10 = ("LED_THT", "LED_D10.0mm")
HOTSWAP = ("agentlight", "SW_MX_HS_CPG151101S11_1u")
MODULE = ("agentlight", "RP2040-Zero_Outline")
SOCKET8 = ("Connector_PinSocket_2.54mm", "PinSocket_1x08_P2.54mm_Vertical")
SOCKET7 = ("Connector_PinSocket_2.54mm", "PinSocket_1x07_P2.54mm_Vertical")
SLIDE = ("Button_Switch_SMD", "SW_SPDT_Shouhan_MSK12C02")
M3 = ("MountingHole", "MountingHole_3.2mm_M3")

LCSC = {
    "220": "C17557",
    "330": "C17630",
    "1k": "C17513",
    "100n": "C49678",
    "10u": "C15850",
    "S8050": "C2146",
    "CPG151101S11": "C41430893",
    "MSK12C02": "C431540",
    # Module sockets — low-profile, part numbers chosen at order time (2026-10-28).
    "Socket_1x8": "C27985233",  # Hong Cheng HC-PM254-5.0H-1x8PZ, 5 mm
    "Socket_1x7": "C27985232",  # HC-PM254-5.0H-1x7PZ
}

COLOR = ["RED", "YELLOW", "GREEN"]

# Red and yellow value — from the breadboard (§2.3): 220 Ω. Green 525 nm — from 5 V via an NPN (§2.2).
R_LED = {"RED": "220", "YELLOW": "220"}

# --- assembly -------------------------------------------------------------------

board = pcbnew.BOARD()
nets = {}
fps = {}


def net(name):
    if name not in nets:
        n = pcbnew.NETINFO_ITEM(board, name)
        board.Add(n)
        nets[name] = n
    return nets[name]


def lib_path(lib):
    return os.path.join(HERE, "agentlight.pretty") if lib == "agentlight" else os.path.join(KICAD_FP, lib + ".pretty")


def mm(x, y):
    return pcbnew.VECTOR2I(pcbnew.FromMM(ORIGIN[0] + x), pcbnew.FromMM(ORIGIN[1] + y))


def xy(p):
    return pcbnew.ToMM(p.x) - ORIGIN[0], pcbnew.ToMM(p.y) - ORIGIN[1]


def place(ref, fp_id, value, x, y, rot=0, back=False, pads=None, sides=None, lcsc=None, hand=False):
    """pads: pad number → net; sides: "west/east/north/south" → net (the outermost pad
    on that side — so there's no need to remember where a lead ended up after rotation and flip).
    hand — hand-soldered, not in the factory BOM/CPL."""
    fp = pcbnew.FootprintLoad(lib_path(fp_id[0]), fp_id[1])
    fp.SetReference(ref)
    fp.SetValue(value)
    board.Add(fp)
    fp.SetPosition(mm(x, y))
    if rot:
        fp.SetOrientationDegrees(rot)
    if back:
        fp.SetLayerAndFlip(pcbnew.B_Cu)
    for p in fp.Pads():
        name = (pads or {}).get(p.GetNumber())
        if name:
            p.SetNet(net(name))
    numbered = [p for p in fp.Pads() if p.GetNumber()]
    key = {"west": lambda p: xy(p.GetPosition())[0], "east": lambda p: -xy(p.GetPosition())[0],
           "north": lambda p: xy(p.GetPosition())[1], "south": lambda p: -xy(p.GetPosition())[1]}
    for side, name in (sides or {}).items():
        min(numbered, key=key[side]).SetNet(net(name))
    if lcsc:
        fp.SetField("LCSC", lcsc)
        for f in fp.GetFields():
            if f.GetName() == "LCSC":
                f.SetVisible(False)
    if hand:
        fp.SetExcludedFromBOM(True)
        fp.SetExcludedFromPosFiles(True)
    # The factory places small SMD parts from the CPL — their labels would only overlap the pads.
    if ref[0] in "RCQJ" or ref == "SW5":
        fp.Reference().SetVisible(False)
    fps[ref] = fp
    return fp


def pad(ref, net_name):
    """Coordinates of a part's pad by net (the first one if there are several)."""
    for p in fps[ref].Pads():
        if p.GetNetname() == net_name:
            return xy(p.GetPosition())
    raise KeyError(f"{ref}: no pad {net_name}")


def gp(n):
    return f"GP{n}"


def module_pin(net_name):
    """The module socket contact on this net."""
    for ref in ["J1", "J2", "J3"]:
        for p in fps[ref].Pads():
            if p.GetNetname() == net_name:
                return xy(p.GetPosition())
    raise KeyError(net_name)


# LEDs: column = slot, row = color; GPIO = slot * 3 + color (§2.6).
# Footprint: pad 1 — cathode (square), 2 — anode 2.54 to the right. LED center = cell center.
# Each cell's resistor is right of the anode: inner pad to the anode, outer pad to the slot lane.
for slot, cx in enumerate(COLS):
    for color, cy in enumerate([ROW_RED, ROW_YELLOW, ROW_GREEN]):
        g = slot * 3 + color
        name = COLOR[color]
        anode, cathode = f"LED{g}_A", ("GND" if name != "GREEN" else f"LED{g}_K")
        place(f"D{g + 1}", LED10, f"LED10_{name}", cx - 1.27, cy,
              pads={"1": cathode, "2": anode}, hand=True)
        if g == 3:
            # slot 1 red is inside the module; socket J2 is to the right, so the resistor sits above the anode
            place(f"R{g + 1}", R_0805, R_LED[name], cx + 1.27, cy - 4.2, rot=90, back=True,
                  sides={"south": anode, "north": gp(g)}, lcsc=LCSC[R_LED[name]])
        elif name != "GREEN":
            # GPIO → R → anode, cathode to GND
            place(f"R{g + 1}", R_0805, R_LED[name], cx + 4.2, cy, back=True,
                  sides={"west": anode, "east": gp(g)}, lcsc=LCSC[R_LED[name]])
        else:
            # 5V → 330 → anode; cathode → NPN collector below it; GPIO → 1k → base; emitter to GND (§2.2)
            base = f"Q{slot}_B"
            place(f"R{g + 1}", R_0805, "330", cx + 4.2, cy, back=True,
                  sides={"west": anode, "east": "+5V"}, lcsc=LCSC["330"])
            q = place(f"Q{slot + 1}", SOT23, "S8050", cx - 1.27, cy + 3.5, rot=90, back=True,
                      pads={"1": base, "2": "GND", "3": cathode}, lcsc=LCSC["S8050"])
            _, by = pad(f"Q{slot + 1}", base)
            place(f"R{20 + slot + 1}", R_0805, "1k", cx + 2.5, by, back=True,
                  sides={"west": base, "east": gp(g)}, lcsc=LCSC["1k"])

# Buttons: hot-swap socket underneath, the switch is inserted from outside through the panel.
# GPIO → 220 → node → switch → GND, 100 nF from the node to GND (§2.4). C — under the socket lead,
# R — to the right, outer pad to the slot lane.
for slot, cx in enumerate(COLS):
    node = f"BTN{slot}"
    place(f"SW{slot + 1}", HOTSWAP, "MX_hotswap", cx, ROW_SW, back=True,
          pads={"1": node, "2": "GND"}, lcsc=LCSC["CPG151101S11"])
    place(f"R{30 + slot + 1}", R_0805, "220", cx + 4.2, ROW_BTN_PARTS, back=True,
          sides={"west": node, "east": gp(12 + slot)}, lcsc=LCSC["220"])
    place(f"C{slot + 1}", C_0805, "100n", cx - 4.72, ROW_BTN_PARTS, back=True,
          sides={"east": node, "west": "GND"}, lcsc=LCSC["100n"])

# Power switch on the back wall: GP26 → 220 → node → common/outer lead → GND (§2.5).
# R — right under the node lead, C — next to it, in parallel.
place("SW5", SLIDE, "MSK12C02", POWER_SW_X, POWER_SW_Y, rot=180, back=True,
      pads={"1": "PWR_SW", "2": "GND"}, lcsc=LCSC["MSK12C02"])
sw_x, sw_y = pad("SW5", "PWR_SW")
place("R35", R_0805, "220", sw_x, sw_y + 2.95, rot=90, back=True,
      sides={"north": "PWR_SW", "south": "GP26"}, lcsc=LCSC["220"])
place("C5", C_0805, "100n", sw_x - 2.5, sw_y + 2.95, rot=90, back=True,
      sides={"north": "PWR_SW", "south": "GND"}, lcsc=LCSC["100n"])

# Socketed module, top view USB up — on the back side (flip).
from gen_module_fp import PINS  # noqa: E402

module_nets = {}
for num, (name, _, _) in PINS.items():
    if name == "5V":
        module_nets[str(num)] = "+5V"
    elif name == "GND":
        module_nets[str(num)] = "GND"
    elif name in {gp(i) for i in range(16)} | {"GP26"}:
        module_nets[str(num)] = name
place("U1", MODULE, "RP2040-Zero", MODULE_X, MODULE_Y, back=True, hand=True)

# Module sockets — low-profile 5 mm (decided 2026-10-28: module sits lower, pins trimmed to ~4 mm),
# soldered by the factory (THT). The module's bottom row is in line with the last side pins, so
# 1×8 + 1×8 on the sides and 1×7 at the bottom (including corner GP8 and GP14); the sockets butt together.
# (The factory ran out of 1×9 C39576 on 2026-10-28.)
# Each contact's net comes from the module pin at the same spot (the module is flipped: x mirrored).
pin_at = {(round(MODULE_X - x, 2), round(MODULE_Y + y, 2)): str(num) for num, (_, x, y) in PINS.items()}
for ref, fp_id, value, x, y, rot in [
        ("J1", SOCKET8, "Socket_1x8", MODULE_X - 7.62, MODULE_Y - 10.16, 0),
        ("J2", SOCKET8, "Socket_1x8", MODULE_X + 7.62, MODULE_Y - 10.16, 0),
        ("J3", SOCKET7, "Socket_1x7", MODULE_X - 7.62, MODULE_Y + 10.16, -90)]:
    fp = place(ref, fp_id, value, x, y, rot=rot, back=True, lcsc=LCSC[value] or None)
    # The sockets butt together under the module outline: their frames and the square pin-1 key only get in the way.
    for g in list(fp.GraphicalItems()):
        if g.GetLayer() in (pcbnew.F_SilkS, pcbnew.B_SilkS):
            fp.Remove(g)
    for p in fp.Pads():
        p.SetShape(pcbnew.PADSTACK.ALL_LAYERS, pcbnew.PAD_SHAPE_CIRCLE)
        num = pin_at.get(tuple(round(c, 2) for c in xy(p.GetPosition())))
        if num is None:
            raise SystemExit(f"{ref}: contact {p.GetNumber()} doesn't land on a module pin")
        if num in module_nets:
            p.SetNet(net(module_nets[num]))

# 5 V decoupling — at the 5 V vertical next to the module.
V5_X = COLS[1] + LANE[1]
place("C6", C_0805, "10u", V5_X + 1.92, -41.5, back=True,
      sides={"west": "+5V", "east": "GND"}, lcsc=LCSC["10u"])
place("C7", C_0805, "100n", V5_X + 1.92, -38.0, back=True,
      sides={"west": "+5V", "east": "GND"}, lcsc=LCSC["100n"])

# M3 mounting at the corners — onto the panel bosses of height pcb_gap.
h = BOARD / 2 - HOLE_INSET
for i, (sx, sy) in enumerate([(-1, -1), (1, -1), (1, 1), (-1, 1)]):
    place(f"H{i + 1}", M3, "M3", sx * h, sy * h, hand=True).Reference().SetVisible(False)

# --- tracks -----------------------------------------------------------------------

F, B = pcbnew.F_Cu, pcbnew.B_Cu


def chamfered(pts):
    """Polyline corners are chamfered at 45°: leg CHAMFER, but no more than half of the adjacent segments."""
    out = [pts[0]]
    for prev, cur, nxt in zip(pts, pts[1:], pts[2:]):
        a = min(CHAMFER, math.dist(prev, cur) / 2, math.dist(cur, nxt) / 2)
        d1 = [(c - p) / math.dist(prev, cur) for p, c in zip(prev, cur)]
        d2 = [(n - c) / math.dist(cur, nxt) for c, n in zip(cur, nxt)]
        if abs(d1[0] * d2[1] - d1[1] * d2[0]) < 1e-9:   # straight — no corner
            out.append(cur)
            continue
        out.append((cur[0] - d1[0] * a, cur[1] - d1[1] * a))
        out.append((cur[0] + d2[0] * a, cur[1] + d2[1] * a))
    out.append(pts[-1])
    return out


def track(net_name, layer, *pts):
    for (x1, y1), (x2, y2) in zip(chamfered(pts), chamfered(pts)[1:]):
        if (x1, y1) == (x2, y2):
            continue
        t = pcbnew.PCB_TRACK(board)
        t.SetStart(mm(x1, y1))
        t.SetEnd(mm(x2, y2))
        t.SetWidth(pcbnew.FromMM(TRACK))
        t.SetLayer(layer)
        t.SetNet(net(net_name))
        board.Add(t)


def via(net_name, x, y):
    v = pcbnew.PCB_VIA(board)
    v.SetPosition(mm(x, y))
    v.SetWidth(pcbnew.FromMM(0.6))
    v.SetDrill(pcbnew.FromMM(0.3))
    v.SetNet(net(net_name))
    board.Add(v)


def gnd_via(x, y):
    """GND lead of a back-side SMD → via to the front pour (stitching)."""
    via("GND", x, y)


# Slot lane: which nets run in it, left to right. The order keeps the stubs going left
# (top to bottom: red, yellow, green, button) from crossing the lane's neighboring tracks.
LANES = {
    0: ["GP0", "GP1", "GP2", "GP12"],
    1: ["GP4", "+5V", "GP5", "GP13"],      # slot 1 red (GP3) — short, inside the module
    2: ["GP6", "GP7", "GP8", "GP14"],
    3: ["GP9", "GP10", "GP11", "GP15"],
}
lane_x = {n: COLS[s] + LANE[i] for s, names in LANES.items() for i, n in enumerate(names)}


def slot_of(name):
    return next(s for s, names in LANES.items() if name in names)


def target(name):
    """The resistor pad where the GPIO from the lane arrives."""
    n = int(name[2:])
    if n >= 12:
        return pad(f"R{30 + n - 12 + 1}", name)
    slot, color = divmod(n, 3)
    return pad(f"R{20 + slot + 1}" if color == 2 else f"R{n + 1}", name)


# Bus on the front: rows top to bottom. The further left a net enters the bus, the lower its row —
# then the entry verticals don't cross rows that are already heading right.
BUS = ["GP15", "GP14", "GP13", "GP11", "GP10", "GP9", "GP8", "GP7", "GP6", "GP5", "GP4"]
bus_y = {n: BUS_TOP + STEP * i for i, n in enumerate(BUS)}
# GP4–GP8 leave the module's left row to the left (on the front), go around it and drop into the bus.
DETOUR_X = {f"GP{i}": -23.0 - STEP * (8 - i) for i in range(4, 9)}

for name in BUS:
    px, py = module_pin(name)
    y = bus_y[name]
    lx = lane_x[name]
    if name in DETOUR_X:
        dx = DETOUR_X[name]
        track(name, F, (px, py), (dx, py), (dx, y), (lx, y))
    elif name == "GP15":
        # pin 8 of the right row: pin 9 (GP14) is below it — step slightly right and down past it
        track(name, F, (px, py), (px + 1.34, py), (px + 1.34, y), (lx, y))
    else:
        track(name, F, (px, py), (px, y), (lx, y))
    via(name, lx, y)
    tx, ty = target(name)
    track(name, B, (lx, y), (lx, ty), (tx, ty))

# Slot 0 — the lane left of the module: GP0–GP2 leave the left row straight into it (back side),
# GP12 — from the module's bottom end, under it.
for name in ["GP0", "GP1", "GP2"]:
    px, py = module_pin(name)
    tx, ty = target(name)
    track(name, B, (px, py), (lane_x[name], py), (lane_x[name], ty), (tx, ty))
px, py = module_pin("GP12")
tx, ty = target("GP12")
track("GP12", B, (px, py), (px, py + 1.68), (lane_x["GP12"], py + 1.68), (lane_x["GP12"], ty), (tx, ty))

# Slot 1 red (GP3): the resistor inside the module above the anode — directly on the back side.
px, py = module_pin("GP3")
tx, ty = target("GP3")
track("GP3", B, (px, py), (tx, py), (tx, ty))

# GP26 → R35 at the power switch: on the front right and up, via to the resistor.
px, py = module_pin("GP26")
tx, ty = pad("R35", "GP26")
track("GP26", F, (px, py), (COLS[2] - 3.76, py), (COLS[2] - 3.76, ty + 2.6), (tx, ty + 2.6))
via("GP26", tx, ty + 2.6)
track("GP26", B, (tx, ty + 2.6), (tx, ty))

# 5 V: from module pin 1 as a vertical in the slot 1 lane down to the horizontal above the green row,
# from there via vias to each cell's 330 Ω.
px, py = module_pin("+5V")
track("+5V", B, (px, py), (V5_X, py), (V5_X, RAIL_5V))
via("+5V", V5_X, RAIL_5V)
for ref in ["C6", "C7"]:
    cx_, cy_ = pad(ref, "+5V")
    track("+5V", B, (V5_X, cy_), (cx_, cy_))
    gx, gy = pad(ref, "GND")
    gnd_via(gx + 1.2, gy)
    track("GND", B, (gx, gy), (gx + 1.2, gy))
feeds = [pad(f"R{slot * 3 + 3}", "+5V") for slot in range(4)]
track("+5V", F, (feeds[0][0], RAIL_5V), (feeds[-1][0], RAIL_5V))
for fx, fy in feeds:
    via("+5V", fx, RAIL_5V)
    track("+5V", B, (fx, RAIL_5V), (fx, fy))

# Cells: short connections inside.
for slot, cx in enumerate(COLS):
    for color, cy in enumerate([ROW_RED, ROW_YELLOW, ROW_GREEN]):
        g = slot * 3 + color
        anode = f"LED{g}_A"
        track(anode, B, pad(f"D{g + 1}", anode), pad(f"R{g + 1}", anode))
        if color == 2:
            cathode, base, q = f"LED{g}_K", f"Q{slot}_B", f"Q{slot + 1}"
            track(cathode, B, pad(f"D{g + 1}", cathode), pad(q, cathode))
            track(base, B, pad(q, base), pad(f"R{20 + slot + 1}", base))
            ex, ey = pad(q, "GND")
            gnd_via(ex, ey + 1.5)
            track("GND", B, (ex, ey), (ex, ey + 1.5))
    # button: socket lead → C → R
    node = f"BTN{slot}"
    hx, hy = next(xy(p.GetPosition()) for p in fps[f"SW{slot + 1}"].Pads()
                  if p.GetNetname() == node and p.GetAttribute() == pcbnew.PAD_ATTRIB_PTH)
    nx, ny = pad(f"C{slot + 1}", node)
    track(node, B, (hx, hy), (nx, ny), pad(f"R{30 + slot + 1}", node))
    gx, gy = pad(f"C{slot + 1}", "GND")
    gnd_via(gx, gy + 1.5)
    track("GND", B, (gx, gy), (gx, gy + 1.5))

# Power switch: node lead → R35 and C5; GND lead and C5 → vias.
track("PWR_SW", B, (sw_x, sw_y), pad("R35", "PWR_SW"), pad("C5", "PWR_SW"))
gx, gy = pad("SW5", "GND")
gnd_via(gx, gy + 1.6)
track("GND", B, (gx, gy), (gx, gy + 1.6))
gx, gy = pad("C5", "GND")
gnd_via(gx - 1.2, gy)
track("GND", B, (gx, gy), (gx - 1.2, gy))

# --- outline, pour, rules -------------------------------------------------------

half = BOARD / 2
corners = [(-half, -half), (half, -half), (half, half), (-half, half)]
for (x1, y1), (x2, y2) in zip(corners, corners[1:] + corners[:1]):
    seg = pcbnew.PCB_SHAPE(board)
    seg.SetShape(pcbnew.SHAPE_T_SEGMENT)
    seg.SetStart(mm(x1, y1))
    seg.SetEnd(mm(x2, y2))
    seg.SetLayer(pcbnew.Edge_Cuts)
    seg.SetWidth(pcbnew.FromMM(0.1))
    board.Add(seg)

# GND — as a pour on both sides.
for layer in (F, B):
    z = pcbnew.ZONE(board)
    z.SetLayer(layer)
    z.SetNet(net("GND"))
    z.AddPolygon(pcbnew.VECTOR_VECTOR2I([mm(x, y) for x, y in corners]))
    z.SetLocalClearance(pcbnew.FromMM(0.2))
    z.SetMinThickness(pcbnew.FromMM(0.15))
    # Don't drop narrow slivers between tracks fenced in by vias — otherwise they become voids.
    z.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_NEVER)
    z.SetPadConnection(pcbnew.ZONE_CONNECTION_THERMAL)
    board.Add(z)

# JLCPCB minimums with margin: track/clearance 0.2, via 0.6/0.3, copper to edge 0.5
# (KiCad default; board rules aren't saved without .kicad_pro, DRC uses the same one).
ds = board.GetDesignSettings()
ds.SetCopperLayerCount(2)
nc = ds.m_NetSettings.GetDefaultNetclass()
nc.SetTrackWidth(pcbnew.FromMM(TRACK))
nc.SetClearance(pcbnew.FromMM(0.2))
nc.SetViaDiameter(pcbnew.FromMM(0.6))
nc.SetViaDrill(pcbnew.FromMM(0.3))
ds.m_CopperEdgeClearance = pcbnew.FromMM(0.5)


def label(text, x, y, back=True, size=1.2, left=False):
    """left — align left (as it reads on its own side), x — start of the line."""
    t = pcbnew.PCB_TEXT(board)
    t.SetText(text)
    if left:
        t.SetHorizJustify(pcbnew.GR_TEXT_H_ALIGN_LEFT)
    t.SetPosition(mm(x, y))
    t.SetTextSize(pcbnew.VECTOR2I(pcbnew.FromMM(size), pcbnew.FromMM(size)))
    t.SetTextThickness(pcbnew.FromMM(size * 0.15))
    t.SetLayer(pcbnew.B_SilkS if back else pcbnew.F_SilkS)
    if back:
        t.SetMirrored(True)
    board.Add(t)
    return t


# LEDs are hand-soldered from the back side — the row and polarity labels are there too.
for name, cy in [("R", ROW_RED), ("Y", ROW_YELLOW), ("G", ROW_GREEN)]:
    label(name, -half + 2.5, cy, size=1.5)
# Polarity at each LED: "+" above the anode (pad 2), "−" above the cathode.
# Slot 1 red has resistor R4 above it — there the labels go under the pads.
for g in range(12):
    for num, sign in [("1", "-"), ("2", "+")]:
        px, py = xy(next(p for p in fps[f"D{g + 1}"].Pads() if p.GetNumber() == num).GetPosition())
        label(sign, px, py + (2.1 if g == 3 else -2.1), size=1.4)
for slot, cx in enumerate(COLS):
    label(str(slot + 1), cx, ROW_SW - 11.0, back=False)

# --- app icon on the back side -------------------------------------------------------
# Icon outline from host/scripts/make-icon.swift (its coordinates too: 1024 × 1024, Y up):
# a head, left half robot (antenna, ear, eye, grille mouth), right half three traffic lights.
# The badge is ~7.5 mm in the bottom left corner (looking at the back side) — between the mounting
# hole, button 4's socket and the board edge; the labels are to its right.
ICON_S = 0.012                      # mm per icon unit: 634 units of height → 7.6 mm
ICON_C = (489, 553)                 # center of the drawing including ear and antenna
ICON_AT = (34.0, half - 6.3)        # where it is on the board; ear toward hole H3, antenna under R34
ICON_W = 0.3                        # line width


def icon_pt(x, y):
    """Icon point → board. We look at the back side, so x is mirrored."""
    return ICON_AT[0] - (x - ICON_C[0]) * ICON_S, ICON_AT[1] - (y - ICON_C[1]) * ICON_S


def silk(shape, **kw):
    s = pcbnew.PCB_SHAPE(board)
    s.SetShape(shape)
    s.SetLayer(pcbnew.B_SilkS)
    s.SetWidth(pcbnew.FromMM(ICON_W))
    for k, v in kw.items():
        getattr(s, k)(*v)
    board.Add(s)


def icon_line(x1, y1, x2, y2):
    silk(pcbnew.SHAPE_T_SEGMENT, SetStart=(mm(*icon_pt(x1, y1)),), SetEnd=(mm(*icon_pt(x2, y2)),))


def icon_arc(cx, cy, r, a1, a2):
    """Counterclockwise arc from a1 to a2 (radians, as in CoreGraphics)."""
    am = (a1 + a2) / 2
    p = [mm(*icon_pt(cx + r * math.cos(a), cy + r * math.sin(a))) for a in (a1, am, a2)]
    silk(pcbnew.SHAPE_T_ARC, SetArcGeometry=p)


def icon_circle(cx, cy, r, filled=False):
    silk(pcbnew.SHAPE_T_CIRCLE, SetCenter=(mm(*icon_pt(cx, cy)),), SetEnd=(mm(*icon_pt(cx + r, cy)),),
         SetFilled=(filled,))


def icon_rrect(x, y, w, h, r):
    icon_line(x + r, y, x + w - r, y)
    icon_line(x + w, y + r, x + w, y + h - r)
    icon_line(x + w - r, y + h, x + r, y + h)
    icon_line(x, y + h - r, x, y + r)
    pi = math.pi
    for cx, cy, a in [(x + w - r, y + r, -pi / 2), (x + w - r, y + h - r, 0),
                      (x + r, y + h - r, pi / 2), (x + r, y + r, pi)]:
        icon_arc(cx, cy, r, a, a + pi / 2)


# Head 560 × 520, seam in the middle
hx, hy, hw, hh = 232, 236, 560, 520
mid = hx + hw / 2
icon_rrect(hx, hy, hw, hh, 130)
icon_line(mid, hy, mid, hy + hh)
# Antenna with a ball
icon_line(372, hy + hh, 372, hy + hh + 62)
icon_circle(372, hy + hh + 88, 26)
# Bolt ear on the left — only the part sticking out of the head
ey1, ey2, er = hy + hh / 2 - 70, hy + hh / 2 + 70, 26
icon_line(hx, ey2, hx - 46 + er, ey2)
icon_arc(hx - 46 + er, ey2 - er, er, math.pi / 2, math.pi)
icon_line(hx - 46, ey2 - er, hx - 46, ey1 + er)
icon_arc(hx - 46 + er, ey1 + er, er, math.pi, 3 * math.pi / 2)
icon_line(hx - 46 + er, ey1, hx, ey1)
# Eye
# (at 9 mm double rings merge — a pupil instead of the inner ring)
icon_circle(382, 560, 72)
icon_circle(382, 560, 30, filled=True)
# Grille mouth
mw = mid - 292 - 34
icon_rrect(292, 330, mw, 74, 22)
for i in (1, 2, 3):
    icon_line(292 + mw * i / 4, 330, 292 + mw * i / 4, 404)
# Three lights with visors
lx = mid + (hx + hw - mid) / 2 - 6
for ly in (hy + hh - 106, hy + hh / 2, hy + 106):
    icon_circle(lx, ly, 52)
    icon_arc(lx, ly, 82, math.pi * 0.12, math.pi * 0.88)

# Right of the badge — name with the board revision (not firmware version) and repo, then license and author.
# All at mid-head height: above are the vias under the button resistors (~35.7), below is the board edge.
# No font smaller than 1.0 mm — the JLCPCB minimum (line width 0.15 mm).
GAP = 1.5
_, head_y = icon_pt(792, hy + hh / 2)
text_x = icon_pt(792, 0)[0] - GAP
lines = [label("agentlight rev. a", text_x, head_y - 1.15, size=1.6, left=True),
         label("github.com/grisha-gu/agentlight", text_x, head_y + 1.35, size=1.0, left=True)]
# end of the long line (mirrored — the left edge of the frame)
text_x = min(pcbnew.ToMM(t.GetBoundingBox().GetX()) for t in lines) - ORIGIN[0] - 3.0
label("CERN-OHL-P-2.0", text_x, head_y - 0.9, size=1.0, left=True)
label("by Gregory Gulyaev", text_x, head_y + 0.9, size=1.0, left=True)

board.BuildConnectivity()
pcbnew.ZONE_FILLER(board).Fill(board.Zones())
board.Save(OUT)

# Library table next to the board — so KiCad finds agentlight.pretty when opening it.
open(os.path.join(HERE, "fp-lib-table"), "w").write(
    '(fp_lib_table\n  (version 7)\n'
    '  (lib (name "agentlight")(type "KiCad")(uri "${KIPRJMOD}/agentlight.pretty")(options "")(descr "agentlight"))\n)\n')
print(OUT, "—", len(board.GetFootprints()), "parts,", len(nets), "nets,", len(board.GetTracks()), "tracks/vias")
