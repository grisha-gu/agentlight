#include "status_led.h"

#include "config.h"
#include "hardware/pio.h"
#include "ws2812.pio.h"

static PIO  pio = pio0;
static uint sm;

void status_led_init(void) {
    uint offset = pio_add_program(pio, &ws2812_program);
    sm = pio_claim_unused_sm(pio, true);
    ws2812_program_init(pio, sm, offset, STATUS_LED_PIN, 800000.0f);
    status_led_set(0, 0, 0);
}

void status_led_set(uint8_t r, uint8_t g, uint8_t b) {
    // Обычный WS2812 ждёт GRB, но на RP2040-Zero пользователя стоит вариант с порядком RGB
    // (проверено 2026-10-23: «зелёный» по GRB горел красным). Старшим битом вперёд, 24 бита в верхней части слова.
    uint32_t rgb = ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
    pio_sm_put_blocking(pio, sm, rgb << 8u);
}
