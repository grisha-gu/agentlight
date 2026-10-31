# 05. Хост: демон для macOS

## 5.1. Почему Swift и почему .app-бандл

Нужны три вещи, которые на macOS делаются проще всего нативно:

| Задача | API |
|---|---|
| USB HID без драйверов | `IOHIDManager` (IOKit) |
| фокус окна терминала | `NSAppleScript` / ScriptingBridge + Accessibility API |
| автозапуск, сон/просыпание | `launchd` + `NSWorkspace` notifications |

Python/Node потянут за собой рантайм, проблемы с подписью и мучения с TCC.
Rust сможет всё, но через FFI и `osascript`-шеллауты.

**Важно: демон должен жить внутри .app-бандла**, даже если у него нет окон
(`LSUIElement = true`). TCC (разрешения Automation и Accessibility) привязывается
к bundle identifier — у «голого» бинарника идентичность это путь + cdhash, и
каждая пересборка сбрасывает выданные разрешения. С бандлом разрешение выдаётся
один раз и живёт.

```
AgentLight.app/
└── Contents/
    ├── Info.plist             # LSUIElement=1, CFBundleIdentifier=com.agentlight.app
    ├── MacOS/
    │   ├── agentlightd        # демон
    │   └── agentlight         # CLI (symlink в /usr/local/bin)
    └── Resources/
        └── focus/*.scpt       # AppleScript-скрипты фокуса
```

## 5.2. Пакет

```
host/
├── Package.swift
└── Sources/
    ├── AgentLightKit/              # вся логика, покрыта тестами
    │   ├── SlotAllocator.swift      # claim/release/rebind/overflow
    │   ├── SlotStateMachine.swift   # событие → состояние
    │   ├── HookEvent.swift          # декодинг JSON всех хуков
    │   ├── SessionRecord.swift      # session_id, cwd, pid, terminal ref
    │   ├── StateStore.swift         # ~/.agentlight/state.json, atomic
    │   ├── Config.swift
    │   ├── DeviceTransport.swift    # protocol
    │   ├── HIDTransport.swift       # IOHIDManager
    │   ├── CDCTransport.swift       # termios, для отладки
    │   ├── FakeTransport.swift      # ANSI-рендер в терминал, без железа
    │   └── TerminalFocus/           # стратегии фокуса
    ├── agentlightd/                 # HTTP-сервер + склейка
    │   └── MenuBar/                 # NSStatusItem + popover со светофорами
    └── agentlight/                  # CLI
```

Тесты `AgentLightKitTests` — вся стейт-машина и аллокатор проверяются без железа
и без Claude Code, на записанных последовательностях событий (`tools/replay.jsonl`).

## 5.3. Приём хуков по HTTP

Claude Code поддерживает хук типа `http` — он делает POST на твой URL с тем же
JSON, что получает `command`-хук на stdin. Это сильно лучше `command` для
высокочастотных событий: `PreToolUse`/`PostToolUse` срабатывают на каждый вызов
инструмента, и форк процесса на каждый из них — 10–20 мс в горячем пути агента.

```swift
// NWListener на 127.0.0.1, минимальный HTTP/1.1
// Правило: ответить 204 МГНОВЕННО, обработку сделать после.
func handle(_ body: Data) {
    queue.async { self.router.dispatch(body) }   // не держим соединение
    respond(status: 204)
}
```

Жёсткие требования к серверу:

* слушать **только** `127.0.0.1` (никогда `0.0.0.0`);
* отвечать `204` за < 1 мс, вся работа — асинхронно;
* никогда не возвращать 5xx — хук с ошибкой пишет шум в дебаг-лог агента;
* `async: true` и `timeout: 2` на стороне хука, чтобы упавший демон вообще
  никак не влиял на работу агента.

### Проверено на практике (2026-10-05)

Главный риск проекта закрыт экспериментом: поднят логирующий сервер на 48879,
в `.claude/settings.json` прописаны `http`-хуки на восемь событий, снят реальный
трафик. Результаты:

| Вопрос | Ответ |
|---|---|
| `http`-хуки работают? | **да** |
| Метод, заголовки | `POST`, `Content-Type: application/json`, `User-Agent: axios/1.15.2`, `Accept-Encoding: gzip, compress, deflate, br` |
| Тело | **побайтово то же самое**, что `command`-хук получает на stdin (сверено программно: `http_body == stdin_json` → `True`) |
| Как различать события | поле `hook_event_name` **в теле** → один URL `/hook` на все события, роутинг по полю |
| `Connection` | **`keep-alive`** → сервер обязан держать persistent-соединения HTTP/1.1 |
| Подхват изменений `settings.json` | **на лету**, перезапуск сессии не нужен |
| Мёртвый эндпоинт ломает агента? | **нет.** При убитом сервере вызов инструмента прошёл без задержки и без ошибки (с `async: true`) |

### Поля, которых нет в документации

В реальном теле обнаружились поля, не описанные на
`https://code.claude.com/docs/en/hooks`. Декодер должен их принимать:

* **`scratchpad_dir`** — временный каталог сессии. Полезен сам по себе;
* `prompt_id` — UUID текущего хода, есть и в `PreToolUse`/`PostToolUse`;
* `permission_mode` — `"auto"`, `"default"`, `"plan"` и т.д.;
* `effort: {level: "high"}`;
* у `Stop` — `stop_hook_active`, **`background_tasks`** (массив запущенных
  фоновых задач с их статусом) и `session_crons`.

`background_tasks` пригодится позже: агент со живой фоновой задачей технически
не бездействует. Пока не используем, но поле стоит сохранять.

Фактические наборы полей по событиям (снято живьём):

```
PreToolUse        cwd effort hook_event_name permission_mode prompt_id
                  scratchpad_dir session_id tool_input tool_name
                  tool_use_id transcript_path
PostToolUse       + duration_ms tool_response
UserPromptSubmit  cwd hook_event_name permission_mode prompt prompt_id
                  scratchpad_dir session_id transcript_path
Stop              cwd effort hook_event_name last_assistant_message
                  permission_mode prompt_id scratchpad_dir session_crons
                  session_id stop_hook_active transcript_path background_tasks
Notification      cwd hook_event_name message notification_type prompt_id
                  scratchpad_dir session_id transcript_path
```

Обрати внимание: у `Notification` и `UserPromptSubmit` **нет** поля `effort`,
а у `Notification` нет и `permission_mode`. Ещё один довод за то, чтобы в
декодере всё было опциональным.

### Расхождение с документацией: PostToolUse

Документация обещает `tool_output: "string"`. **В реальности приходит
`tool_response` — объект**, плюс `duration_ms`:

```json
{
  "hook_event_name": "PostToolUse",
  "tool_response": {
    "stdout": "trigger-1: 17:32:13\ndone",
    "stderr": "",
    "interrupted": false,
    "isImage": false,
    "noOutputExpected": false
  },
  "duration_ms": 352
}
```

Для нашей задачи содержимое не нужно — `PostToolUse` используется только как
keepalive для `BUSY`. Но `HookEvent` в Swift надо декодировать так, чтобы
**неизвестные и отсутствующие поля не ломали разбор**: все поля кроме
`hook_event_name` и `session_id` — опциональные, лишние игнорируются.
Иначе смена формата в новой версии Claude Code положит индикацию.

### Следствия для реализации

1. Один эндпоинт `POST /hook`, роутинг по `hook_event_name` из тела.
2. Сервер на `NWListener` **обязан** поддерживать keep-alive: несколько запросов
   в одном TCP-соединении. Отвечать `204` с `Content-Length: 0`.
3. `agentlight install-hooks` применяется сразу, без перезапуска агентов —
   значит установка проходит в один шаг без «перезапусти все сессии».
4. Хуки и `command`, и `http` можно свободно смешивать на одном событии
   (проверено: на `PreToolUse` одновременно висели оба).
5. **`Notification(idle_prompt)` приходит ровно через 60 с после `Stop`** и
   означает лишь бездействие, а не блокировку. В `ATTN` его вести нельзя —
   разбор в [01-architecture.md](01-architecture.md#почему-idle_prompt-нельзя-вести-в-attn-проверено-2026-10-05).

Сырые данные эксперимента: `tools/hook-capture/` — сервер и снятые образцы.

## 5.4. Установка хуков

`agentlight install-hooks` дописывает в `~/.claude/settings.json`, **сохраняя
существующие хуки** (merge по событию, а не перезапись), и прописывает абсолютные
пути. `agentlight uninstall-hooks` убирает ровно свои записи по маркеру.

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ {
        "type": "command",
        "command": "'/Applications/AgentLight.app/Contents/MacOS/agentlight' hook",
        "async": true,
        "timeout": 5
      } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] }
    ],
    "PreToolUse":         [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "PostToolUse":        [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "PostToolUseFailure": [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "PermissionRequest":  [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "PermissionDenied":   [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "Notification":       [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "Elicitation":        [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "SubagentStart":      [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "SubagentStop":       [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "Stop":               [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "StopFailure":        [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ],
    "SessionEnd":         [ { "hooks": [ { "type": "http", "url": "http://127.0.0.1:48879/hook", "async": true, "timeout": 2 } ] } ]
    }
}
```

`SessionStart` — единственный `command`-хук, потому что ему нужно окружение
терминала, которого в HTTP-payload нет.

## 5.5. Захват идентичности терминала (ключевой трюк для кнопки)

`command`-хук запускается как дочерний процесс Claude Code и наследует его
окружение и контролирующий терминал. Отсюда можно достать всё нужное:

```swift
// agentlight hook — на SessionStart
struct TerminalRef: Codable {
    var termProgram: String?    // ProcessInfo: TERM_PROGRAM  ("iTerm.app", "Apple_Terminal", "ghostty", "WezTerm", "vscode")
    var itermSessionId: String? // ITERM_SESSION_ID → "w0t0p0:UUID"
    var tmuxPane: String?       // TMUX_PANE  ("%3") + TMUX (socket)
    var weztermPane: String?    // WEZTERM_PANE
    var kittyWindowId: String?  // KITTY_WINDOW_ID
    var tty: String?            // ttyname(open("/dev/tty")) → "/dev/ttys004"
    var claudePid: Int32?       // getppid(), затем вверх по дереву до процесса "claude"
    var windowTitleHint: String // basename(cwd)
}
```

* `tty`: `let fd = open("/dev/tty", O_RDONLY); String(cString: ttyname(fd))`.
  Это контролирующий терминал — именно по нему и Terminal.app, и iTerm2 умеют
  искать таб в AppleScript. Самый надёжный идентификатор.
* `claudePid`: `getppid()`, потом вверх через `proc_pidpath`/`sysctl(KERN_PROC_PID)`
  пока имя процесса не `claude`/`node`. Нужен и для фокуса, и для проверки живости.

Этот `TerminalRef` сохраняется в `SessionRecord` вместе с `session_id` и `cwd`.

## 5.6. Фокус окна по нажатию кнопки

Цепочка стратегий, первая сработавшая выигрывает. Порядок настраивается в
`config.terminal_focus_order`.

### 1. Terminal.app — основная стратегия (твой случай)

Terminal.app полностью скриптуется и умеет искать таб по tty. Это делает кнопку
точной: фокусируется именно нужный таб, а не просто окно.

```applescript
on run argv
  set theTTY to item 1 of argv
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        if tty of t is theTTY then
          set miniaturized of w to false   -- свёрнутое в Dock окно иначе не всплывёт
          set selected tab of w to t
          set index of w to 1
          activate
          return "ok"
        end if
      end repeat
    end repeat
  end tell
  return "notfound"
end run
```

Вызов: `NSAppleScript` с `Resources/focus/terminal_app.scpt`, аргумент — `tty`
из `TerminalRef`. `set index of w to 1` поднимает окно внутри приложения,
`activate` выводит вперёд само приложение — нужны оба.

**Нативные вкладки (проверено 2026-10-16).** В современной macOS вкладки Terminal —
системные, и AppleScript отдаёт **каждую вкладку отдельным `window` с одной `tab`**
(2 физических окна → 5 `windows` с одинаковыми `bounds`). Поэтому скрипт перебирает все
окна и все вкладки, а `set index of w to 1` поднимает нужную вкладку внутри группы.
Классические вкладки (несколько `tabs` в одном окне) покрывает `set selected tab`.

**Имя процесса claude.** Нативная сборка лежит в `~/.local/share/claude/versions/2.1.x`,
и её `p_comm` — версия («2.1.295»), а не `claude`. Опознавать по `argv[0]` или пути.

**`cwd` в хуках — текущий каталог шелла агента**, он меняется после `cd`. Проект сессии —
cwd первого события, дальше не перезаписывается.

Свойства проверены по словарю Terminal.app (`sdef /System/Applications/Utilities/Terminal.app`):
`tty` у класса `tab` (read-only text), `selected tab` / `index` / `miniaturized`
у класса `window`. Альтернатива `set selected of t to true` тоже валидна.

### 2. tmux (если `TMUX_PANE` есть)

Если запускаешь агентов в tmux внутри Terminal.app — сначала переключить панель,
потом сфокусировать само окно Terminal.app стратегией 1:

```bash
tmux select-window -t "$TMUX_PANE"
tmux select-pane  -t "$TMUX_PANE"
```

### 3. Открыть новое окно (фоллбэк)

```applescript
tell application "Terminal"
  do script "cd " & quoted form of theCwd & " && claude --resume " & theSessionId
  activate
end tell
```

Срабатывает, только если стратегия 1 вернула `notfound` (например, таб уже закрыт).

### 4. Прочие терминалы — отложить до M7

Интерфейс `TerminalFocusStrategy` остаётся расширяемым, но реализовывать сразу
не нужно. Когда понадобится:

| Терминал | Как |
|---|---|
| iTerm2 | тот же AppleScript, но перебор `sessions of t`, матч по `tty of s`, затем `select w/t/s` |
| WezTerm | `wezterm cli activate-pane --pane-id $WEZTERM_PANE` |
| Kitty | `kitty @ focus-window --match id:$KITTY_WINDOW_ID` (нужен `allow_remote_control yes`) |
| Ghostty, терминал VS Code/Cursor | скриптинга нет: фоллбэк на Accessibility API — найти окно приложения, у которого `AXTitle` содержит basename от `cwd`, затем `AXRaise` + `activate`. Таб внутри окна так не выбрать — известное ограничение |

Поскольку сейчас нужен только Terminal.app, **Accessibility-разрешение на M5 не
требуется** — хватает Automation для Terminal.app. Это заметно упрощает настройку.

### Если слот пуст

Кнопка под погашенным светофором запускает **новый** агент в каталоге из
`config.empty_slot_button_launches`, и тот автоматически заезжает в этот же слот
(аллокатор отдаёт предпочтение слоту, с чьей кнопки был запуск — передать
`AGENTLIGHT_PREFER_SLOT=n` в окружение запускаемого процесса, `SessionStart`-хук
прочитает его и передаст демону).

## 5.7. Разрешения TCC — что реально придётся нажать

| Разрешение | Зачем | Где выдать |
|---|---|---|
| **Automation** → Terminal | AppleScript-фокус таба по tty — **единственное нужное на M5** | всплывёт диалог при первом нажатии кнопки; потом Настройки → Конфиденциальность → Автоматизация |
| Accessibility | только для AX-фоллбэка (Ghostty и пр., фаза M7) | Настройки → Конфиденциальность → Универсальный доступ → добавить `AgentLight.app` вручную |
| Input Monitoring | **не нужно** для vendor-HID | — |

Грабли:

* Из launchd-агента диалоги TCC появляются, но могут быть «за» другими окнами —
  при первой настройке лучше запустить демон из терминала руками.
* Пересборка бинарника меняет cdhash → разрешения сбрасываются. Лечится
  подписью стабильным self-signed сертификатом:
  `codesign -s "AgentLight Dev" --force --deep AgentLight.app`, и при разработке
  не менять bundle id.
* `agentlight doctor` должен проверять все разрешения и печатать точные шаги
  («открой Настройки → ... → добавь это»), иначе диагностика превращается в ад.

## 5.8. Транспорт USB

```swift
final class HIDTransport: DeviceTransport {
    // IOHIDManagerCreate + matching dict: VendorID 0x1209, ProductID 0xAC01
    // IOHIDManagerRegisterDeviceMatchingCallback → устройство появилось
    // IOHIDManagerRegisterDeviceRemovalCallback  → устройство исчезло
    // IOHIDDeviceRegisterInputReportCallback     → !BTN / !PONG / !READY
    // IOHIDDeviceSetReport(kIOHIDReportTypeOutput, ...) → команды
}
```

* `PING` раз в 1000 мс отдельным таймером, иначе железка погасит светофоры.
* На `READY` (перезагрузка железки) — немедленно полный ресинк:
  `BRIGHTNESS`, `CONFIG`, `SET_ALL`.
* На removal — чистить ссылку, ждать matching callback, не опрашивать в цикле.
* Несколько устройств: каждое получает «банк» из 4 слотов по порядку подключения —
  первое показывает слоты 0..3, второе 4..7 и т. д. (`DeviceLink`). Устройство
  узнаётся по `uid` из `READY`: переподключённое встаёт на свой прежний банк, если тот
  свободен, иначе на минимальный свободный. Банк сверх `slot_count` горит выключенным.
* Одна железка, видная и по HID, и по CDC, — одно устройство: говорим через транспорт,
  что раньше в списке (HID), второй канал молчит, пока первый не пропадёт.

### Сон и просыпание

```swift
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification ...)
// → SET_ALL off, остановить PING
NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification ...)
// → пере-энумерация устройства, проверка живости всех PID, полный ресинк
```

После сна часть агентов уже мертва — обязательно прогнать `kill(pid, 0)` по всем
слотам, прежде чем что-то зажигать.

## 5.9. CLI

```
agentlight install-hooks [--settings PATH]   # merge в ~/.claude/settings.json
agentlight uninstall-hooks
agentlight install-daemon                    # LaunchAgent + копия .app
agentlight status                            # таблица: слот, состояние, проект, pid, терминал
agentlight test [--slot N]                   # welcome / selftest / перебор состояний
agentlight pin <slot> [path]                 # закрепить проект за слотом
agentlight brightness <0-255>
agentlight focus <slot>                      # то же, что кнопка — отладка фокуса без железа
agentlight doctor                            # устройство, разрешения, хуки, порт, версия протокола
agentlight hook                              # внутреннее: читает JSON со stdin, POST в демон
agentlight logs [-f]
agentlight flash <uf2>                       # picotool reboot -f -u + заливка
```

## 5.10. LaunchAgent

`~/Library/LaunchAgents/com.agentlight.daemon.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key>                 <string>com.agentlight.daemon</string>
  <key>ProgramArguments</key>
    <array><string>/Applications/AgentLight.app/Contents/MacOS/agentlightd</string></array>
  <key>RunAtLoad</key>             <true/>
  <key>KeepAlive</key>             <dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key>           <string>Interactive</string>
  <key>StandardOutPath</key>       <string>/tmp/agentlight.out.log</string>
  <key>StandardErrorPath</key>     <string>/tmp/agentlight.err.log</string>
</dict></plist>
```

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.agentlight.daemon.plist
launchctl kickstart -k gui/$(id -u)/com.agentlight.daemon   # перезапуск после пересборки
```

## 5.11. Разработка без железа

`FakeTransport` рисует 4 светофора ANSI-цветами в терминале и читает нажатия
клавиш `1234` как кнопки:

```
$ agentlightd --fake-device
  ┌────┐ ┌────┐ ┌────┐ ┌────┐
  │ ●  │ │ ○  │ │ ○  │ │ ○  │   R
  │ ○  │ │ ●  │ │ ○  │ │ ○  │   Y
  │ ○  │ │ ○  │ │ ●  │ │ ○  │   G
  └────┘ └────┘ └────┘ └────┘
   attn   busy   idle    off
  agent-ind  backend   infra    —
  [1]      [2]      [3]      [4]   ← нажми цифру = кнопка
```

Это позволяет сделать M4–M5 целиком, пока едут компоненты. Те же 4 светофора
рисует иконка в строке меню и её popover (M4, `MenuBar/`), так что видеть
состояние агентов можно и вообще без устройства.

Запись и воспроизведение событий:

```bash
agentlightd --record ~/replay.jsonl     # писать все входящие хуки
agentlight replay ~/replay.jsonl --speed 4   # прогнать в стейт-машину, сверить состояния
```

## 5.12. Чеклист приёмки хоста

* [x] запуск одного агента → welcome → зелёный; ввод промпта → жёлтый; ответ → зелёный (строка меню, 2026-10-16)
* [ ] `Bash(rm ...)` с запросом разрешения → красный; разрешил → жёлтый → зелёный
* [ ] 4 агента одновременно, каждый в своём слоте, состояния не путаются
* [ ] 5-й агент → в overflow, без светофора; закрыл 2-го → 5-й заехал в слот 1 с welcome
* [ ] `/clear` → светофор не гаснет и не меняет слот
* [ ] `claude --resume` в том же окне → тот же слот
* [ ] `kill -9` агента → слот гаснет в течение 5 с
* [ ] `launchctl kill` демона → все светофоры гаснут через 3 с (watchdog)
* [ ] перезапуск демона → состояния восстановлены из `state.json`
* [ ] выдернуть USB и вставить → всё восстанавливается без перезапуска демона
* [ ] сон/просыпание ноута → корректные состояния, мёртвые слоты погашены
* [ ] кнопка фокусирует правильный таб Terminal.app: таб в активном окне, таб в фоновом окне, окно свёрнуто в Dock
* [ ] кнопка на пустом слоте запускает агента, и он заезжает именно в этот слот
* [ ] измерить задержку: `UserPromptSubmit` → жёлтый. Цель < 50 мс
