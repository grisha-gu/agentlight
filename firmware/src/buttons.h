#pragma once
#include <stdbool.h>
#include <stdint.h>

// Slot buttons on GP12–GP15, to GND, internal pull-up.
// Only debounce and a "pressed" event for now; gestures (long, double) are a later step.

void buttons_init(void);
bool buttons_poll(uint8_t *slot);   // true — a slot was pressed (one event per call)
