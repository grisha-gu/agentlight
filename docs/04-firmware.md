# 04. Прошивка (RP2040)

## 4.1. Стек

**Pico SDK (C) + TinyUSB.** Причины: прямой доступ к 14-битному PWM и жёсткому
маппингу слайсов, TinyUSB умеет composite HID+CDC из коробки, всё документировано
и отлаживается `picotool`/SWD.

Альтернативы: Rust + `embassy-rp` (приятнее, но composite USB настраивать дольше),
Arduino-core (быстрее стартовать, но меньше контроля над USB-дескрипторами).
Для v1 — Pico SDK.

## 4.2. Структура

```
firmware/
├── CMakeLists.txt
├── pico_sdk_import.cmake
└── src/
    ├── main.c              # init + главный цикл
    ├── config.h            # SLOTS, пины, тайминги, калибровка яркости
    ├── leds.c/.h           # 12 каналов PWM, гамма, калибровка, led_set()
    ├── anim.c/.h           # стейт-машина слота, кроссфейды, welcome, пульс
    ├── buttons.c/.h        # дебаунс, событие press
    ├── proto.c/.h          # единый парсер команд, очередь событий
    ├── transport_hid.c     # HID IN/OUT репорты
    ├── transport_cdc.c     # построчный ASCII
    ├── usb_descriptors.c   # composite: HID (vendor) + CDC
    └── watchdog.c/.h       # контроль heartbeat от хоста
```

## 4.3. Главный цикл

Фиксированный тик 120 Гц (8.33 мс). Ничего блокирующего, никаких `sleep_ms`
в логике.

```c
int main(void) {
    stdio_init_all();
    board_uid_init();
    leds_init();                   // 12 пинов GP0..GP11, PWM 14 бит
    buttons_init();
    tusb_init();
    anim_init();
    watchdog_host_init(3000 /* ms */);

    anim_power_on_wave();              // волна по 4 слотам при включении
    proto_emit_ready();                // !READY / 0x81

    absolute_time_t next = get_absolute_time();
    while (true) {
        tud_task();                    // USB
        transport_hid_poll();
        transport_cdc_poll();

        cmd_t cmd;
        while (proto_pop(&cmd))
            anim_apply(&cmd);          // идемпотентно

        if (watchdog_host_expired()) {
            anim_force_all_off();
            proto_emit_wd_trip();      // один раз на срабатывание
        }

        btn_event_t ev;
        while (buttons_poll(&ev))
            proto_emit_button(ev.slot, ev.gesture, ev.t_ms);

        next = delayed_by_us(next, 8333);
        if (absolute_time_diff_us(get_absolute_time(), next) > 0) {
            anim_tick();               // посчитать кадр
            leds_render();             // гамма + калибровка → pwm_set_chan_level
            sleep_until(next);
        } else {
            next = get_absolute_time();  // не догоняем, пропускаем кадр
        }
    }
}
```

## 4.4. Рендер светодиодов

Абстракция, за которой спрятан способ вывода — если когда-нибудь переедем на
адресуемые светодиоды, меняется только `leds.c`:

```c
void leds_init(void);
void led_set(uint8_t index, float level);     // index 0..11, level 0..1 (линейный, до гаммы)
void leds_render(void);                        // level → гамма → калибровка → PWM
```

### Инициализация PWM

Маппинг жёсткий: `слайс = (gpio / 2) % 8`, канал `A` для чётных GPIO, `B` для
нечётных. `GP0–GP11` дают 12 независимых каналов на слайсах 0–5.

```c
#define LED_COUNT   12
#define PWM_WRAP    16383           // 14 бит

void leds_init(void) {
    for (uint pin = 0; pin < LED_COUNT; pin++) {
        gpio_set_function(pin, GPIO_FUNC_PWM);
        gpio_set_drive_strength(pin, GPIO_DRIVE_STRENGTH_8MA);
        uint slice = pwm_gpio_to_slice_num(pin);
        pwm_set_wrap(slice, PWM_WRAP);          // 125 МГц / 16384 ≈ 7.6 кГц
        pwm_set_clkdiv(slice, 1.0f);
        pwm_set_enabled(slice, true);
    }
}
```

7.6 кГц — выше любого видимого мерцания, в том числе на видео и в периферийном
зрении. Уходить ниже 1 кГц нельзя: на камеру телефона появятся полосы.

Сначала было 12 бит (30.5 кГц), но приёмка 2026-10-23 показала слабые ступени в
самом низу затухания: там 1 → 2 отсчёта из 4095 — скачок яркости вдвое. 14 бит
дают в 4 раза более мелкий шаг; частота при этом всё ещё с запасом выше 1 кГц.

### Гамма: float до самого PWM

Главный выигрыш перед WS2812. Устройство на столе работает на 10–20 % яркости,
и там 8-битный выход даёт заметные ступени при затухании. Поэтому уровни от
анимаций (уже умноженные на `BRIGHT`) хранятся во float 0..1 и разворачиваются
в PWM одной формулой, без промежуточного округления до 8 бит:

```c
v = lroundf(powf(level, 2.2f) * LED_CAL[color] * PWM_WRAP);
```

8 бит остаются только во входе протокола (`RAW`, `BRIGHT`). Поэтому `RAW` — инструмент
отладки, а не плавности: уровень 5 → 4 — это −40 % яркости.

Главный цикл раз в секунду пишет `!LOG tick late=… work=… us`, если кадр опоздал
больше чем на 1 мс или занял больше 2 мс (fw 0.4.3).

### Калибровка цветов

Красный, жёлтый и зелёный при одном токе воспринимаются по-разному яркими
(глаз чувствительнее всего к 555 нм, то есть к зелёному). Выравнивается
коэффициентами, подобранными на глаз на M1:

```c
// RED, YELLOW, GREEN — подобрать живьём за диффузором корпуса
static const float LED_CAL[3] = { 1.00f, 0.85f, 0.95f };

void leds_render(void) {
    for (uint i = 0; i < LED_COUNT; i++) {
        uint16_t v = fb[i] > 0 ? (uint16_t)lroundf(powf(fb[i], 2.2f) * LED_CAL[i % 3] * PWM_WRAP) : 0;
        pwm_set_gpio_level(i, v);
    }
}
```

Калибровку делать **в собранном корпусе**: матовый пластик и козырёк меняют
восприятие сильнее, чем разница в самих светодиодах.

### Чего больше не нужно

Относительно варианта с WS2812 из прошивки удаляются: PIO-программа, DMA-канал,
reset-импульс 280 мкс между кадрами, преобразование RGB→GRB и power limiter
(максимум 72 мА при 220 Ω × 12 — бюджет USB не напряжён). Это примерно
−150 строк и −1 микросхема на плате.

## 4.5. Анимации

Каждый слот — независимая мини-стейт-машина с таймлайном:

```c
typedef struct {
    slot_state_t  target;       // куда идём
    slot_state_t  shown;        // что показываем
    uint32_t      phase_start;  // ms
    anim_phase_t  phase;        // PH_STEADY | PH_CROSSFADE | PH_WELCOME
    rgb_t         from[3], to[3];
} slot_anim_t;
```

| Анимация | Параметры |
|---|---|
| **crossfade** | 220 мс, easing `ease-in-out-cubic`, между любыми двумя состояниями |
| **welcome** | 1200 мс: R fade-in 0→150, R→Y 150→300, Y→G 300→450, G hold 450→650, затем все три ярко 650→750, затухание 750→950, crossfade в целевое состояние 950→1200 |
| **power-on wave** | welcome со сдвигом 120 мс на слот, затем всё в OFF |
| **attn** | ровный красный. Мигания нет и включить его нельзя — удалено 2026-10-26 |
| **busy pulse** | жёлтый дышит 1.0 ↔ 0.65 с периодом 2.2 с — глазом видно, что агент жив, а не замер. Глубина пульса нарастает за 220 мс после смены состояния, а crossfade стартует с реально горящего уровня (с пульсом) — частая смена busy ↔ idle не мигает |
| **idle pulse** | по умолчанию выключено: зелёный ровный, чтобы не отвлекал |
| **selftest** | по очереди каждый светодиод 80 мс, затем все R, все Y, все G, затем OFF |

Все переходы считаются во float и только на выходе разворачиваются в 14-битный PWM
через гамму — поэтому затухание с 20 % до нуля идёт плавно, без ступеней.

Правило: **анимация никогда не блокирует приём команд.** Пришёл `SET_STATE` во
время welcome — welcome доигрывается, но `target` уже новый, и crossfade в конце
ведёт в него.

## 4.6. Кнопки: дебаунс

Опрос в каждом тике (8.33 мс). Уровень принимается, если продержался
`BTN_DEBOUNCE_MS` (20 мс) без дребезга; на переходе в «нажата» сразу уходит
`BTN_PRESS` — в оба транспорта.

Жестов (долгое, двойное) нет — **убраны 2026-10-23**: распознавание двойного
стоило бы 350 мс задержки на каждое нажатие, а мгновенная реакция важнее.

## 4.7. USB-дескрипторы

```c
// usb_descriptors.c — composite
enum { ITF_NUM_HID, ITF_NUM_CDC, ITF_NUM_CDC_DATA, ITF_NUM_TOTAL };

static const uint8_t desc_hid_report[] = {
    0x06, 0x00, 0xFF,        // Usage Page (Vendor 0xFF00)
    0x09, 0x01,              // Usage (0x01)
    0xA1, 0x01,              //   Collection (Application)
    0x09, 0x02, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08,
    0x95, 0x40, 0x81, 0x02,  //     Input  (64 bytes)
    0x09, 0x03, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08,
    0x95, 0x40, 0x91, 0x02,  //     Output (64 bytes)
    0xC0
};
```

Serial-строка собирается из `pico_get_unique_board_id_string()`.
`CFG_TUD_HID = 1`, `CFG_TUD_CDC = 1` в `tusb_config.h`.

## 4.8. Сборка и прошивка

```bash
# один раз
brew install cmake ninja picotool
git clone --depth 1 --branch 2.1.1 https://github.com/raspberrypi/pico-sdk ~/pico-sdk
cd ~/pico-sdk && git submodule update --init --depth 1   # нужен lib/tinyusb

# компилятор — официальный архив Arm, НЕ формула brew arm-none-eabi-gcc:
# в формуле нет newlib, сборка падает на «cannot read spec file nosys.specs».
# Архив ставится без sudo (cask gcc-arm-embedded — то же самое, но через .pkg).
mkdir -p ~/tools && cd ~/tools
curl -fLO https://developer.arm.com/-/media/Files/downloads/gnu/14.2.rel1/binrel/arm-gnu-toolchain-14.2.rel1-darwin-x86_64-arm-none-eabi.tar.xz
tar xf arm-gnu-toolchain-*.tar.xz && rm arm-gnu-toolchain-*.tar.xz

# сборка (плата задана в CMakeLists.txt)
cd firmware && cmake -B build -G Ninja -DPICO_SDK_PATH=~/pico-sdk \
    -DPICO_TOOLCHAIN_PATH=~/tools/arm-gnu-toolchain-14.2.rel1-darwin-x86_64-arm-none-eabi
cmake --build build

# прошить: зажать BOOT, подключить USB → смонтируется RPI-RP2
cp build/agentlight.uf2 /Volumes/RPI-RP2/
# либо, если уже прошито и USB работает:
picotool load -f build/agentlight.uf2
```

`picotool reboot -f -u` из хост-демона позволит делать обновление прошивки без
залезания под корпус — заведи в `agentlight` CLI команду `agentlight flash`.

## 4.9. Чеклист приёмки прошивки

Прогон: `python3 tools/proto_test.py --manual --stop-daemon` (автоматические проверки
по CDC + ручные с вопросами y/n; `--list` — все имена, `--only` — выборочно).
HID скрипт не проверяет — его гоняет демон.

**Приёмка пройдена 2026-10-26 на fw 0.5.0** (последние результаты — `--list`, непройденные — `--pending`).
Открыты два пункта, оба переезжают на M6 — их осмысленно делать в собранном корпусе:

* [x] `HELLO` отвечает корректной версией и uid
* [x] все команды, невалидные аргументы → `ERR` (34 случая; на fw 0.4.1 исправлены
  переполнение/знак в числах и табы в строке)
* [x] все 12 светодиодов зажигаются по одному через `RAW` в нужном порядке (слот 0 — левый)
* [ ] три цвета на глаз равной яркости за диффузором корпуса (`LED_CAL` подобран) — на M6
* [x] пульс busy (BRIGHT 255 и 30) и crossfade — без видимых ступеней и рывков (гамма, 14 бит).
  Через `RAW 50 → 0` не проверяется: вход `RAW` 8 бит до гаммы, внизу ступени неизбежны.
  Рывки на fw 0.4.2 — пульс включался/выключался мгновенно при смене цели; fw 0.5.0
  вводит его за 220 мс и стартует crossfade с реально горящего уровня
* [x] снять на телефон: никаких полос и мерцания (PWM 7.6 кГц, fw 0.4.2)
* [x] переключение `SET 0 busy` ↔ `SET 0 idle` 200 раз/с — все 1000 ответов, без `!WD`,
  на глаз без вспышек (fw 0.5.0)
* [x] welcome не ломается, если в середине пришло новое состояние
* [x] повторный `SET` с тем же состоянием не перезапускает анимацию
* [x] отключение heartbeat → через 3 с всё гаснет + `!WD trip` ровно один раз
* [x] переподключение USB → `!READY`, светофоры погашены до команд хоста
* [x] все 4 кнопки дают `!BTN n press`, ложных срабатываний нет при стуке по столу
* [ ] все 12 на полную (`RAW ff` ×12 — `SELFTEST` зажигает максимум 4 сразу): ток мультиметром < 120 мА
  — не мерили, перенесено в M6 (§6.8 п. 9)
* [x] устройство не греется, модуль RP2040 тёплый максимум
* [x] выключатель (fw 0.6.0, `--only power`, проверено проводом 2026-10-27): провод GP26 → GND — `!POWER off` один раз, огни и
  встроенный RGB плавно гаснут за 220 мс, кнопки молчат, `HELLO` говорит `power=off`; провод убрать —
  `!POWER on`, огни разгораются с состоянием, присланным в «выкл»
