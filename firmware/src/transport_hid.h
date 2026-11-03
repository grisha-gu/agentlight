#pragma once
#include <stdbool.h>
#include <stdint.h>

// Vendor HID: 64-byte reports both ways. TinyUSB callbacks only enqueue —
// tud_task() is also called from inside printf, so commands must not be executed in the callback.

#define REPORT_SIZE 64

bool transport_hid_read(uint8_t report[REPORT_SIZE]);   // true — an OUT report arrived
void transport_hid_send(const uint8_t report[REPORT_SIZE]);
void transport_hid_task(void);                              // send queued IN reports
bool transport_hid_mounted(void);
