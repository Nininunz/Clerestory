#!/bin/bash
#
# Build a drag-to-Applications installer DMG for Clerestory.
#
# Usage: ./Scripts/make-dmg.sh [path to Clerestory.app]
# The default input is export/Clerestory.app from the archive export.
# Output is export/Clerestory-<VERSION>.dmg.
#
# Stage the app, Applications link, and background in a writable image.
# Finder applies the icon positions, sizes, and background before UDZO compression.
# The Finder step requires macOS Automation permission.
#
# This script preserves the app signature. make-release.sh signs, notarizes, and
# staples the final DMG after the Developer ID archive.
# DMG_LAYOUT_TEMPLATE can point to a prior DMG's .DS_Store. Use a layout that
# references Clerestory.app to create a compressed DMG without scripting Finder.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$REPO_ROOT/export/Clerestory.app}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo 1.0)"
DMG_NAME="Clerestory-$VERSION"
STAGE="$REPO_ROOT/export/dmg-stage"
RW_DMG="$REPO_ROOT/export/$DMG_NAME-rw.dmg"
FINAL_DMG="$REPO_ROOT/export/$DMG_NAME.dmg"
BACKGROUND_SRC="$REPO_ROOT/Scripts/dmg-background.png"

# Window and icon dimensions match generate-dmg-background.swift.
WIN_W=600; WIN_H=360
APP_X=140; APP_Y=165
ALIAS_X=460; ALIAS_Y=165
ICON_SIZE=128

if [ ! -d "$APP_PATH" ]; then
    echo "error: app not found at ${APP_PATH}（先 archive 导出或传入路径）" >&2
    exit 1
fi
if [ ! -f "$BACKGROUND_SRC" ]; then
    echo "生成背景图…"
    swift "$REPO_ROOT/Scripts/generate-dmg-background.swift"
fi
if [ -n "${DMG_LAYOUT_TEMPLATE:-}" ] && [ ! -f "$DMG_LAYOUT_TEMPLATE" ]; then
    echo "error: 安装包布局模板不存在：$DMG_LAYOUT_TEMPLATE" >&2
    exit 1
fi

echo "==> 准备 staging"
rm -rf "$STAGE"
mkdir -p "$STAGE/.background"
cp -R "$APP_PATH" "$STAGE/Clerestory.app"
ln -s /Applications "$STAGE/Applications"
cp "$BACKGROUND_SRC" "$STAGE/.background/background.png"

if [ -n "${DMG_LAYOUT_TEMPLATE:-}" ]; then
    echo "==> 复用安装包布局"
    cp "$DMG_LAYOUT_TEMPLATE" "$STAGE/.DS_Store"
    hdiutil create -srcfolder "$STAGE" -volname "Clerestory" -fs HFS+ \
        -format UDZO -imagekey zlib-level=9 -ov "$FINAL_DMG" >/dev/null
    rm -rf "$STAGE"
    echo "==> 完成：$FINAL_DMG"
    exit 0
fi

echo "==> 创建读写 DMG"
rm -f "$RW_DMG" "$FINAL_DMG"
hdiutil create -srcfolder "$STAGE" -volname "Clerestory" -fs HFS+ \
    -format UDRW -ov "$RW_DMG" >/dev/null

echo "==> 挂载"
MOUNT_DIR="$(hdiutil attach -readwrite -noverify "$RW_DMG" | tail -1 | sed -E 's/.*(\/Volumes\/.*)$/\1/')"
echo "    mounted at $MOUNT_DIR"

# Retry Finder layout once to recover from transient errors such as -1712.
# Abort if the retry fails to avoid releasing an unstyled installer.
echo "==> 设置窗口布局（可能弹「自动化」授权）"
layout_ok=0
for attempt in 1 2; do
    if osascript <<EOF 2>/dev/null
tell application "Finder"
    tell disk "Clerestory"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set pathbar visible of container window to false
        set the bounds of container window to {400, 200, 400 + $WIN_W, 200 + $WIN_H}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to $ICON_SIZE
        set background picture of viewOptions to file ".background:background.png"
        set position of item "Clerestory.app" of container window to {$APP_X, $APP_Y}
        set position of item "Applications" of container window to {$ALIAS_X, $ALIAS_Y}
        close
        open
        update without registering applications
        close
    end tell
end tell
EOF
    then
        layout_ok=1
        echo "    布局完成"
        break
    fi
    [ "$attempt" -eq 1 ] && { echo "    布局失败，5s 后重试…" >&2; sleep 5; }
done
if [ "$layout_ok" -ne 1 ]; then
    echo "error: Finder 布局连续失败，已中止（检查「自动化」授权或手动重跑）" >&2
    hdiutil detach "$MOUNT_DIR" -quiet || true
    exit 1
fi

echo "==> 卸载并压缩"
hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL_DMG" >/dev/null
rm -f "$RW_DMG"
rm -rf "$STAGE"

echo "==> 完成：$FINAL_DMG"
hdiutil imageinfo "$FINAL_DMG" | grep -E 'Format:|Compressed Size' || true
