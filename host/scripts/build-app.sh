#!/bin/bash
# Сборка AgentLight.app (docs/05-host-macos.md §5.1).
#   scripts/build-app.sh            → host/build.noindex/AgentLight.app (суффикс .noindex — чтобы Spotlight/Apps не показывали вторую копию)
#   scripts/build-app.sh --install  → + копия в /Applications, симлинк CLI, перезапуск LaunchAgent
#   scripts/build-app.sh --dist     → + нотаризация и build.noindex/AgentLight-<версия>.zip для других маков
#
# Сборка universal (arm64 + x86_64). Подпись — первая найденная (или $SIGN_IDENTITY):
#   1. "Developer ID Application: …" — hardened runtime + timestamp, годится для раздачи
#   2. "AgentLight Dev" (самоподписанный) — только для своего мака
#   3. ad-hoc — после каждой пересборки TCC спросит заново
# Разрешения TCC (Automation) привязаны к подписи: сменилась подпись — выдать заново.
#
# Нотаризация (--dist) берёт пароль из профиля notarytool, один раз:
#   xcrun notarytool store-credentials agentlight-notary --apple-id … --team-id …
set -euo pipefail

HOST_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HOST_DIR/build.noindex/AgentLight.app"
ENTITLEMENTS="$HOST_DIR/Resources/AgentLight.entitlements"
NOTARY_PROFILE="${NOTARY_PROFILE:-agentlight-notary}"
INSTALL_DIR="/Applications"
MODE="${1:-}"

cd "$HOST_DIR"
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/agentlightd" "$BIN/agentlight" "$APP/Contents/MacOS/"
cp "$HOST_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
# иконка рисуется кодом; перерисовываем, только если скрипт новее готового .icns
ICNS="$HOST_DIR/Resources/AgentLight.icns"
if [[ ! -f "$ICNS" || "$HOST_DIR/scripts/make-icon.swift" -nt "$ICNS" ]]; then
    swift "$HOST_DIR/scripts/make-icon.swift" "$HOST_DIR/Resources"
    rm -f "$HOST_DIR/Resources/icon-1024.png"
fi
cp "$ICNS" "$APP/Contents/Resources/"
# единственный источник версии — AgentLightVersion.string в коде
VERSION="$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/AgentLightKit/ControlAPI.swift)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi
# без -v: самоподписанный сертификат «не доверен», но для стабильного требования TCC это не важно
if [[ -z "$IDENTITY" ]] && security find-identity -p codesigning | grep -q '"AgentLight Dev"'; then
    IDENTITY="AgentLight Dev"
fi
if [[ "$IDENTITY" == "Developer ID Application:"* ]]; then
    SIGN_ARGS=(--options runtime --timestamp --entitlements "$ENTITLEMENTS")
elif [[ -n "$IDENTITY" ]]; then
    SIGN_ARGS=()
else
    echo "⚠️  сертификатов нет — подписываю ad-hoc"
    IDENTITY="-"
    SIGN_ARGS=()
fi
if [[ "$MODE" == "--dist" && "$IDENTITY" != "Developer ID Application:"* ]]; then
    echo "❌ для --dist нужен сертификат Developer ID Application (сейчас: $IDENTITY)" >&2
    exit 1
fi
# вложенный CLI подписываем отдельно (--deep для нотаризации не годится), потом бандл
codesign --force --sign "$IDENTITY" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$APP/Contents/MacOS/agentlight"
codesign --force --sign "$IDENTITY" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$APP"
codesign --verify --strict "$APP"
echo "собрано: $APP (версия $VERSION, $(lipo -archs "$APP/Contents/MacOS/agentlightd"), подпись: $IDENTITY)"

if [[ "$MODE" == "--dist" ]]; then
    ZIP="$HOST_DIR/build.noindex/AgentLight-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"   # перепаковка уже со степлером
    spctl --assess --type execute -v "$APP"
    echo "для раздачи: $ZIP"
fi

if [[ "$MODE" == "--install" ]]; then
    rm -rf "$INSTALL_DIR/AgentLight.app"
    cp -R "$APP" "$INSTALL_DIR/"
    ln -sf "$INSTALL_DIR/AgentLight.app/Contents/MacOS/agentlight" /usr/local/bin/agentlight
    echo "установлено: $INSTALL_DIR/AgentLight.app, CLI: /usr/local/bin/agentlight"
    if launchctl print "gui/$(id -u)/dev.grisha-gu.agentlight.daemon" >/dev/null 2>&1; then
        launchctl kickstart -k "gui/$(id -u)/dev.grisha-gu.agentlight.daemon"
        echo "демон перезапущен"
    elif launchctl print "gui/$(id -u)/com.agentlight.daemon" >/dev/null 2>&1; then
        # до 0.2.0 был другой bundle id и метка; install-daemon заменит старый LaunchAgent
        "$INSTALL_DIR/AgentLight.app/Contents/MacOS/agentlight" install-daemon
    else
        echo "дальше: agentlight install-daemon && agentlight install-hooks"
    fi
fi
