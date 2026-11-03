#pragma once

// Same as the SDK's own tusb_config.h: reset_interface.c (1200 baud → BOOTSEL) takes its defaults from here.
#include "pico/stdio_usb.h"

// The firmware brings up TinyUSB itself (composite HID + CDC, usb_descriptors.c);
// pico_stdio_usb still carries printf over CDC and catches 1200 baud → BOOTSEL.

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
