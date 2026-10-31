#pragma once
#include <stdbool.h>
#include <stdint.h>

// Состояния слотов и анимации поверх них (docs/04-firmware.md §4.5).
// Всё считается в долях 0..1, на выходе умножается на яркость и уходит в led_set().

typedef enum {
    ST_OFF  = 0,
    ST_IDLE = 1,   // зелёный
    ST_BUSY = 2,   // жёлтый
    ST_ATTN = 3,   // красный
} slot_state_t;

void anim_init(void);
void anim_set_state(uint8_t slot, slot_state_t st, uint32_t now);   // то же состояние — ничего не делает
void anim_force_off(void);                                           // мгновенно, без crossfade (watchdog)
void anim_welcome(int slot, uint32_t now);                           // slot < 0 — волна по всем
void anim_set_brightness(uint8_t b);
void anim_set_config(bool busy_pulse, bool idle_pulse);
void anim_tick(uint32_t now);                                        // раз за тик: кадр → led_set()

bool anim_parse_state(const char *name, slot_state_t *st);
