#pragma once
#include <stdbool.h>

// Выключатель на задней стенке (docs/02-hardware.md §2.12): GP26, pull-up, на GND = «выкл».
// Без переключателя (макетка, обрыв провода) пин висит на pull-up — устройство включено.

void power_init(void);
bool power_is_on(void);
bool power_poll(bool *on);   // true — положение сменилось (после дебаунса), *on — новое
