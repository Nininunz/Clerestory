#!/bin/bash
#
# Submit a signed Clerestory artifact to Apple and staple the notarization ticket.
#
# Prerequisites
#   xcrun notarytool store-credentials <profile-name> ...
#   export NOTARY_PROFILE=<profile-name>
#
# Usage: ./Scripts/notarize.sh export/Clerestory-1.0.5.dmg
# Developer ID-signed .app and .pkg inputs are also supported. This script preserves
# the existing signatures.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -f "$REPO_ROOT/Scripts/release-signing.local" ]; then
    source "$REPO_ROOT/Scripts/release-signing.local"
fi

ARTIFACT_PATH="${1:-}"
if [ -z "$ARTIFACT_PATH" ] || [ ! -e "$ARTIFACT_PATH" ]; then
    echo "error: Usage: $0 <signed .dmg|.app|.pkg>" >&2
    exit 1
fi
if [ -z "${NOTARY_PROFILE:-}" ]; then
    echo "error: NOTARY_PROFILE is missing. Store credentials with notarytool store-credentials first." >&2
    exit 1
fi

SUBMISSION_PATH="$ARTIFACT_PATH"
NOTARY_TEMP_DIR=""
NOTARY_RESULT="$(mktemp /tmp/clerestory-notary-result.XXXXXX)"
case "$ARTIFACT_PATH" in
    *.app)
        # Submit an app in a temporary ZIP and staple the ticket to the original app.
        NOTARY_TEMP_DIR="$(mktemp -d /tmp/clerestory-notary.XXXXXX)"
        SUBMISSION_PATH="$NOTARY_TEMP_DIR/Clerestory.zip"
        ditto -c -k --keepParent "$ARTIFACT_PATH" "$SUBMISSION_PATH"
        ;;
    *.dmg|*.pkg) ;;
    *)
        echo "error: Only .dmg, .app, and .pkg files are supported." >&2
        exit 1
        ;;
esac

cleanup() {
    rm -f -- "$NOTARY_RESULT"
    if [ -n "$NOTARY_TEMP_DIR" ] && [[ "$NOTARY_TEMP_DIR" == /tmp/clerestory-notary.* ]]; then
        rm -rf -- "$NOTARY_TEMP_DIR"
    fi
}
trap cleanup EXIT

echo "==> Submit to Apple for notarization: $SUBMISSION_PATH"
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

echo "==> Staple and validate the ticket: $ARTIFACT_PATH"
xcrun stapler staple "$ARTIFACT_PATH"
xcrun stapler validate "$ARTIFACT_PATH"

case "$ARTIFACT_PATH" in
    *.app) spctl --assess --type execute -vv "$ARTIFACT_PATH" ;;
    *.dmg) spctl --assess --type open --context context:primary-signature -vv "$ARTIFACT_PATH" ;;
    *.pkg) spctl --assess --type install -vv "$ARTIFACT_PATH" ;;
esac

echo "Notarization complete: $ARTIFACT_PATH"
