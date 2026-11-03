// agentlight firmware (M2): LEDs, animations, buttons (press only), power switch, heartbeat watchdog,
// protocol over two transports — vendor HID (main) and CDC (ASCII, debugging). docs/03-protocol.md.

#include <ctype.h>
#include <stdio.h>
#include <string.h>

#include "anim.h"
#include "buttons.h"
#include "config.h"
#include "leds.h"
#include "pico/stdlib.h"
#include "pico/unique_id.h"
#include "power.h"
#include "proto.h"
#include "status_led.h"
#include "transport_hid.h"
#include "tusb.h"

typedef enum { VIA_CDC, VIA_HID } via_t;

static pico_unique_board_id_t uid;
static char uid_str[2 * PICO_UNIQUE_BOARD_ID_SIZE_BYTES + 1];

// SELFTEST: each LED in turn, then all red, all yellow, all green, then OFF.
// Doesn't block the loop: the step is computed from the start time.
#define SELFTEST_SINGLE_STEPS LED_COUNT
#define SELFTEST_STEPS        (SELFTEST_SINGLE_STEPS + 3 * 2)   // each whole color is held for two steps

// Who draws the frame: slot states (normal mode), RAW or SELFTEST.
// RAW holds until the first state command; SELFTEST returns to states when it finishes.
typedef enum { MODE_ANIM, MODE_RAW, MODE_SELFTEST } run_mode_t;

static run_mode_t mode = MODE_ANIM;
static uint32_t   selftest_start_ms;
static uint8_t    config_flags = CONFIG_BUSY_PULSE;

// The watchdog is armed by the first PING: manual tests via screen without a heartbeat don't go dark.
static bool     wd_armed;
static bool     wd_tripped;          // tripped and not yet reported in PONG
static uint32_t last_ping_ms;

static uint32_t now_ms(void) {
    return to_ms_since_boot(get_absolute_time());
}

static void put_le32(uint8_t *p, uint32_t v) {
    for (int i = 0; i < 4; i++)
        p[i] = (uint8_t)(v >> (8 * i));
}

static void selftest_tick(void) {
    uint32_t step = (now_ms() - selftest_start_ms) / SELFTEST_STEP_MS;
    leds_clear();
    if (step >= SELFTEST_STEPS) {
        mode = MODE_ANIM;
        return;
    }
    if (step < SELFTEST_SINGLE_STEPS) {
        led_set((uint8_t)step, 1.0f);
        return;
    }
    uint32_t color = (step - SELFTEST_SINGLE_STEPS) / 2;
    for (uint8_t slot = 0; slot < SLOTS; slot++)
        led_set(slot * 3 + color, 1.0f);
}

// --- replies and events -----------------------------------------------------

static void print_ident(const char *prefix) {
    printf("%s agentlight proto=%d fw=%d.%d.%d slots=%d uid=%s power=%s\n",
           prefix, PROTO_VERSION,
           FW_VERSION_MAJOR, FW_VERSION_MINOR, FW_VERSION_PATCH,
           SLOTS, uid_str, power_is_on() ? "on" : "off");
}

static void send_ready_report(void) {
    uint8_t r[REPORT_SIZE] = { EV_READY, PROTO_VERSION, SLOTS,
                                   FW_VERSION_MAJOR, FW_VERSION_MINOR, FW_VERSION_PATCH };
    memcpy(&r[6], uid.id, PICO_UNIQUE_BOARD_ID_SIZE_BYTES);
    r[14] = power_is_on();
    transport_hid_send(r);
}

static void reply_ident(via_t via) {
    if (via == VIA_HID)
        send_ready_report();
    else
        print_ident("OK");
}

static void reply_pong(via_t via, uint32_t seq) {
    if (via == VIA_HID) {
        uint8_t r[REPORT_SIZE] = { EV_PONG };
        put_le32(&r[1], seq);
        put_le32(&r[5], last_ping_ms);
        r[9] = wd_tripped;
        transport_hid_send(r);
    } else {
        printf("OK PONG %lu uptime=%lu wd=%d\n", (unsigned long)seq, (unsigned long)last_ping_ms, wd_tripped);
    }
}

// Events go to both transports: the host listens on the device's main channel and ignores the other.
static void emit_button(uint8_t slot) {
    uint32_t t = now_ms();
    printf("!BTN %u press t=%lu\n", slot, (unsigned long)t);
    uint8_t r[REPORT_SIZE] = { EV_BUTTON, slot, 1 /* BTN_PRESS */ };
    put_le32(&r[3], t);
    transport_hid_send(r);
}

static void emit_power(bool on) {
    printf("!POWER %s\n", on ? "on" : "off");
    uint8_t r[REPORT_SIZE] = { EV_POWER, on };
    transport_hid_send(r);
}

// "Off": everything drawn (states, RAW, SELFTEST) fades out via the master multiplier and
// fades back in — states keep changing underneath, so "on" shows the current picture.
static void power_fade_tick(void) {
    static float level = -1;
    if (level < 0)
        level = power_is_on();   // at startup — straight to the right position, no fade
    float step = TICK_US / 1000.0f / POWER_FADE_MS;
    if (power_is_on())
        level = level + step > 1 ? 1 : level + step;
    else
        level = level - step < 0 ? 0 : level - step;
    leds_set_master(level);
}

// --- command execution ------------------------------------------------------

static void exec(const cmd_t *c, via_t via) {
    uint32_t now = now_ms();
    switch (c->op) {
    case CMD_HELLO:
        reply_ident(via);
        return;
    case CMD_PING:
        wd_armed = true;
        last_ping_ms = now;
        reply_pong(via, c->seq);
        wd_tripped = false;
        return;
    case CMD_SET_STATE:
        mode = MODE_ANIM;
        anim_set_state(c->set.slot, c->set.state, now);
        break;
    case CMD_SET_ALL:
        mode = MODE_ANIM;
        for (int i = 0; i < SLOTS; i++)
            anim_set_state((uint8_t)i, c->all[i], now);
        break;
    case CMD_WELCOME:
        mode = MODE_ANIM;
        anim_welcome(c->welcome_slot, now);
        break;
    case CMD_BRIGHTNESS:
        anim_set_brightness(c->brightness);
        break;
    case CMD_CONFIG:
        config_flags = (uint8_t)((config_flags & ~c->config.mask) | (c->config.values & c->config.mask));
        anim_set_config(config_flags & CONFIG_BUSY_PULSE, config_flags & CONFIG_IDLE_PULSE);
        break;
    case CMD_SELFTEST:
        mode = MODE_SELFTEST;
        selftest_start_ms = now;
        break;
    case CMD_RAW:
        mode = MODE_RAW;
        for (int i = 0; i < LED_COUNT; i++)
            led_set((uint8_t)i, c->raw[i] / 255.0f);
        break;
    }
    // HID has no acknowledgements: a report is either accepted or not.
    if (via == VIA_CDC)
        printf("OK\n");
}

// No PING for longer than WD_TIMEOUT_MS — turn everything off and report once.
static void watchdog_tick(void) {
    if (!wd_armed || now_ms() - last_ping_ms < WD_TIMEOUT_MS)
        return;
    wd_armed = false;
    wd_tripped = true;
    mode = MODE_ANIM;
    anim_force_off();
    printf("!WD trip\n");
}

// --- transports -------------------------------------------------------------

// Non-blocking line read from CDC. Returns true when a line is ready.
static bool read_line(char *buf, size_t cap, size_t *len) {
    int c;
    while ((c = getchar_timeout_us(0)) != PICO_ERROR_TIMEOUT) {
        if (c == '\r' || c == '\n') {
            if (*len == 0)
                continue;
            buf[*len] = '\0';
            *len = 0;
            return true;
        }
        if (c == '\t')
            c = ' ';
        if (*len < cap - 1 && isprint(c))
            buf[(*len)++] = (char)c;
    }
    return false;
}

static void poll_cdc(void) {
    static char line[CMD_LINE_MAX];
    static size_t line_len;
    static bool was_connected;

    bool connected = stdio_usb_connected();
    if (connected && !was_connected)
        print_ident("!READY");
    was_connected = connected;

    while (read_line(line, sizeof line, &line_len)) {
        cmd_t c;
        const char *err = proto_parse_line(line, &c);
        if (err)
            printf("ERR %s\n", err);
        else
            exec(&c, VIA_CDC);
    }
}

static void poll_hid(void) {
    // READY once after enumeration: that's how the host learns the device has rebooted.
    static bool announced;
    bool mounted = transport_hid_mounted();
    if (mounted && !announced)
        send_ready_report();
    announced = mounted;

    uint8_t r[REPORT_SIZE];
    while (transport_hid_read(r)) {
        cmd_t c;
        if (proto_parse_report(r, &c))
            exec(&c, VIA_HID);
    }
}

int main(void) {
    pico_get_unique_board_id(&uid);
    pico_get_unique_board_id_string(uid_str, sizeof uid_str);
    // TinyUSB before stdio: stdio_usb_init expects the stack to be up already.
    tusb_init();
    stdio_init_all();
    status_led_init();
    leds_init();
    anim_init();
    buttons_init();
    power_init();

    absolute_time_t next = get_absolute_time();
    uint32_t tick = 0;

    uint32_t worst_late_us = 0, worst_work_us = 0, stats_ms = 0;

    while (true) {
        // Diagnostics: how late the frame was and how long it took. Once a second, if bad.
        uint64_t frame_start = time_us_64();
        uint32_t late = (uint32_t)(frame_start - to_us_since_boot(next));
        if (late > worst_late_us)
            worst_late_us = late;
        poll_cdc();
        poll_hid();

        bool on;
        if (power_poll(&on))
            emit_power(on);

        // Button debounce keeps running while "off", but events are suppressed: otherwise
        // a press made in the dark would fire when switched back "on".
        uint8_t slot;
        while (buttons_poll(&slot))
            if (power_is_on())
                emit_button(slot);

        watchdog_tick();

        if (mode == MODE_SELFTEST)
            selftest_tick();
        else if (mode == MODE_ANIM)
            anim_tick(now_ms());
        power_fade_tick();
        leds_render();

        // Host sends PING — steady dim green; otherwise a blue "breath" once a second: firmware alive.
        // When "off", the onboard RGB goes dark too.
        if (!power_is_on()) {
            status_led_set(0, 0, 0);
        } else if (wd_armed) {
            status_led_set(0, 6, 0);
        } else {
            uint32_t phase = tick % 120;
            uint8_t level = phase < 60 ? phase / 4 : (119 - phase) / 4;
            status_led_set(0, 0, level);
        }

        uint32_t work = (uint32_t)(time_us_64() - frame_start);
        if (work > worst_work_us)
            worst_work_us = work;
        if (now_ms() - stats_ms >= 1000) {
            if (worst_late_us > 1000 || worst_work_us > 2000)
                printf("!LOG tick late=%lu work=%lu us\n", (unsigned long)worst_late_us, (unsigned long)worst_work_us);
            worst_late_us = worst_work_us = 0;
            stats_ms = now_ms();
        }

        tick++;
        next = delayed_by_us(next, TICK_US);
        // Service USB the whole time until the next tick, not once every 8 ms.
        while (!time_reached(next)) {
            tud_task();
            transport_hid_task();
        }
    }
}
