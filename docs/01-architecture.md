# 01. Архитектура

## 1.1. Почему нужен демон

vibesignal сделан stateless: каждый хук — отдельный короткоживущий процесс, который
пишет JSON-файл и сразу красит одну коммерческую лампу. Нам так нельзя:

* нужно держать **4 независимых слота** и помнить, какой `session_id` в каком слоте;
* нужно **читать кнопки** — кто-то должен постоянно висеть на USB и слушать устройство;
* нужно **гасить светофоры**, если агент умер без `SessionEnd`;
* нужен **один владелец USB-устройства** (hot-plug, reconnect, heartbeat).

Поэтому: резидентный демон `agentlightd` как LaunchAgent + stateless-хуки, которые
только отправляют событие в демон.

## 1.2. Состояния слота

```
        SessionStart
   OFF ─────────────► WELCOME ──► IDLE (зелёный)
    ▲                               │  ▲
    │                UserPromptSubmit│  │ Stop
    │ SessionEnd                     ▼  │ Notification(agent_completed)
    │ / watchdog                   BUSY (жёлтый)
    │                               │  ▲
    │          PermissionRequest    │  │ PreToolUse / PostToolUse
    │          Notification(...)    ▼  │ PermissionDenied
    └──────────────────────────── ATTN (красный)
```

Четыре видимых состояния + одно переходное:

| Код | Свет | Смысл |
|---|---|---|
| `OFF` | ничего | слот свободен, агента нет |
| `WELCOME` | анимация ~1.2 с | слот только что занят |
| `IDLE` | зелёный | агент жив, ждёт твой ввод |
| `BUSY` | жёлтый | агент думает / крутит инструменты |
| `ATTN` | красный | агент заблокирован, ждёт решения |

## 1.3. Маппинг хуков Claude Code → состояния

Все хуки получают `session_id`, `transcript_path`, `cwd`, `hook_event_name`.
Полный список событий и их полей: `https://code.claude.com/docs/en/hooks`.

| Хук | Матчер | Переход | Тип хука |
|---|---|---|---|
| `SessionStart` | — | claim слота → `WELCOME` → `IDLE` | **command** (нужны env терминала) |
| `UserPromptSubmit` | — | → `BUSY` | http |
| `PreToolUse` | — | → `BUSY` (keepalive) | http |
| `PostToolUse` | — | → `BUSY` (keepalive) | http |
| `PostToolUseFailure` | — | → `BUSY` | http |
| `PermissionRequest` | — | → `ATTN` | http |
| `Notification` | `permission_prompt` | → `ATTN` | http |
| `Notification` | `idle_prompt` | **игнорировать** (см. ниже) | http |
| `Notification` | `agent_needs_input` | → `ATTN` | http |
| `Notification` | `elicitation_dialog`, `elicitation_url_dialog` | → `ATTN` | http |
| `Notification` | `agent_completed` | → `IDLE` | http |
| `Elicitation` | — | → `ATTN` | http |
| `Stop` | — | → `IDLE` | http |
| `StopFailure` | — | → `ATTN` (ошибка API — нужен человек) | http |
| `SubagentStart` / `SubagentStop` | — | **не меняет** состояние (только продлевает жизнь сессии) | http |
| `PreCompact` / `PostCompact` | — | **не меняет** состояние | — |
| `SessionEnd` | — | release слота → `OFF` | http |

### Почему `idle_prompt` нельзя вести в `ATTN` (проверено 2026-10-05)

Изначально я отнёс `Notification(idle_prompt)` к «требуется ввод» → красный.
Захват реального трафика показал, что это ошибка:

```
17:34:19.679  Stop                        → IDLE (зелёный)
17:35:19.695  Notification idle_prompt    ровно +60.0 с
              message: "Claude is waiting for your input"
```

`idle_prompt` — это **таймер бездействия**, который срабатывает через 60 секунд
после того, как агент закончил ход. Он не означает, что агент чем-то заблокирован:
он означает ровно то же, что и `Stop` — агент закончил и ждёт тебя.

Если вести его в `ATTN`, получится так: агент ответил → зелёный → через минуту
красный. И все четыре светофора будут красными всё время, пока ты ими не
занимаешься. Это инвертирует весь смысл индикации: красный должен означать
«без тебя не поедет», а не «тут никого нет».

**Правило: `ATTN` только когда агент реально заблокирован решением** —
`PermissionRequest`, `Notification(permission_prompt)`,
`Notification(agent_needs_input)`, `Elicitation`, `StopFailure`.
`idle_prompt` не меняет состояние вообще.

Самоисцеляющиеся последовательности (важно — проверять на них):

```
Pre(BUSY) → PermissionRequest(ATTN) → [юзер разрешил] → PostToolUse(BUSY) → Stop(IDLE)
Pre(BUSY) → PermissionRequest(ATTN) → [юзер отклонил] → PermissionDenied(BUSY) → Stop(IDLE)
Stop(IDLE) → Notification(idle_prompt, +60 с)(состояние НЕ меняется, остаётся IDLE)
```

### Почему субагенты не красят в жёлтый (баг 2026-10-16)

Claude Code сам запускает форк-агентов, пока ты ничего не делаешь: `away_summary`
(сводка «пока тебя не было» через ~3 мин простоя), `prompt_suggestion`,
`agent_summary`, а ещё сжимает контекст в простое (`idleCompaction`). Когда
`SubagentStart`/`SubagentStop` вели в `BUSY`, простаивающий агент через 3 минуты
после `Stop` становился жёлтым и висел так до `busy_timeout_sec`. Настоящий субагент
работает внутри хода, когда слот уже жёлтый от `UserPromptSubmit`/`PreToolUse`, так
что эти события ничего не теряют. Для разбора подобного демон пишет все хуки (без
промптов и содержимого инструментов) в `~/.agentlight/hooks.jsonl`.

### Важный нюанс: `/clear` и `--resume`

`/clear` даёт `SessionEnd(end_reason="clear")`, затем `SessionStart(source="clear")`
с **новым** `session_id`. Если на `SessionEnd` слот освобождать сразу, светофор
мигнёт в OFF и агент может переехать в другой слот.

**Решение:** на `SessionEnd` с `end_reason ∈ {clear, resume}` слот не освобождается,
а помечается `rebinding` на 15 секунд с ключом `(cwd, claude_pid)`. Следующий
`SessionStart` с тем же ключом занимает тот же слот и **не** проигрывает welcome.

## 1.4. Аллокация слотов

```
claim(session_id, cwd, pid):
  1. если session_id уже в слоте → вернуть его
  1a. если процесс claude фоновый, без своего окна → в скрытый список background
  2. если есть слот в состоянии rebinding с ключом (cwd, pid) → занять его, без welcome
  3. если в конфиге есть pin для cwd (или родительского пути) и слот свободен → занять его
  4. иначе — минимальный свободный индекс 0..slot_count-1
  5. если свободных нет → в overflow-очередь (светофора не будет)
```

* Фоновые сессии хостит демон Claude Code (`claude --bg`, форк в фон): у `claude`
  родитель `bg-pty-host`, окна в терминале нет, фокусировать нечего. Демон ещё и заранее
  поднимает запасной процесс `--bg-spare`, который отрабатывает `SessionStart` без
  пользователя. Таким светофор не положен: события поглощаются в список `background`
  (виден в `agentlight status`), запись уходит по `SessionEnd` или смерти процесса.
  Проверка по PID идёт и в sweep раз в 5 с — так из слотов уходят сессии из state.json
  прошлой версии.
* `release(slot)` — по `SessionEnd`, по проверке живости (`kill(pid, 0)` раз в 5 с),
  или по TTL (нет событий 8 часов) — TTL только для сессий без известного PID,
  и время сна мака в него не засчитывается.
* Esc (прерывание хода, отказ от вопроса или запроса разрешения) хуков не шлёт —
  демон ловит строку `[Request interrupted by user…]` в transcript сессии → `IDLE`.
* Когда слот освобождается, занятые слоты справа от него сдвигаются влево — дырок
  между светофорами не остаётся (сдвинутые не проигрывают welcome, mute и rebinding
  едут вместе со слотом). В первый свободный слот из overflow-очереди заезжает сессия
  с самым свежим событием (и получает welcome). Пин и кнопка пустого слота влияют
  только на то, куда сессия встанет при старте.
* Маппинг персистится в `~/.agentlight/state.json` (atomic write через temp + rename),
  чтобы перезапуск демона не ломал привязки.

### Конфиг пинов

`~/.agentlight/config.json`:

```json
{
  "port": 48879,
  "brightness": 120,
  "slot_count": 4,
  "pins": {
    "/Users/me/projects/agentlight": 0,
    "/Users/me/work/backend": 1
  },
  "busy_timeout_sec": 900,
  "idle_pulse": false,
  "empty_slot_button_launches": "~/projects",
  "terminal_focus_order": ["tmux", "native", "ax", "new_window"]
}
```

`slot_count` — сколько светофоров в приложении (1–16, по умолчанию 4; меняется и в
«Настройках…»). Одно устройство показывает 4 из них: первое подключённое — слоты 0..3,
второе — 4..7 и т. д. ([§5.8](05-host-macos.md#58-транспорт-usb)). Слоты без устройства
видны только в строке меню. При уменьшении `slot_count` сессии из лишних слотов уходят
в overflow, при увеличении — новые слоты заполняются из overflow.

## 1.5. Watchdog на двух уровнях

| Уровень | Условие | Действие |
|---|---|---|
| хост → слот | в `BUSY` нет событий `busy_timeout_sec` (900 с) | деградировать в `IDLE` |
| хост → слот | `kill(pid, 0)` не проходит | `release` → `OFF` |
| железка → все слоты | нет `PING` от хоста > 3 с | погасить все светофоры |

Третий пункт — ключевой для честности индикации: если демон упал или мак ушёл в
сон, светофоры гаснут сами, а не врут зелёным.

## 1.6. Кнопки

| Нажатие | Слот занят | Слот пуст |
|---|---|---|
| короткое | сфокусировать окно терминала агента | запустить новый `claude` в каталоге из `empty_slot_button_launches` |

**Жесты (долгое, двойное) убраны 2026-10-23**: у кнопки одно действие, реакция мгновенная,
без ожидания «а вдруг будет второе нажатие». Mute слота остался только командой
`agentlight mute <slot>`. Дебаунс — в прошивке, хост получает готовое `!BTN <slot> press`.

## 1.7. Структура репозитория (целевая)

```
agent-indicator/
├── firmware/              # Pico SDK, C
│   ├── CMakeLists.txt
│   ├── src/main.c         # главный цикл 60 Гц
│   ├── src/leds.c         # 12 каналов PWM, гамма, PWM 14 бит, калибровка
│   ├── src/anim.c         # кроссфейды, welcome, пульс
│   ├── src/buttons.c      # дебаунс, жесты
│   ├── src/proto.c        # разбор команд, события
│   └── src/usb_descriptors.c
├── host/                  # Swift Package
│   ├── Package.swift
│   └── Sources/
│       ├── agentlightd/   # демон
│       ├── AgentLightKit/ # слоты, стейт-машина, транспорт
│       └── agentlight/    # CLI: install-hooks, status, test
├── hardware/              # KiCad (фаза 7)
├── enclosure/             # OpenSCAD / STEP + STL
├── tools/
│   ├── proto_test.py      # стресс-тест протокола прошивки (M2)
│   └── replay.jsonl       # записанные хук-события для тестов
└── docs/
```
