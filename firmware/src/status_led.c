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
    // A regular WS2812 expects GRB, but the user's RP2040-Zero has the RGB-order variant
    // (checked 2026-10-23: "green" in GRB lit up red). MSB first, 24 bits in the top of the word.
    uint32_t rgb = ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
    pio_sm_put_blocking(pio, sm, rgb << 8u);
}
