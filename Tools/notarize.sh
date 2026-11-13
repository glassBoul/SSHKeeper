#!/usr/bin/env bash
# 把已签名的 DMG 提交给 Apple Notary Service 并 staple ticket。
#
# 必须的环境变量（也可在 .env 中加载）：
#   NOTARY_PROFILE          先用一次性命令存好 keychain profile：
#                              xcrun notarytool store-credentials NOTARY_PROFILE \
#                                  --apple-id you@apple.com \
#                                  --team-id ABCD1234 \
#                                  --password app-specific-password
#                          之后这里只需要传 profile 名。
#
# 用法：
#   Tools/notarize.sh build/SSHKeeper.dmg

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
    # shellcheck disable=SC1091
    source .env
fi

if [[ $# -lt 1 ]]; then
    echo "用法：$0 <path-to-dmg-or-app>"
    exit 1
fi

TARGET="$1"
PROFILE="${NOTARY_PROFILE:-SSHKeeperNotary}"

if [[ ! -e "$TARGET" ]]; then
    echo "❌ 找不到：$TARGET"
    exit 1
fi

echo "-> 提交到 Apple Notary Service (profile: $PROFILE)..."
xcrun notarytool submit "$TARGET" \
    --keychain-profile "$PROFILE" \
    --wait

echo "-> Staple ticket..."
xcrun stapler staple "$TARGET"

echo "-> 验证:"
spctl --assess --type execute --verbose=4 "$TARGET" || true
xcrun stapler validate "$TARGET"

echo "✅ 公证完成：$TARGET"
