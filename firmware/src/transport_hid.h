#pragma once
#include <stdbool.h>
#include <stdint.h>

// Vendor HID: 64-байтные репорты в обе стороны. Колбэки TinyUSB только складывают в очередь —
// tud_task() зовётся и изнутри printf, поэтому исполнять команды прямо в колбэке нельзя.

#define REPORT_SIZE 64

bool transport_hid_read(uint8_t report[REPORT_SIZE]);   // true — пришёл OUT-репорт
void transport_hid_send(const uint8_t report[REPORT_SIZE]);
void transport_hid_task(void);                              // отправить накопленные IN-репорты
bool transport_hid_mounted(void);
