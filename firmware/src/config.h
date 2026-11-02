#pragma once

#define FW_VERSION_MAJOR 0
#define FW_VERSION_MINOR 6
#define FW_VERSION_PATCH 0
#define PROTO_VERSION    1

#define SLOTS            4

// Встроенный WS2812 на модуле — индикатор «прошивка жива / хост на связи».
#define STATUS_LED_PIN   16

// Главный цикл: фиксированный тик 120 Гц.
#define TICK_US          8333

// Длина входной строки CDC, включая команду и аргументы.
#define CMD_LINE_MAX     96

// Кнопки слотов: GP12..GP15, к GND.
#define BTN_PIN_BASE     12
#define BTN_DEBOUNCE_MS  20

// Выключатель на задней стенке: GP26, к GND = «выкл» (docs/02-hardware.md §2.5).
#define POWER_PIN        26
#define POWER_DEBOUNCE_MS 30
// Огни гаснут и разгораются за то же время, что crossfade состояний.
#define POWER_FADE_MS    220

// Яркость цветов RED, YELLOW, GREEN. Подобрано на глаз на макетке 2026-10-23, без диффузора:
// красный 220 Ω, жёлтый 270 Ω (временно), зелёный 525 нм 330 Ω от 5 В — уровень 0x90 ≈ 0.28.
// Окончательно подбирать в корпусе (docs/04-firmware.md §4.4).
#define LED_CAL_INIT     { 1.00f, 1.00f, 0.28f }

// SELFTEST: шаг «по одному светодиоду». По спеке 80 мс; на подключении железа
// дольше, чтобы успеть понять, какой горит.
#define SELFTEST_STEP_MS 400

// Нет PING от хоста дольше этого — всё гаснет, !WD trip (docs/03-protocol.md §3.5).
#define WD_TIMEOUT_MS    3000
