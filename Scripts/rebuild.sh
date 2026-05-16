#!/bin/bash
set -euo pipefail

# FontCopy 重建脚本
#
# 用固定的 Developer ID 证书签名，保证 macOS TCC（网络宗卷访问授权）
# 跨次启动被记住，只弹一次"允许"。
# 绝对不要回退到 `codesign --sign -`（ad-hoc），那样每次签名都变，
# TCC 认不出是同一个 App，会每次启动都重新弹窗。

SIGN_IDENTITY="Developer ID Application: Huang zhenning (PXYRA7322P)"
APP="dist/FontCopy.app"

cd "$(dirname "$0")/.."

echo "[1/4] 编译 release"
swift build -c release

echo "[2/4] 替换 app 内二进制"
osascript -e 'quit app "FontCopy"' 2>/dev/null || true
sleep 1
cp .build/release/FontCopy "$APP/Contents/MacOS/FontCopy"

echo "[3/4] 用 Developer ID 签名 (hardened runtime)"
codesign --force --deep --options runtime --timestamp \
    --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "[4/4] 启动"
open "$APP"
echo "完成。"
