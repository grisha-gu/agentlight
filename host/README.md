# host — macOS daemon and CLI

Design: [docs/05-host-macos.md](../docs/05-host-macos.md); slot logic:
[docs/01-architecture.md](../docs/01-architecture.md).

```
Sources/AgentLightKit/   all logic, no UI: HookEvent, SlotStateMachine, SlotAllocator,
                         StateStore, Config, DeviceProtocol, HID/CDC/fake transports,
                         HTTPServer, HookInstaller, TerminalCapture, TerminalFocus
Sources/agentlightd/     the daemon: wiring (Daemon.swift) + MenuBar/ (icon, popover, settings)
Sources/agentlight/      the CLI
Tests/                   swift test — no hardware, no Claude Code needed
scripts/build-app.sh     builds AgentLight.app
```

Requires macOS 13+ and Swift 6 (Xcode 16+).

## Development

```bash
cd host
swift test
swift run agentlightd --fake-device          # lights drawn in the terminal, keys 1–4 = buttons
swift run agentlight replay ../tools/hook-capture/samples.jsonl
```

To keep your real `~/.agentlight` and port 48879 untouched, run a separate instance:

```bash
mkdir -p /tmp/al && echo '{"port":48880}' > /tmp/al/config.json
AGENTLIGHT_HOME=/tmp/al swift run agentlightd --transport cdc
AGENTLIGHT_HOME=/tmp/al swift run agentlight status
```

`agentlightd --snapshot DIR` renders the menu bar icon (on a dark and a light bar) and
the popover to PNG files and exits.

## Installing

From Homebrew:

```bash
brew install --cask grisha-gu/tap/agentlight
```

From source:

```bash
host/scripts/build-app.sh --install    # /Applications/AgentLight.app + /usr/local/bin/agentlight
```

Then:

```bash
agentlight install-daemon              # LaunchAgent, starts at login
agentlight install-hooks               # hooks in ~/.claude/settings.json (a backup is written next to it)
agentlight doctor
```

Uninstall: `agentlight uninstall-hooks && agentlight uninstall-daemon`.

### Signing and Automation

Builds are always universal (arm64 + x86_64). `build-app.sh` signs with the first
identity it finds: **Developer ID Application** → a self-signed "AgentLight Dev"
certificate → ad-hoc (override with `SIGN_IDENTITY="…" scripts/build-app.sh`).
macOS permissions are bound to the signature and the bundle id
(`dev.grisha-gu.agentlight`); if either changes, Automation has to be granted again.
`agentlight doctor` shows the permission state.

* On the first focus button press macOS asks "AgentLight wants to control Terminal" →
  **Allow**. If it was denied: System Settings → Privacy & Security → Automation →
  AgentLight → Terminal.
* A self-signed "AgentLight Dev" certificate (for your own Mac only): Keychain Access →
  Certificate Assistant → Create a Certificate, type "Code Signing".

### Releases

`scripts/build-app.sh --dist` signs with Developer ID, notarizes, staples and writes
`build.noindex/AgentLight-<version>.zip`. It needs a Developer ID Application
certificate and a `notarytool` keychain profile:

```bash
xcrun notarytool store-credentials agentlight-notary --apple-id <email> --team-id <TEAM_ID>
```

Pushing a `v<version>` tag does the same in GitHub Actions
([`.github/workflows/release.yml`](../.github/workflows/release.yml)), attaches the zip
to the release and bumps the Homebrew cask.

## Transports

| | When | Notes |
|---|---|---|
| HID | default | VID `1209` / `2E8A`, usage page `0xFF00` |
| CDC | debugging (`--transport cdc`) | the port is found automatically (replies `OK agentlight` to `HELLO`), or set `cdc_port` in config.json |
| fake | `--fake-device` | ANSI in the terminal; the log goes to `~/.agentlight/agentlightd.log` |
