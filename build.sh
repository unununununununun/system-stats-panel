#!/bin/bash
# Сборка, установка в /Applications и запуск панели мониторинга.
set -euo pipefail
cd "$(dirname "$0")"

APP="StatsPanel.app"

# Остановить предыдущий экземпляр и дождаться, пока он освободит SMC-соединение.
pkill -x StatsPanel 2>/dev/null || true
for _ in $(seq 1 30); do
    pgrep -x StatsPanel >/dev/null 2>&1 || break
    sleep 0.1
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
if [ -f tools/AppIcon.icns ]; then
    cp tools/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

swiftc -O main.swift -o "$APP/Contents/MacOS/StatsPanel" \
    -framework AppKit -framework SwiftUI
codesign --force --sign - "$APP" 2>/dev/null

# Установка: /Applications, при отсутствии прав — ~/Applications.
DEST="/Applications/StatsPanel.app"
if rm -rf "$DEST" 2>/dev/null && ditto "$APP" "$DEST" 2>/dev/null; then
    TARGET="$DEST"
else
    DEST="$HOME/Applications/StatsPanel.app"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    TARGET="$DEST"
fi

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$TARGET" >/dev/null 2>&1 || true

open "$TARGET"
echo "Установлено и запущено: $TARGET"
