#include "proto.h"

#include <ctype.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define ERR_ARGS    "bad args"
#define ERR_SLOT    "bad slot"
#define ERR_UNKNOWN "unknown command"

static char *next_tok(void) {
    return strtok(NULL, " \t");
}

// strtoul silently accepts a sign ("-1" → ULONG_MAX) and saturates on overflow,
// and unsigned long is 32-bit on the RP2040 — so the sign and ERANGE are rejected by hand.
static bool parse_uint(const char *tok, int base, unsigned long max, unsigned long *out) {
    char *end;
    if (!tok || !isxdigit((unsigned char)*tok))
        return false;
    errno = 0;
    *out = strtoul(tok, &end, base);
    return !*end && errno != ERANGE && *out <= max;
}

// SET 2 busy
static const char *parse_set(cmd_t *c) {
    unsigned long slot;
    if (!parse_uint(next_tok(), 10, ~0ul, &slot))
        return ERR_ARGS;
    const char *name = next_tok();
    if (slot >= SLOTS)
        return ERR_SLOT;
    if (!name || !anim_parse_state(name, &c->set.state) || next_tok())
        return ERR_ARGS;
    c->set.slot = (uint8_t)slot;
    return NULL;
}

// SETALL idle busy attn off
static const char *parse_setall(cmd_t *c) {
    for (int i = 0; i < SLOTS; i++) {
        const char *name = next_tok();
        if (!name || !anim_parse_state(name, &c->all[i]))
            return ERR_ARGS;
    }
    return next_tok() ? ERR_ARGS : NULL;
}

// WELCOME 0 | WELCOME ALL
static const char *parse_welcome(cmd_t *c) {
    const char *tok = next_tok();
    unsigned long slot;
    if (!tok)
        return ERR_ARGS;
    if (strcasecmp(tok, "ALL") == 0)
        c->welcome_slot = -1;
    else if (parse_uint(tok, 10, ~0ul, &slot) && slot < SLOTS)
        c->welcome_slot = (int)slot;
    else
        return ERR_SLOT;
    return next_tok() ? ERR_ARGS : NULL;
}

// CONFIG busy_pulse=1 idle_pulse=0 — any subset of keys, in any order
static const char *parse_config(cmd_t *c) {
    static const struct { const char *key; uint8_t bit; } KEYS[] = {
        { "busy_pulse", CONFIG_BUSY_PULSE },
        { "idle_pulse", CONFIG_IDLE_PULSE },
    };
    c->config.mask = c->config.values = 0;
    char *tok;
    while ((tok = next_tok())) {
        char *eq = strchr(tok, '=');
        if (!eq || (strcmp(eq + 1, "0") != 0 && strcmp(eq + 1, "1") != 0))
            return ERR_ARGS;
        *eq = '\0';
        uint8_t bit = 0;
        for (unsigned k = 0; k < sizeof KEYS / sizeof KEYS[0]; k++)
            if (strcasecmp(tok, KEYS[k].key) == 0)
                bit = KEYS[k].bit;
        if (!bit)
            return ERR_ARGS;
        c->config.mask |= bit;
        if (eq[1] == '1')
            c->config.values |= bit;
    }
    return NULL;
}

// RAW ff 00 00 ... — 12 levels 0..255 in hex, order GP0..GP11
static const char *parse_raw(cmd_t *c) {
    for (int i = 0; i < LED_COUNT; i++) {
        unsigned long v;
        if (!parse_uint(next_tok(), 16, 255, &v))
            return ERR_ARGS;
        c->raw[i] = (uint8_t)v;
    }
    return next_tok() ? ERR_ARGS : NULL;
}

const char *proto_parse_line(char *line, cmd_t *c) {
    const char *name = strtok(line, " \t");
    unsigned long v;
    if (!name)
        return ERR_UNKNOWN;

    if (strcasecmp(name, "HELLO") == 0) {
        c->op = CMD_HELLO;
        return NULL;
    }
    if (strcasecmp(name, "SET") == 0) {
        c->op = CMD_SET_STATE;
        return parse_set(c);
    }
    if (strcasecmp(name, "SETALL") == 0) {
        c->op = CMD_SET_ALL;
        return parse_setall(c);
    }
    if (strcasecmp(name, "WELCOME") == 0) {
        c->op = CMD_WELCOME;
        return parse_welcome(c);
    }
    if (strcasecmp(name, "BRIGHT") == 0) {
        c->op = CMD_BRIGHTNESS;
        if (!parse_uint(next_tok(), 10, 255, &v) || next_tok())
            return ERR_ARGS;
        c->brightness = (uint8_t)v;
        return NULL;
    }
    if (strcasecmp(name, "PING") == 0) {
        c->op = CMD_PING;
        if (!parse_uint(next_tok(), 10, 0xFFFFFFFFul, &v) || next_tok())
            return ERR_ARGS;
        c->seq = (uint32_t)v;
        return NULL;
    }
    if (strcasecmp(name, "SELFTEST") == 0) {
        c->op = CMD_SELFTEST;
        return NULL;
    }
    if (strcasecmp(name, "CONFIG") == 0) {
        c->op = CMD_CONFIG;
        return parse_config(c);
    }
    if (strcasecmp(name, "RAW") == 0) {
        c->op = CMD_RAW;
        return parse_raw(c);
    }
    return ERR_UNKNOWN;
}

static bool valid_state(uint8_t s) {
    return s <= ST_ATTN;
}

bool proto_parse_report(const uint8_t *r, cmd_t *c) {
    c->op = (cmd_op_t)r[0];
    switch (r[0]) {
    case CMD_SET_STATE:
        if (r[1] >= SLOTS || !valid_state(r[2]))
            return false;
        c->set.slot = r[1];
        c->set.state = (slot_state_t)r[2];
        return true;
    case CMD_SET_ALL:
        for (int i = 0; i < SLOTS; i++) {
            if (!valid_state(r[1 + i]))
                return false;
            c->all[i] = (slot_state_t)r[1 + i];
        }
        return true;
    case CMD_WELCOME:
        if (r[1] != 0xFF && r[1] >= SLOTS)
            return false;
        c->welcome_slot = r[1] == 0xFF ? -1 : r[1];
        return true;
    case CMD_BRIGHTNESS:
        c->brightness = r[1];
        return true;
    case CMD_PING:
        c->seq = (uint32_t)r[1] | (uint32_t)r[2] << 8 | (uint32_t)r[3] << 16 | (uint32_t)r[4] << 24;
        return true;
    case CMD_HELLO:
    case CMD_SELFTEST:
        return true;
    case CMD_CONFIG:
        c->config.mask = CONFIG_BUSY_PULSE | CONFIG_IDLE_PULSE;
        c->config.values = r[1];
        return true;
    case CMD_RAW:
        memcpy(c->raw, &r[1], LED_COUNT);
        return true;
    default:
        return false;
    }
}
