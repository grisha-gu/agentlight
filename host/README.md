# host — демон и CLI для macOS

Устройство и решения — [docs/05-host-macos.md](../docs/05-host-macos.md),
логика слотов — [docs/01-architecture.md](../docs/01-architecture.md).

```
Sources/AgentLightKit/   вся логика без UI: HookEvent, SlotStateMachine, SlotAllocator,
                         StateStore, Config, DeviceProtocol, транспорты HID/CDC/fake,
                         HTTPServer, HookInstaller, TerminalCapture
Sources/agentlightd/     демон: склейка (Daemon.swift) + MenuBar/ (иконка и popover)
Sources/agentlight/      CLI
Tests/                   swift test — без железа и без Claude Code
scripts/build-app.sh     сборка AgentLight.app
```

## Разработка

```bash
cd host
swift test
swift run agentlightd --fake-device          # светофоры в терминале, клавиши 1–4 = кнопки
swift run agentlight replay ../tools/hook-capture/samples.jsonl
```

Чтобы не трогать настоящие `~/.agentlight` и порт 48879, поднимай отдельную копию:

```bash
mkdir -p /tmp/al && echo '{"port":48880}' > /tmp/al/config.json
AGENTLIGHT_HOME=/tmp/al swift run agentlightd --transport cdc
AGENTLIGHT_HOME=/tmp/al swift run agentlight status
```

`agentlightd --snapshot DIR` рендерит иконку и popover в PNG и выходит — удобно,
когда нет доступа к экрану.

## Установка

```bash
host/scripts/build-app.sh --install    # /Applications/AgentLight.app + /usr/local/bin/agentlight
agentlight install-daemon              # LaunchAgent, старт при входе
agentlight install-hooks               # хуки в ~/.claude/settings.json (резервная копия рядом)
agentlight doctor
```

Удаление: `agentlight uninstall-hooks && agentlight uninstall-daemon`.

### Подпись и Automation

Сборка всегда universal (arm64 + x86_64). `build-app.sh` подписывает первым, что найдёт:
**Developer ID Application** → самоподписанный «AgentLight Dev» → ad-hoc
(можно задать явно: `SIGN_IDENTITY="…" scripts/build-app.sh`).
Разрешения TCC привязаны к подписи: сменилась подпись — Automation выдаётся заново.

* При первом нажатии кнопки фокуса macOS спросит «AgentLight хочет управлять Terminal» →
  «Разрешить». Если отказали: Системные настройки → Конфиденциальность и безопасность →
  Автоматизация → AgentLight → Terminal.
* «AgentLight Dev» (только для своего мака): Связка ключей → Ассистент сертификации →
  Создать сертификат, тип «Подписывание кода».

### Раздача на другие маки

Один раз:
1. developer.apple.com → Certificates → **Developer ID Application** (создать может только
   Account Holder), CSR — из Связки ключей; скачанный `.cer` открыть двойным кликом.
2. appleid.apple.com → Пароли приложений → создать, затем
   `xcrun notarytool store-credentials agentlight-notary --apple-id <почта> --team-id <TEAM_ID>`.

Каждый релиз: `scripts/build-app.sh --dist` → подпись, нотаризация, степлер,
`build.noindex/AgentLight-<версия>.zip`. У получателя:

```bash
# распаковать, перетащить AgentLight.app в /Applications, затем
sudo ln -sf /Applications/AgentLight.app/Contents/MacOS/agentlight /usr/local/bin/agentlight
agentlight install-daemon && agentlight install-hooks
```

## Транспорты

| | когда | заметки |
|---|---|---|
| HID | основной, когда в прошивке появится vendor HID | VID 1209/2E8A, usage page 0xFF00 |
| CDC | сейчас, пока прошивка умеет только ASCII | порт ищется сам (ответ `OK agentlight` на `HELLO`), или `cdc_port` в config.json |
| fake | `--fake-device` | ANSI в терминале; лог уходит в `~/.agentlight/agentlightd.log` |
