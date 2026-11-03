#!/bin/bash
# Builds AgentLight.app (docs/05-host-macos.md §5.1).
#   scripts/build-app.sh            → host/build.noindex/AgentLight.app (the .noindex suffix keeps Spotlight/Apps from showing a second copy)
#   scripts/build-app.sh --install  → + copy to /Applications, CLI symlink, LaunchAgent restart
#   scripts/build-app.sh --dist     → + notarization and build.noindex/AgentLight-<version>.zip for other Macs
#
# Universal build (arm64 + x86_64). Signs with the first identity found (or $SIGN_IDENTITY):
#   1. "Developer ID Application: …" — hardened runtime + timestamp, fit for distribution
#   2. "AgentLight Dev" (self-signed) — for your own Mac only
#   3. ad-hoc — TCC will ask again after every rebuild
# TCC permissions (Automation) are tied to the signature: a new signature means granting them again.
#
# Notarization (--dist) takes the password from a notarytool profile, set up once:
#   xcrun notarytool store-credentials agentlight-notary --apple-id … --team-id …
# In CI, instead of a profile — an App Store Connect API key: NOTARY_KEY (path to .p8), NOTARY_KEY_ID, NOTARY_ISSUER.
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
# the icon is drawn by code; redraw only if the script is newer than the existing .icns
ICNS="$HOST_DIR/Resources/AgentLight.icns"
if [[ ! -f "$ICNS" || "$HOST_DIR/scripts/make-icon.swift" -nt "$ICNS" ]]; then
    swift "$HOST_DIR/scripts/make-icon.swift" "$HOST_DIR/Resources"
    rm -f "$HOST_DIR/Resources/icon-1024.png"
fi
cp "$ICNS" "$APP/Contents/Resources/"
# UI translations: English is the source language in the code, the rest are *.lproj
cp -R "$HOST_DIR"/Resources/*.lproj "$APP/Contents/Resources/"
# the single source of the version is AgentLightVersion.string in the code
VERSION="$(sed -n 's/.*static let string = "\(.*\)".*/\1/p' Sources/AgentLightKit/ControlAPI.swift)"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi
# no -v: a self-signed certificate is "not trusted", but that doesn't matter for a stable TCC requirement
if [[ -z "$IDENTITY" ]] && security find-identity -p codesigning | grep -q '"AgentLight Dev"'; then
    IDENTITY="AgentLight Dev"
fi
if [[ "$IDENTITY" == "Developer ID Application:"* ]]; then
    SIGN_ARGS=(--options runtime --timestamp --entitlements "$ENTITLEMENTS")
elif [[ -n "$IDENTITY" ]]; then
    SIGN_ARGS=()
else
    echo "⚠️  no certificates — signing ad-hoc"
    IDENTITY="-"
    SIGN_ARGS=()
fi
if [[ "$MODE" == "--dist" && "$IDENTITY" != "Developer ID Application:"* ]]; then
    echo "❌ --dist needs a Developer ID Application certificate (now: $IDENTITY)" >&2
    exit 1
fi
# sign the nested CLI separately (--deep won't do for notarization), then the bundle
codesign --force --sign "$IDENTITY" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$APP/Contents/MacOS/agentlight"
codesign --force --sign "$IDENTITY" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$APP"
codesign --verify --strict "$APP"
echo "built: $APP (version $VERSION, $(lipo -archs "$APP/Contents/MacOS/agentlightd"), signed by: $IDENTITY)"

if [[ "$MODE" == "--dist" ]]; then
    ZIP="$HOST_DIR/build.noindex/AgentLight-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    if [[ -n "${NOTARY_KEY:-}" ]]; then
        NOTARY_ARGS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
    else
        NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
    fi
    xcrun notarytool submit "$ZIP" "${NOTARY_ARGS[@]}" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"   # repack, now with the stapled ticket
    spctl --assess --type execute -v "$APP"
    echo "for distribution: $ZIP"
fi

if [[ "$MODE" == "--install" ]]; then
    rm -rf "$INSTALL_DIR/AgentLight.app"
    cp -R "$APP" "$INSTALL_DIR/"
    ln -sf "$INSTALL_DIR/AgentLight.app/Contents/MacOS/agentlight" /usr/local/bin/agentlight
    echo "installed: $INSTALL_DIR/AgentLight.app, CLI: /usr/local/bin/agentlight"
    if launchctl print "gui/$(id -u)/dev.grisha-gu.agentlight.daemon" >/dev/null 2>&1; then
        launchctl kickstart -k "gui/$(id -u)/dev.grisha-gu.agentlight.daemon"
        echo "daemon restarted"
    elif launchctl print "gui/$(id -u)/com.agentlight.daemon" >/dev/null 2>&1; then
        # before 0.2.0 the bundle id and label were different; install-daemon replaces the old LaunchAgent
        "$INSTALL_DIR/AgentLight.app/Contents/MacOS/agentlight" install-daemon
    else
        echo "next: agentlight install-daemon && agentlight install-hooks"
    fi
fi
