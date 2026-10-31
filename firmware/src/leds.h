#pragma once
#include <stdint.h>

// 12 светодиодов на GP0–GP11, индекс = номер GPIO = slot * 3 + color.
// Протокол о типе светодиодов не знает: при переходе на адресуемые меняется только leds.c.

#define LED_COUNT 12

void leds_init(void);
void led_set(uint8_t index, float level);     // index 0..11, level 0..1 (линейный, до гаммы)
void leds_clear(void);
void leds_set_master(float level);             // общий множитель 0..1 поверх всех уровней (выключатель)
void leds_render(void);                        // level → гамма → калибровка → PWM
