#pragma once
#include <stdbool.h>
#include <stdint.h>

// Кнопки слотов на GP12–GP15, к GND, внутренний pull-up.
// Пока только дебаунс и событие «нажата»; жесты (long, double) — следующий шаг M2.

void buttons_init(void);
bool buttons_poll(uint8_t *slot);   // true — слот нажат (по одному событию за вызов)
