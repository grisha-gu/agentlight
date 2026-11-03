#pragma once
#include <stdbool.h>

// Power switch on the back wall (docs/02-hardware.md §2.5): GP26, pull-up, tied to GND = "off".
// Without a switch (breadboard, broken wire) the pin floats on the pull-up — the device is on.

void power_init(void);
bool power_is_on(void);
bool power_poll(bool *on);   // true — position changed (after debounce), *on — the new one
