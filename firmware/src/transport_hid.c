#include "transport_hid.h"

#include <string.h>

#include "tusb.h"

#define QUEUE_LEN 8   // PING раз в секунду, кнопки — редко; переполнение = потеря репорта

typedef struct {
    uint8_t buf[QUEUE_LEN][REPORT_SIZE];
    uint8_t head, tail;
} report_queue_t;

static report_queue_t rx, tx;

static bool queue_push(report_queue_t *q, const uint8_t *data, uint16_t len) {
    uint8_t next = (uint8_t)((q->head + 1) % QUEUE_LEN);
    if (next == q->tail)
        return false;
    memset(q->buf[q->head], 0, REPORT_SIZE);
    memcpy(q->buf[q->head], data, len < REPORT_SIZE ? len : REPORT_SIZE);
    q->head = next;
    return true;
}

static uint8_t *queue_front(report_queue_t *q) {
    return q->head == q->tail ? NULL : q->buf[q->tail];
}

static void queue_pop(report_queue_t *q) {
    q->tail = (uint8_t)((q->tail + 1) % QUEUE_LEN);
}

bool transport_hid_read(uint8_t report[REPORT_SIZE]) {
    uint8_t *r = queue_front(&rx);
    if (!r)
        return false;
    memcpy(report, r, REPORT_SIZE);
    queue_pop(&rx);
    return true;
}

void transport_hid_send(const uint8_t report[REPORT_SIZE]) {
    if (tud_mounted())
        queue_push(&tx, report, REPORT_SIZE);
}

void transport_hid_task(void) {
    uint8_t *r;
    while ((r = queue_front(&tx)) && tud_hid_ready() && tud_hid_report(0, r, REPORT_SIZE))
        queue_pop(&tx);
}

bool transport_hid_mounted(void) {
    return tud_mounted();
}

// OUT-репорт: по interrupt OUT или SET_REPORT по control — оба приходят сюда.
void tud_hid_set_report_cb(uint8_t instance, uint8_t report_id, hid_report_type_t type,
                           uint8_t const *buffer, uint16_t bufsize) {
    (void)instance;
    (void)report_id;
    if (type == HID_REPORT_TYPE_FEATURE || bufsize == 0)
        return;
    queue_push(&rx, buffer, bufsize);
}

uint16_t tud_hid_get_report_cb(uint8_t instance, uint8_t report_id, hid_report_type_t type,
                               uint8_t *buffer, uint16_t reqlen) {
    (void)instance;
    (void)report_id;
    (void)type;
    (void)buffer;
    (void)reqlen;
    return 0;
}
