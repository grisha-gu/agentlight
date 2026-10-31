#include "buttons.h"

#include "config.h"
#include "hardware/gpio.h"
#include "pico/time.h"

static bool     stable_down[SLOTS];
static bool     raw_down[SLOTS];
static uint32_t raw_since_ms[SLOTS];

void buttons_init(void) {
    for (uint s = 0; s < SLOTS; s++) {
        uint pin = BTN_PIN_BASE + s;
        gpio_init(pin);
        gpio_set_dir(pin, GPIO_IN);
        gpio_pull_up(pin);
    }
}

bool buttons_poll(uint8_t *slot) {
    uint32_t now = to_ms_since_boot(get_absolute_time());

    for (uint s = 0; s < SLOTS; s++) {
        bool down = !gpio_get(BTN_PIN_BASE + s);
        if (down != raw_down[s]) {
            raw_down[s] = down;
            raw_since_ms[s] = now;
        }
        // Уровень принимается, только если продержался BTN_DEBOUNCE_MS без дребезга.
        if (raw_down[s] != stable_down[s] && now - raw_since_ms[s] >= BTN_DEBOUNCE_MS) {
            stable_down[s] = raw_down[s];
            if (stable_down[s]) {
                *slot = (uint8_t)s;
                return true;
            }
        }
    }
    return false;
}
