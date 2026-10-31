"""RP2040-Zero: пины (PINS) и контур модуля для платы.

Пины — 2 × 9 по бокам + 5 на нижнем торце (GP9–GP13); на плате это три гнезда J1–J3, их паяет
завод. Футпринт RP2040-Zero_Outline — только контур и метка USB, чтобы модуль было видно.
Вид на модуль сверху, USB-C вверху; на плате ставится на обратную сторону (flip).
Координаты сверены с dj505/RP2040-Zero-KiCAD и CountParadox/RP2040-Zero-Kicad:
ряды через 15.24 мм, шаг 2.54, нижний ряд на одной линии с последними боковыми пинами.
Номера пинов 1–23 и их GPIO — PINS ниже, порядок как у символа dj505.
"""
import os

# номер → имя, (x, y) от центра модуля; центр = середина между рядами на уровне 5-го пина
PINS = {}
for i, name in enumerate(["5V", "GND", "3V3", "GP29", "GP28", "GP27", "GP26", "GP15", "GP14"]):
    PINS[i + 1] = (name, -7.62, -10.16 + 2.54 * i)
for i in range(9):
    PINS[10 + i] = (f"GP{i}", 7.62, -10.16 + 2.54 * i)
for i, name in enumerate(["GP13", "GP12", "GP11", "GP10", "GP9"]):
    PINS[19 + i] = (name, -5.08 + 2.54 * i, 10.16)


def line(x1, y1, x2, y2, layer, w):
    return f'\t(fp_line (start {x1} {y1}) (end {x2} {y2}) (stroke (width {w}) (type solid)) (layer "{layer}"))\n'


def rect(x1, y1, x2, y2, layer, w):
    return "".join(line(*p, layer, w) for p in [(x1, y1, x2, y1), (x2, y1, x2, y2), (x2, y2, x1, y2), (x1, y2, x1, y1)])


def text(kind, val, y, layer):
    return (f'\t(fp_text {kind} "{val}" (at 0 {y}) (layer "{layer}")\n'
            f'\t\t(effects (font (size 1 1) (thickness 0.15))))\n')


out = ['(footprint "RP2040-Zero_Outline"\n\t(version 20240108)\n\t(generator "agentlight")\n\t(layer "F.Cu")\n'
       '\t(descr "Waveshare RP2040-Zero outline only (pins are the J1-J3 sockets on the board). Top view, USB up; place flipped on B.Cu")\n'
       '\t(attr exclude_from_pos_files exclude_from_bom allow_missing_courtyard)\n']
out.append(text("reference", "REF**", -15.2, "F.SilkS"))
out.append(text("value", "RP2040-Zero", 0, "F.Fab"))
# модуль 18.16 × 23.88, USB-C выступает на 1.78 за верхний край
out.append(rect(-9.08, -11.94, 9.08, 11.94, "F.Fab", 0.1))
out.append(rect(-4.5, -13.72, 4.5, -8.4, "F.Fab", 0.1))
out.append(line(-2, -13.2, 2, -13.2, "F.SilkS", 0.12))   # метка «здесь USB»

if __name__ == "__main__":
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "agentlight.pretty", "RP2040-Zero_Outline.kicad_mod")
    open(path, "w").write("".join(out) + ")\n")
    print(path)
