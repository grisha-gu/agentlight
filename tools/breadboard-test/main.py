# M1 breadboard check on MicroPython (RP2040-Zero).
#
# Wiring: GP0/GP1/GP2 -> resistor -> LED anode (red/yellow/green),
#        cathodes to GND; button GP14 <-> GND.
#
# Modes (switched by the button):
#   0 cycle  — each color in turn fades in and out smoothly
#   1 steady — all three lit steadily (compare brightness, swap LEDs in a slot)
#   2 off    — everything off
# The onboard RGB (GP16) blinks blue — a sign the script is alive.

import time
from machine import Pin, PWM
import neopixel

LEDS = [("red", 0), ("yellow", 1), ("green", 2)]
BTN_PIN = 14
MODES = ("cycle", "steady", "off")

pwms = []
for name, gp in LEDS:
    p = PWM(Pin(gp))
    p.freq(1000)
    p.duty_u16(0)
    pwms.append(p)

btn = Pin(BTN_PIN, Pin.IN, Pin.PULL_UP)
np = neopixel.NeoPixel(Pin(16), 1)


def set_all(duty):
    for p in pwms:
        p.duty_u16(duty)


def gamma(x):
    # x in 0..1 -> duty_u16; squared so the fade looks smooth to the eye
    return int(65535 * x * x)


mode = 0
btn_prev = 1
btn_changed_at = 0
t0 = time.ticks_ms()
print("breadboard-test: ready, mode =", MODES[mode])

while True:
    now = time.ticks_ms()
    t = time.ticks_diff(now, t0)

    # button: 30 ms debounce, fires on press
    b = btn.value()
    if b != btn_prev and time.ticks_diff(now, btn_changed_at) > 30:
        btn_changed_at = now
        btn_prev = b
        if b == 0:
            mode = (mode + 1) % len(MODES)
            print("BTN press -> mode", MODES[mode])
            set_all(0)
        else:
            print("BTN release")

    if mode == 0:
        # 2 s per color: 1 s up, 1 s down
        phase = t % 6000
        idx = phase // 2000
        local = (phase % 2000) / 1000
        level = local if local <= 1 else 2 - local
        for i, p in enumerate(pwms):
            p.duty_u16(gamma(level) if i == idx else 0)
    elif mode == 1:
        set_all(65535)

    np[0] = (0, 0, 20) if (t // 500) % 2 else (0, 0, 0)
    np.write()
    time.sleep_ms(10)
