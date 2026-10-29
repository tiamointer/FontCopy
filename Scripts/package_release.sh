#!/bin/bash
set -euo pipefail

# FontCopy 发布打包：编译 → 签名 → 公证 → 装订 → 出 DMG（再签名公证装订）。
# 产物 dist/FontCopy-v<版本>.dmg 可在其他 Mac 上直接打开安装，不会被 Gatekeeper 拦。
#
# 复用 CutPalette 已配置的公证凭据（同一开发者账号，notarytool profile 是账号级）。

SIGN_IDENTITY="Developer ID Application: Huang zhenning (PXYRA7322P)"
NOTARY_PROFILE="CutPalette-AC"
APP="dist/FontCopy.app"

cd "$(dirname "$0")/.."

# 版本号唯一来源 = VERSION 文件。可传参覆盖（如 ./package_release.sh 2.0.0）。
# 打包成功后自动把补丁号 +1 写回 VERSION，下次打包自然递增、无需手动记。
VERSION="${1:-$(cat VERSION)}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "✗ 版本号格式应为 x.y.z，当前: $VERSION" >&2
    exit 1
fi
echo "$VERSION" > VERSION
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

DMG="dist/FontCopy-v${VERSION}.dmg"
ZIP="dist/FontCopy-notarize.zip"
echo "打包版本: $VERSION"

echo "[1/7] 编译 release"
swift build -c release
osascript -e 'quit app "FontCopy"' 2>/dev/null || true
sleep 1
cp .build/release/FontCopy "$APP/Contents/MacOS/FontCopy"

echo "[2/7] 签名 App（Developer ID + hardened runtime）"
codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "[3/7] 打包并提交 App 公证（等待 Apple 处理，可能数分钟）"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$ZIP"

echo "[4/7] 装订 App"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "[5/7] 生成 DMG（含 Applications 拖拽快捷方式）"
rm -f "$DMG"
PAYLOAD=$(mktemp -d)
ditto "$APP" "$PAYLOAD/FontCopy.app"
ln -s /Applications "$PAYLOAD/Applications"
hdiutil create -volname "FontCopy v$VERSION" -srcfolder "$PAYLOAD" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$PAYLOAD"

echo "[6/7] 签名 + 公证 + 装订 DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "[7/7] 验证 Gatekeeper"
spctl -a -t open --context context:primary-signature -vv "$DMG" || true

# 打包成功，补丁号 +1 写回 VERSION，供下次自动递增
NEXT=$(echo "$VERSION" | awk -F. '{printf "%d.%d.%d", $1, $2, $3+1}')
echo "$NEXT" > VERSION
echo "完成：$DMG（VERSION 已自动递增为 $NEXT，供下次打包）"