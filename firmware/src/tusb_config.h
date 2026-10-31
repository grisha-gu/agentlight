#pragma once

// Как и в tusb_config.h самого SDK: reset_interface.c (1200 бод → BOOTSEL) берёт отсюда свои дефолты.
#include "pico/stdio_usb.h"

// TinyUSB поднимает прошивка сама (composite HID + CDC, usb_descriptors.c);
// pico_stdio_usb при этом продолжает возить printf по CDC и ловить 1200 бод → BOOTSEL.

#define CFG_TUSB_RHPORT0_MODE  OPT_MODE_DEVICE
#define CFG_TUSB_OS            OPT_OS_PICO

#define CFG_TUD_ENDPOINT0_SIZE 64

#define CFG_TUD_HID            1
#define CFG_TUD_CDC            1
#define CFG_TUD_MSC            0
#define CFG_TUD_MIDI           0
#define CFG_TUD_VENDOR         0

#define CFG_TUD_HID_EP_BUFSIZE 64

#define CFG_TUD_CDC_RX_BUFSIZE 256
#define CFG_TUD_CDC_TX_BUFSIZE 256
#define CFG_TUD_CDC_EP_BUFSIZE 64
