#!/usr/bin/env bash
set -euo pipefail

APP_NAME="FontCopy"
BUNDLE_ID="com.laike.FontCopy"
MIN_SYSTEM_VERSION="14.0"
APP_VERSION="${APP_VERSION:-1.0.0}"

INSTALL=0
SKIP_DMG=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --no-dmg)  SKIP_DMG=1 ;;
    -h|--help)
      echo "usage: $0 [--install] [--no-dmg]"
      echo "  --install  copy built .app to /Applications and clear quarantine"
      echo "  --no-dmg   skip DMG creation (faster when you only need --install)"
      exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.icns"
DMG_PATH="$DIST_DIR/$APP_NAME-$APP_VERSION.dmg"

echo "==> swift build -c release (universal)"
MACOSX_DEPLOYMENT_TARGET="$MIN_SYSTEM_VERSION" \
  swift build -c release --arch arm64 --arch x86_64
BUILD_BINARY="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"

echo "==> assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
strip -x "$APP_BINARY" 2>/dev/null || true

if [ -f "$APP_ICON_SOURCE" ]; then
  cp "$APP_ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"
fi

echo "==> generating release notes"
NOTES_FILE="$APP_RESOURCES/ReleaseNotes.txt"
SIDECAR_NOTES="$DIST_DIR/$APP_NAME-$APP_VERSION.notes.txt"
PREV_TAG="$(git -C "$ROOT_DIR" tag -l 'v*' --sort=-v:refname 2>/dev/null | grep -v "^v$APP_VERSION$" | head -1 || true)"
if [ -n "$PREV_TAG" ]; then
  RANGE_DESC="自 $PREV_TAG 起"
  RAW_LOG="$(git -C "$ROOT_DIR" log "$PREV_TAG..HEAD" --no-merges --pretty=format:'- %s' 2>/dev/null || true)"
else
  RANGE_DESC="最近提交"
  RAW_LOG="$(git -C "$ROOT_DIR" log -20 --no-merges --pretty=format:'- %s' 2>/dev/null || true)"
fi
if [ -z "$RAW_LOG" ]; then
  RAW_LOG="- 此版本暂无可见提交说明。"
fi
DATE_LINE="$(date +%Y-%m-%d)"
{
  echo "FontCopy $APP_VERSION · $DATE_LINE"
  echo "($RANGE_DESC)"
  echo
  echo "$RAW_LOG"
} >"$NOTES_FILE"
cp "$NOTES_FILE" "$SIDECAR_NOTES"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleDisplayName</key>
  <string>FontCopy</string>
  <key>CFBundleName</key>
  <string>FontCopy</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" || true

if [ "$SKIP_DMG" -eq 0 ]; then
  echo "==> creating DMG"
  rm -f "$DMG_PATH"
  STAGE_DIR="$(mktemp -d)"
  cp -R "$APP_BUNDLE" "$STAGE_DIR/"
  ln -s /Applications "$STAGE_DIR/Applications"
  hdiutil create \
    -volname "$APP_NAME $APP_VERSION" \
    -srcfolder "$STAGE_DIR" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null
  rm -rf "$STAGE_DIR"
fi

if [ "$INSTALL" -eq 1 ]; then
  echo "==> installing to /Applications"
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
  xattr -dr com.apple.quarantine "/Applications/$APP_NAME.app" 2>/dev/null || true
fi

echo
echo "App:  $APP_BUNDLE"
[ "$SKIP_DMG" -eq 0 ] && echo "DMG:  $DMG_PATH"
[ "$INSTALL" -eq 1 ]  && echo "Installed: /Applications/$APP_NAME.app"
file "$APP_BINARY"
