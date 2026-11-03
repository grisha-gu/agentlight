#include "anim.h"

#include <math.h>
#include <string.h>
#include <strings.h>

#include "config.h"
#include "leds.h"

enum { RED, YELLOW, GREEN };

#define XFADE_MS       220
#define WELCOME_MS     1200
#define WAVE_STEP_MS   120     // welcome offset between slots for WELCOME ALL
#define BUSY_PERIOD_MS 2200
#define PULSE_LOW      0.65f

typedef struct {
    slot_state_t target;
    float        from[3];        // what was on screen at the moment of the change
    float        shown[3];       // last frame output
    uint32_t     change_ms;      // crossfade start
    bool         welcome;
    uint32_t     welcome_ms;     // welcome start (may be in the future — the wave)
} slot_anim_t;

static slot_anim_t slots[SLOTS];
static uint8_t     brightness = 255;
static bool        busy_pulse = true, idle_pulse = false;

static const char *const STATE_NAMES[] = { "off", "idle", "busy", "attn" };

bool anim_parse_state(const char *name, slot_state_t *st) {
    for (int i = 0; i < 4; i++)
        if (strcasecmp(name, STATE_NAMES[i]) == 0) {
            *st = (slot_state_t)i;
            return true;
        }
    return false;
}

static void state_levels(slot_state_t st, float out[3]) {
    out[RED]    = st == ST_ATTN;
    out[YELLOW] = st == ST_BUSY;
    out[GREEN]  = st == ST_IDLE;
}

static float ease_in_out_cubic(float t) {
    return t < 0.5f ? 4 * t * t * t : 1 - powf(-2 * t + 2, 3) / 2;
}

static void lerp3(const float a[3], const float b[3], float t, float out[3]) {
    for (int c = 0; c < 3; c++)
        out[c] = a[c] + (b[c] - a[c]) * t;
}

static float ramp(uint32_t t, uint32_t t0, uint32_t t1) {
    return (float)(t - t0) / (float)(t1 - t0);
}

void anim_init(void) {
    memset(slots, 0, sizeof slots);
}

static void start_change(slot_anim_t *s, slot_state_t st, uint32_t now) {
    memcpy(s->from, s->shown, sizeof s->from);
    s->target = st;
    s->change_ms = now;
}

void anim_set_state(uint8_t slot, slot_state_t st, uint32_t now) {
    if (slot >= SLOTS || slots[slot].target == st)
        return;
    // During welcome the target simply changes: welcome finishes and crossfades into the new one.
    start_change(&slots[slot], st, now);
}

void anim_force_off(void) {
    anim_init();
}

void anim_welcome(int slot, uint32_t now) {
    for (int i = 0; i < SLOTS; i++) {
        if (slot >= 0 && i != slot)
            continue;
        slots[i].welcome = true;
        slots[i].welcome_ms = now + (slot < 0 ? (uint32_t)i * WAVE_STEP_MS : 0);
    }
}

void anim_set_brightness(uint8_t b) {
    brightness = b;
}

void anim_set_config(bool busy, bool idle) {
    busy_pulse = busy;
    idle_pulse = idle;
}

// R fade-in → R→Y → Y→G → G hold → all three → fade out → crossfade to target.
static bool welcome_frame(slot_anim_t *s, uint32_t now, float out[3]) {
    static const float R[3] = { 1, 0, 0 }, Y[3] = { 0, 1, 0 }, G[3] = { 0, 0, 1 }, ALL[3] = { 1, 1, 1 },
                       NONE[3] = { 0, 0, 0 };
    if ((int32_t)(now - s->welcome_ms) < 0)
        return false;
    uint32_t t = now - s->welcome_ms;
    float target[3];
    state_levels(s->target, target);

    if (t < 150)       lerp3(NONE, R, ramp(t, 0, 150), out);
    else if (t < 300)  lerp3(R, Y, ramp(t, 150, 300), out);
    else if (t < 450)  lerp3(Y, G, ramp(t, 300, 450), out);
    else if (t < 650)  memcpy(out, G, sizeof G);
    else if (t < 750)  lerp3(G, ALL, ramp(t, 650, 750), out);
    else if (t < 950)  lerp3(ALL, NONE, ramp(t, 750, 950), out);
    else if (t < WELCOME_MS) lerp3(NONE, target, ease_in_out_cubic(ramp(t, 950, WELCOME_MS)), out);
    else {
        s->welcome = false;
        return false;
    }
    return true;
}

void anim_tick(uint32_t now) {
    for (int i = 0; i < SLOTS; i++) {
        slot_anim_t *s = &slots[i];
        float lv[3];

        if (!(s->welcome && welcome_frame(s, now, lv))) {
            float to[3];
            state_levels(s->target, to);
            uint32_t dt = now - s->change_ms;
            if (dt < XFADE_MS)
                lerp3(s->from, to, ease_in_out_cubic((float)dt / XFADE_MS), lv);
            else
                memcpy(lv, to, sizeof lv);
        }

        // The pulse fades in over the crossfade time: otherwise frequent target changes (busy ↔ idle)
        // switch it on and off every frame, which shows up as fine flicker.
        uint32_t since = now - s->change_ms;
        float depth = since >= XFADE_MS ? 1 : (float)since / XFADE_MS;
        float wave = 0.5f * (1 + cosf(2 * (float)M_PI * (now % BUSY_PERIOD_MS) / BUSY_PERIOD_MS));
        float pulse = 1 - depth * (1 - PULSE_LOW) * (1 - wave);
        if (busy_pulse && s->target == ST_BUSY)
            lv[YELLOW] *= pulse;
        if (idle_pulse && s->target == ST_IDLE)
            lv[GREEN] *= pulse;
        // shown includes the pulse: the next crossfade starts exactly from what's lit, no jump.
        memcpy(s->shown, lv, sizeof lv);

        for (int c = 0; c < 3; c++)
            led_set((uint8_t)(i * 3 + c), lv[c] * brightness / 255.0f);
    }
}
