#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_SRC="$ROOT_DIR/local.codex.tray.plist.template"
PLIST_DST="$HOME/Library/LaunchAgents/local.codex.tray.plist"
APP_PATH="$ROOT_DIR/CodexTray.app"

mkdir -p "$HOME/Library/LaunchAgents"
sed "s#__ROOT_DIR__#$ROOT_DIR#g; s#__APP_PATH__#$APP_PATH#g" "$PLIST_SRC" > "$PLIST_DST"

launchctl bootout "gui/$(id -u)" "$PLIST_DST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
launchctl enable "gui/$(id -u)/local.codex.tray"
launchctl kickstart -k "gui/$(id -u)/local.codex.tray"
