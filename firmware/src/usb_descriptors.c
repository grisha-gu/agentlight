// Composite: vendor HID (рабочий канал, docs/03-protocol.md §3.3) + CDC (отладка, ASCII §3.4).

#include <string.h>

#include "pico/unique_id.h"
#include "tusb.h"

// На время разработки — VID/PID Pico SDK (docs/03-protocol.md §3.1); хост матчит по usage page.
#define USB_VID 0x2E8A
#define USB_PID 0x000A
#define USB_BCD 0x0200

enum { ITF_NUM_HID, ITF_NUM_CDC, ITF_NUM_CDC_DATA, ITF_NUM_TOTAL };

#define EPNUM_HID_OUT   0x01
#define EPNUM_HID_IN    0x81
#define EPNUM_CDC_NOTIF 0x82
#define EPNUM_CDC_OUT   0x03
#define EPNUM_CDC_IN    0x83

#define REPORT_SIZE 64

enum { STR_LANG, STR_MANUFACTURER, STR_PRODUCT, STR_SERIAL, STR_HID, STR_CDC };

static const tusb_desc_device_t desc_device = {
    .bLength            = sizeof(tusb_desc_device_t),
    .bDescriptorType    = TUSB_DESC_DEVICE,
    .bcdUSB             = USB_BCD,
    // IAD нужен CDC внутри composite
    .bDeviceClass       = TUSB_CLASS_MISC,
    .bDeviceSubClass    = MISC_SUBCLASS_COMMON,
    .bDeviceProtocol    = MISC_PROTOCOL_IAD,
    .bMaxPacketSize0    = CFG_TUD_ENDPOINT0_SIZE,
    .idVendor           = USB_VID,
    .idProduct          = USB_PID,
    .bcdDevice          = 0x0100,
    .iManufacturer      = STR_MANUFACTURER,
    .iProduct           = STR_PRODUCT,
    .iSerialNumber      = STR_SERIAL,
    .bNumConfigurations = 1,
};

// Usage page 0xFF00, usage 0x01: 64 байта IN + 64 байта OUT, без report ID.
static const uint8_t desc_hid_report[] = {
    TUD_HID_REPORT_DESC_GENERIC_INOUT(REPORT_SIZE)
};

#define CONFIG_TOTAL_LEN (TUD_CONFIG_DESC_LEN + TUD_HID_INOUT_DESC_LEN + TUD_CDC_DESC_LEN)

static const uint8_t desc_configuration[] = {
    TUD_CONFIG_DESCRIPTOR(1, ITF_NUM_TOTAL, 0, CONFIG_TOTAL_LEN, 0x00, 150),
    TUD_HID_INOUT_DESCRIPTOR(ITF_NUM_HID, STR_HID, HID_ITF_PROTOCOL_NONE, sizeof desc_hid_report,
                             EPNUM_HID_OUT, EPNUM_HID_IN, REPORT_SIZE, 1),
    TUD_CDC_DESCRIPTOR(ITF_NUM_CDC, STR_CDC, EPNUM_CDC_NOTIF, 8, EPNUM_CDC_OUT, EPNUM_CDC_IN, 64),
};

uint8_t const *tud_descriptor_device_cb(void) {
    return (uint8_t const *)&desc_device;
}

uint8_t const *tud_descriptor_configuration_cb(uint8_t index) {
    (void)index;
    return desc_configuration;
}

uint8_t const *tud_hid_descriptor_report_cb(uint8_t instance) {
    (void)instance;
    return desc_hid_report;
}

uint16_t const *tud_descriptor_string_cb(uint8_t index, uint16_t langid) {
    (void)langid;
    static uint16_t desc[1 + 32];
    static char serial[2 * PICO_UNIQUE_BOARD_ID_SIZE_BYTES + 1];
    const char *str;

    switch (index) {
    case STR_LANG:
        desc[1] = 0x0409;
        desc[0] = (uint16_t)((TUSB_DESC_STRING << 8) | 4);
        return desc;
    case STR_MANUFACTURER: str = "AgentLight"; break;
    case STR_PRODUCT:      str = "AgentLight"; break;
    case STR_SERIAL:
        // Serial = uid флеша: хост различает два устройства (docs/03-protocol.md §3.1)
        pico_get_unique_board_id_string(serial, sizeof serial);
        str = serial;
        break;
    case STR_HID:          str = "AgentLight HID"; break;
    case STR_CDC:          str = "AgentLight CDC"; break;
    default:               return NULL;
    }

    size_t n = strlen(str);
    if (n > 32)
        n = 32;
    for (size_t i = 0; i < n; i++)
        desc[1 + i] = (uint8_t)str[i];
    desc[0] = (uint16_t)((TUSB_DESC_STRING << 8) | (2 * n + 2));
    return desc;
}
