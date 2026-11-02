# 04. Firmware (RP2040)

## 4.1. Stack

**Pico SDK (C) + TinyUSB.** Direct access to the 14-bit PWM and the fixed slice
mapping, composite HID + CDC out of the box, well documented, debuggable with
`picotool` / SWD.

## 4.2. Layout

```
firmware/
├── CMakeLists.txt
├── pico_sdk_import.cmake       # from the Raspberry Pi Pico SDK (BSD-3-Clause)
└── src/
    ├── main.c                  # init, main loop, CDC line transport, heartbeat watchdog
    ├── config.h                # version, pins, timings, colour calibration
    ├── leds.c/.h               # 12 PWM channels, gamma, calibration, master fade
    ├── anim.c/.h               # per-slot state machine, crossfades, welcome, pulse, selftest
    ├── buttons.c/.h            # debounce, press events
    ├── power.c/.h              # rear power switch (GP26), debounce
    ├── proto.c/.h              # shared command parser and event formatting
    ├── transport_hid.c/.h      # vendor HID IN/OUT reports
    ├── status_led.c/.h         # on-board RGB LED (heartbeat indicator)
    ├── ws2812.pio              # PIO program for the on-board RGB LED
    ├── usb_descriptors.c       # composite: vendor HID + CDC
    └── tusb_config.h
```

## 4.3. Main loop

A fixed 120 Hz tick (8.33 ms). Nothing blocks; no `sleep_ms` in the logic.
Simplified:

```c
int main(void) {
    leds_init();                   // GP0..GP11, 14-bit PWM
    buttons_init();
    power_init();
    tusb_init();
    anim_init();

    anim_power_on_wave();          // a welcome wave across the 4 slots at power-up
    proto_emit_ready();            // !READY / 0x81

    absolute_time_t next = get_absolute_time();
    while (true) {
        tud_task();                // USB
        poll_cdc_lines();
        transport_hid_poll();      // both feed the same command queue

        cmd_t cmd;
        while (proto_pop(&cmd))
            anim_apply(&cmd);      // idempotent

        if (host_heartbeat_expired()) {
            anim_force_all_off();
            proto_emit_wd_trip();  // once per trip
        }

        btn_event_t ev;
        while (buttons_poll(&ev))
            proto_emit_button(ev.slot, ev.gesture, ev.t_ms);

        next = delayed_by_us(next, TICK_US);
        anim_tick();               // compute the frame
        leds_render();             // gamma + calibration → pwm_set_gpio_level
        sleep_until(next);         // a late frame is skipped, not caught up
    }
}
```

Once a second the loop logs `!LOG tick late=… work=… us` if a frame was more than
1 ms late or took more than 2 ms.

## 4.4. LED rendering

The output method is hidden behind a small interface:

```c
void leds_init(void);
void led_set(uint8_t index, float level);     // index 0..11, level 0..1 (linear, pre-gamma)
void leds_render(void);                        // level → gamma → calibration → PWM
```

### PWM setup

`slice = (gpio / 2) % 8`, channel `A` for even GPIOs, `B` for odd. `GP0–GP11` give
12 independent channels on slices 0–5.

```c
#define LED_COUNT   12
#define PWM_WRAP    16383           // 14 bits

void leds_init(void) {
    for (uint pin = 0; pin < LED_COUNT; pin++) {
        gpio_set_function(pin, GPIO_FUNC_PWM);
        gpio_set_drive_strength(pin, GPIO_DRIVE_STRENGTH_8MA);
        uint slice = pwm_gpio_to_slice_num(pin);
        pwm_set_wrap(slice, PWM_WRAP);          // 125 MHz / 16384 ≈ 7.6 kHz
        pwm_set_clkdiv(slice, 1.0f);
        pwm_set_enabled(slice, true);
    }
}
```

7.6 kHz is far above visible flicker, including on video and in peripheral vision.
Going below ~1 kHz would show banding on phone cameras. 12 bits (30.5 kHz) still
showed faint steps at the very bottom of a fade (1 → 2 counts out of 4095 doubles the
brightness); 14 bits make the step 4× finer.

### Gamma: float all the way to the PWM

Levels from the animations (already multiplied by `BRIGHT`) are kept as floats 0..1
and converted to PWM in one step, with no intermediate 8-bit rounding:

```c
v = lroundf(powf(level, 2.2f) * LED_CAL[color] * PWM_WRAP);
```

8 bits remain only at the protocol input (`RAW`, `BRIGHT`). That makes `RAW` a
debugging tool rather than a smooth one: going from level 5 to 4 is −40 %.

### Colour calibration

Red, yellow and green at the same current look differently bright (the eye is most
sensitive around 555 nm). Per-colour coefficients balance them:

```c
// RED, YELLOW, GREEN — tune by eye behind the enclosure's diffuser
#define LED_CAL_INIT { 1.00f, 1.00f, 0.28f }
```

Calibrate in the assembled enclosure: the black plastic and the 10 mm light well
change the perception more than the LEDs themselves.

## 4.5. Animations

Each slot is an independent mini state machine with a timeline.

| Animation | Parameters |
|---|---|
| **crossfade** | 220 ms, `ease-in-out-cubic`, between any two states |
| **welcome** | 1200 ms: R fade-in 0→150, R→Y 150→300, Y→G 300→450, G hold 450→650, all three bright 650→750, fade 750→950, crossfade into the target state 950→1200 |
| **power-on wave** | welcome with a 120 ms offset per slot, then everything off |
| **attn** | steady red, no blinking |
| **busy pulse** | yellow breathes 1.0 ↔ 0.65 with a 2.2 s period, so a working agent visibly differs from a frozen one. The pulse depth ramps in over 220 ms after a state change, and a crossfade starts from the actually lit level (pulse included), so rapid busy ↔ idle switching does not flicker |
| **idle pulse** | off by default: steady green, not distracting |
| **selftest** | each LED in turn (400 ms per step), then all R, all Y, all G, then off |

All transitions are computed in float and only converted to 14-bit PWM through gamma
at the output, so fading from 20 % to zero has no steps.

Rule: **an animation never blocks command handling.** If `SET_STATE` arrives during a
welcome, the welcome finishes but the target is already updated, and the final
crossfade goes to the new state.

## 4.6. Buttons: debounce

Buttons are polled on every tick (8.33 ms). A level is accepted once it has been
stable for `BTN_DEBOUNCE_MS` (20 ms); the transition to "pressed" immediately emits
`BTN_PRESS` on both transports.

There are no gestures (long or double press): recognising a double press would delay
every single press by ~350 ms, and an instant reaction matters more.

## 4.7. USB descriptors

```c
// usb_descriptors.c — composite
enum { ITF_NUM_HID, ITF_NUM_CDC, ITF_NUM_CDC_DATA, ITF_NUM_TOTAL };

static const uint8_t desc_hid_report[] = {
    0x06, 0x00, 0xFF,        // Usage Page (Vendor 0xFF00)
    0x09, 0x01,              // Usage (0x01)
    0xA1, 0x01,              //   Collection (Application)
    0x09, 0x02, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08,
    0x95, 0x40, 0x81, 0x02,  //     Input  (64 bytes)
    0x09, 0x03, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08,
    0x95, 0x40, 0x91, 0x02,  //     Output (64 bytes)
    0xC0
};
```

The serial string comes from the RP2040 flash unique ID. VID/PID: see
[03-protocol.md §3.1](03-protocol.md#identification).

## 4.8. Building and flashing

```bash
# once
brew install cmake ninja picotool
git clone --depth 1 --branch 2.1.1 https://github.com/raspberrypi/pico-sdk ~/pico-sdk
cd ~/pico-sdk && git submodule update --init --depth 1   # needed for lib/tinyusb

# compiler: use the official Arm archive, NOT the `arm-none-eabi-gcc` Homebrew formula —
# the formula ships without newlib, and the build fails with
# "cannot read spec file nosys.specs". The archive needs no sudo
# (the `gcc-arm-embedded` cask is the same toolchain as a .pkg).
# Pick the archive for your CPU (darwin-arm64 or darwin-x86_64).
mkdir -p ~/tools && cd ~/tools
curl -fLO https://developer.arm.com/-/media/Files/downloads/gnu/14.2.rel1/binrel/arm-gnu-toolchain-14.2.rel1-darwin-x86_64-arm-none-eabi.tar.xz
tar xf arm-gnu-toolchain-*.tar.xz && rm arm-gnu-toolchain-*.tar.xz

# build (the board is set in CMakeLists.txt)
cd firmware && cmake -B build -G Ninja -DPICO_SDK_PATH=~/pico-sdk \
    -DPICO_TOOLCHAIN_PATH=~/tools/arm-gnu-toolchain-14.2.rel1-darwin-x86_64-arm-none-eabi
cmake --build build

# flash: hold BOOT, plug in USB → the RPI-RP2 drive mounts
cp build/agentlight.uf2 /Volumes/RPI-RP2/
```

Once AgentLight firmware is on the board, `tools/flash.sh` rebuilds and flashes
without the BOOT button: opening the CDC port at 1200 baud reboots the RP2040 into
BOOTSEL.

## 4.9. Test checklist

Run `python3 tools/proto_test.py --manual --stop-daemon`: automatic checks over CDC
plus manual y/n questions (`--list` shows all checks and their last results, `--only`
runs a subset, `--pending` only the manual checks not yet passed). HID is exercised by
the daemon, not by this script.

* [ ] `HELLO` reports the right version and uid
* [ ] every command; invalid arguments → `ERR`
* [ ] all 12 LEDs light one by one via `RAW` in the right order (slot 0 = leftmost)
* [ ] the three colours look equally bright behind the diffuser (`LED_CAL` tuned)
* [ ] busy pulse (at `BRIGHT` 255 and 30) and crossfades show no visible steps or jerks
* [ ] filmed with a phone: no banding or flicker
* [ ] `SET 0 busy` ↔ `SET 0 idle` at 200 switches/s: every reply arrives, no `!WD`, no visible flashes
* [ ] welcome survives a new state arriving mid-animation
* [ ] repeating `SET` with the same state does not restart the animation
* [ ] heartbeat stops → after 3 s everything goes dark and `!WD trip` is sent exactly once
* [ ] USB reconnect → `!READY`, lights stay off until the host sends state
* [ ] all 4 buttons send `!BTN n press`; no false triggers when tapping the desk
* [ ] all 12 LEDs at full (`RAW ff` × 12): current < 120 mA
* [ ] the module stays at most warm
* [ ] power switch: `!POWER off` once, LEDs and the on-board RGB fade out in 220 ms,
  buttons are silent, `HELLO` says `power=off`; switching on → `!POWER on`, LEDs fade
  in with the state sent while off
