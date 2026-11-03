#pragma once

#define FW_VERSION_MAJOR 0
#define FW_VERSION_MINOR 6
#define FW_VERSION_PATCH 0
#define PROTO_VERSION    1

#define SLOTS            4

// On-module WS2812 — "firmware alive / host connected" indicator.
#define STATUS_LED_PIN   16

// Main loop: fixed 120 Hz tick.
#define TICK_US          8333

// Max CDC input line length, including the command and arguments.
#define CMD_LINE_MAX     96

// Slot buttons: GP12..GP15, to GND.
#define BTN_PIN_BASE     12
#define BTN_DEBOUNCE_MS  20

// Power switch on the back wall: GP26, tied to GND = "off" (docs/02-hardware.md §2.5).
#define POWER_PIN        26
#define POWER_DEBOUNCE_MS 30
// Lights fade out and back in over the same time as a state crossfade.
#define POWER_FADE_MS    220

// Brightness of RED, YELLOW, GREEN. Tuned by eye on the breadboard on 2026-10-23, no diffuser:
// red 220 Ω, yellow 270 Ω (temporary), green 525 nm 330 Ω from 5 V — level 0x90 ≈ 0.28.
// Final tuning happens inside the case (docs/04-firmware.md §4.4).
#define LED_CAL_INIT     { 1.00f, 1.00f, 0.28f }

// SELFTEST: the "one LED at a time" step. The spec says 80 ms; longer while wiring up
// the hardware, so there's time to see which one is lit.
#define SELFTEST_STEP_MS 400

// No PING from the host for longer than this — everything goes dark, !WD trip (docs/03-protocol.md §3.5).
#define WD_TIMEOUT_MS    3000
