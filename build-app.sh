#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/CodexTray.app"
APP_BIN="$APP_DIR/Contents/MacOS/CodexTray"
LAUNCH_PLIST="$HOME/Library/LaunchAgents/local.codex.tray.plist"
BUNDLE_ID="local.codex.tray"

mkdir -p "$APP_DIR/Contents/MacOS"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>CodexTray</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>CodexTray</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

cd "$ROOT_DIR"
pkill -f "$APP_BIN" >/dev/null 2>&1 || true
if [[ -f "$LAUNCH_PLIST" ]]; then
  launchctl bootout "gui/$(id -u)" "$LAUNCH_PLIST" >/dev/null 2>&1 || true
fi

swift build
cp "$ROOT_DIR/.build/debug/CodexTray" "$APP_BIN.new"
mv "$APP_BIN.new" "$APP_BIN"
chmod +x "$APP_BIN"

if [[ -f "$LAUNCH_PLIST" ]]; then
  zsh "$ROOT_DIR/install-autostart.sh"
fi
