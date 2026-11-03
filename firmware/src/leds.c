#include "leds.h"

#include <math.h>
#include <string.h>

#include "config.h"
#include "hardware/gpio.h"
#include "hardware/pwm.h"

// 14 bits: 125 MHz / 16384 ≈ 7.6 kHz — no flicker, even on camera. 12 bits (30.5 kHz)
// gave visible steps at the very bottom of a fade: 1 → 2 counts out of 4095 doubles the brightness.
#define PWM_WRAP  16383
#define GAMMA     2.2f

static const float LED_CAL[3] = LED_CAL_INIT;

// Levels stay float all the way to PWM: gamma and LED_CAL without intermediate rounding to 8 bits.
static float fb[LED_COUNT];
static float master = 1.0f;

void leds_init(void) {
    for (uint pin = 0; pin < LED_COUNT; pin++) {
        gpio_set_function(pin, GPIO_FUNC_PWM);
        gpio_set_drive_strength(pin, GPIO_DRIVE_STRENGTH_8MA);
        uint slice = pwm_gpio_to_slice_num(pin);
        pwm_set_wrap(slice, PWM_WRAP);
        pwm_set_clkdiv(slice, 1.0f);
        pwm_set_gpio_level(pin, 0);
        pwm_set_enabled(slice, true);
    }
}

void led_set(uint8_t index, float level) {
    if (index < LED_COUNT)
        fb[index] = level < 0 ? 0 : level > 1 ? 1 : level;
}

void leds_clear(void) {
    memset(fb, 0, sizeof fb);
}

void leds_set_master(float level) {
    master = level < 0 ? 0 : level > 1 ? 1 : level;
}

void leds_render(void) {
    for (uint i = 0; i < LED_COUNT; i++) {
        float lv = fb[i] * master;
        uint16_t v = lv > 0 ? (uint16_t)lroundf(powf(lv, GAMMA) * LED_CAL[i % 3] * PWM_WRAP) : 0;
        pwm_set_gpio_level(i, v);
    }
}
