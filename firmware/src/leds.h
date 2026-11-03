#pragma once
#include <stdint.h>

// 12 LEDs on GP0–GP11, index = GPIO number = slot * 3 + color.
// The protocol knows nothing about the LED type: moving to addressable LEDs only changes leds.c.

#define LED_COUNT 12

void leds_init(void);
void led_set(uint8_t index, float level);     // index 0..11, level 0..1 (linear, before gamma)
void leds_clear(void);
void leds_set_master(float level);             // global multiplier 0..1 on top of all levels (power switch)
void leds_render(void);                        // level → gamma → calibration → PWM
