#!/usr/bin/env bash
# 打包 Release: archive → export (Developer ID) → DMG
#
# 必须配置的环境变量（也可在 .env 中加载）：
#   DEVELOPMENT_TEAM        Apple Developer Team ID（10 位字符）
#
# 可选环境变量：
#   APP_NAME                默认 SSHKeeper
#   BUILD_DIR               默认 ./build
#   SCHEME                  默认 SSHKeeper
#
# 通知公证（notarization）请在打完 DMG 后另跑 Tools/notarize.sh。

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
    # shellcheck disable=SC1091
    source .env
fi

APP_NAME="${APP_NAME:-SSHKeeper}"
SCHEME="${SCHEME:-SSHKeeper}"
BUILD_DIR="${BUILD_DIR:-build}"

if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
    echo "❌ DEVELOPMENT_TEAM 未设置（需要 Developer ID Team ID）"
    exit 1
fi

mkdir -p "$BUILD_DIR"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"

echo "→ 重新生成 Xcode 工程..."
xcodegen generate >/dev/null

echo "→ Archive..."
rm -rf "$ARCHIVE"
xcodebuild archive \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"

echo "→ Export Developer ID..."
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist Tools/exportOptions.plist \
    -exportPath "$EXPORT_DIR"

EXPORTED_APP="$EXPORT_DIR/$APP_NAME.app"
if [[ ! -d "$EXPORTED_APP" ]]; then
    echo "❌ 导出失败：找不到 $EXPORTED_APP"
    exit 1
fi

echo "→ 创建 DMG..."
rm -f "$DMG_PATH"
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$EXPORTED_APP" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

rm -rf "$DMG_STAGING"

echo "✅ 完成：$DMG_PATH"
echo "下一步：Tools/notarize.sh \"$DMG_PATH\""
