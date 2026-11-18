#!/bin/bash
#
# notarize.sh — 用 Apple notarytool 公证并装订 OpenYoink 分发产物。
#
# 前置条件：
#   xcrun notarytool store-credentials <profile-name> ...
#   export NOTARY_PROFILE=<profile-name>
#
# 用法：
#   ./Scripts/notarize.sh export/OpenYoink-1.0.2.dmg
#   也支持已完成 Developer ID 签名的 .app / .pkg；本脚本不会重签任何组件。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$REPO_ROOT/Scripts/release-signing.local" ]; then
    source "$REPO_ROOT/Scripts/release-signing.local"
fi

ARTIFACT_PATH="${1:-}"
if [ -z "$ARTIFACT_PATH" ] || [ ! -e "$ARTIFACT_PATH" ]; then
    echo "error: 用法：$0 <已签名的 .dmg|.app|.pkg>" >&2
    exit 1
fi
if [ -z "${NOTARY_PROFILE:-}" ]; then
    echo "error: 缺少 NOTARY_PROFILE（先用 notarytool store-credentials 保存凭据）。" >&2
    exit 1
fi

SUBMISSION_PATH="$ARTIFACT_PATH"
NOTARY_TEMP_DIR=""
NOTARY_RESULT="$(mktemp /tmp/openyoink-notary-result.XXXXXX)"
case "$ARTIFACT_PATH" in
    *.app)
        # notarytool 不直接接受 .app；仅为提交生成临时 zip，票据仍装订回 app。
        NOTARY_TEMP_DIR="$(mktemp -d /tmp/openyoink-notary.XXXXXX)"
        SUBMISSION_PATH="$NOTARY_TEMP_DIR/OpenYoink.zip"
        ditto -c -k --keepParent "$ARTIFACT_PATH" "$SUBMISSION_PATH"
        ;;
    *.dmg|*.pkg) ;;
    *)
        echo "error: 仅支持 .dmg、.app 或 .pkg。" >&2
        exit 1
        ;;
esac

cleanup() {
    rm -f -- "$NOTARY_RESULT"
    if [ -n "$NOTARY_TEMP_DIR" ] && [[ "$NOTARY_TEMP_DIR" == /tmp/openyoink-notary.* ]]; then
        rm -rf -- "$NOTARY_TEMP_DIR"
    fi
}
trap cleanup EXIT

echo "==> 提交 Apple 公证：$SUBMISSION_PATH"
xcrun notarytool submit "$SUBMISSION_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json > "$NOTARY_RESULT"
cat "$NOTARY_RESULT"
NOTARY_STATUS="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"])' "$NOTARY_RESULT")"
if [ "$NOTARY_STATUS" != "Accepted" ]; then
    SUBMISSION_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$NOTARY_RESULT")"
    echo "error: Apple notarization status: $NOTARY_STATUS ($SUBMISSION_ID)" >&2
    xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" || true
    exit 1
fi

echo "==> 装订并验证票据：$ARTIFACT_PATH"
xcrun stapler staple "$ARTIFACT_PATH"
xcrun stapler validate "$ARTIFACT_PATH"

case "$ARTIFACT_PATH" in
    *.app) spctl --assess --type execute -vv "$ARTIFACT_PATH" ;;
    *.dmg) spctl --assess --type open --context context:primary-signature -vv "$ARTIFACT_PATH" ;;
    *.pkg) spctl --assess --type install -vv "$ARTIFACT_PATH" ;;
esac

echo "公证完成：$ARTIFACT_PATH"
