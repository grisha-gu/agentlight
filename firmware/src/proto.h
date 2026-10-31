#pragma once
#include <stdbool.h>
#include <stdint.h>

#include "anim.h"
#include "config.h"
#include "leds.h"

// Один набор команд, два кодирования (docs/03-protocol.md §3.3–3.4): HID-репорт и ASCII-строка
// разбираются в одну и ту же cmd_t, исполняет её main.c.

typedef enum {
    CMD_SET_STATE  = 0x01,
    CMD_SET_ALL    = 0x02,
    CMD_WELCOME    = 0x03,
    CMD_BRIGHTNESS = 0x04,
    CMD_PING       = 0x05,
    CMD_HELLO      = 0x06,
    CMD_SELFTEST   = 0x07,
    CMD_CONFIG     = 0x08,
    CMD_RAW        = 0x09,
} cmd_op_t;

// Устройство → хост, HID IN
enum {
    EV_READY  = 0x81,
    EV_BUTTON = 0x82,
    EV_PONG   = 0x83,
    EV_LOG    = 0x84,
    EV_POWER  = 0x85,
};

// bit0 был attn_blink — мигание красного удалено 2026-10-26, бит не используется
#define CONFIG_BUSY_PULSE 0x02
#define CONFIG_IDLE_PULSE 0x04

typedef struct {
    cmd_op_t op;
    union {
        struct { uint8_t slot; slot_state_t state; } set;
        slot_state_t all[SLOTS];
        int          welcome_slot;                 // -1 — волна по всем
        uint8_t      brightness;
        uint32_t     seq;
        struct { uint8_t mask, values; } config;  // ASCII может прислать не все ключи
        uint8_t      raw[LED_COUNT];
    };
} cmd_t;

// NULL — разобрано; иначе текст ошибки для «ERR …». line портится (strtok).
const char *proto_parse_line(char *line, cmd_t *cmd);
bool proto_parse_report(const uint8_t *r, cmd_t *cmd);
