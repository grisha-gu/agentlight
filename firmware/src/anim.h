#pragma once
#include <stdbool.h>
#include <stdint.h>

// Slot states and the animations on top of them (docs/04-firmware.md §4.5).
// Everything is computed as fractions 0..1, then multiplied by brightness and sent to led_set().

typedef enum {
    ST_OFF  = 0,
    ST_IDLE = 1,   // green
    ST_BUSY = 2,   // yellow
    ST_ATTN = 3,   // red
} slot_state_t;

void anim_init(void);
void anim_set_state(uint8_t slot, slot_state_t st, uint32_t now);   // same state — no-op
void anim_force_off(void);                                           // instantly, no crossfade (watchdog)
void anim_welcome(int slot, uint32_t now);                           // slot < 0 — wave across all slots
void anim_set_brightness(uint8_t b);
void anim_set_config(bool busy_pulse, bool idle_pulse);
void anim_tick(uint32_t now);                                        // once per tick: frame → led_set()

bool anim_parse_state(const char *name, slot_state_t *st);
