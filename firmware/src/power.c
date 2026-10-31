#include "power.h"

#include "config.h"
#include "hardware/gpio.h"
#include "pico/time.h"

static bool     stable_on = true;
static bool     raw_on = true;
static uint32_t raw_since_ms;

void power_init(void) {
    gpio_init(POWER_PIN);
    gpio_set_dir(POWER_PIN, GPIO_IN);
    gpio_pull_up(POWER_PIN);
    // 100 нФ заряжается через внутренний pull-up ~50 кОм: τ ≈ 5 мс. Дать уровню установиться,
    // чтобы первый READY сообщил правильное положение без дебаунса.
    sleep_ms(20);
    stable_on = raw_on = gpio_get(POWER_PIN);
}

bool power_is_on(void) {
    return stable_on;
}

bool power_poll(bool *on) {
    uint32_t now = to_ms_since_boot(get_absolute_time());
    bool level = gpio_get(POWER_PIN);
    if (level != raw_on) {
        raw_on = level;
        raw_since_ms = now;
    }
    if (raw_on == stable_on || now - raw_since_ms < POWER_DEBOUNCE_MS)
        return false;
    stable_on = raw_on;
    *on = stable_on;
    return true;
}
