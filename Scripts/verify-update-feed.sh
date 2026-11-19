#!/bin/bash
# Verify the appcast and its download without publishing changes. Check the DMG
# length and Ed25519 signature, app version, and Sparkle helper signing boundaries.
# Usage: verify-update-feed.sh [APPCAST_URL_OR_PATH] [EXPECTED_VERSION]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-https://nininunz.github.io/Clerestory/appcast.xml}"
EXPECTED_VERSION="${2:-}"
WORK_DIR="$(mktemp -d /tmp/clerestory-feed-verify.XXXXXX)"
MOUNT_DIR="$WORK_DIR/mount"
MOUNTED=0

cleanup() {
    if [ "$MOUNTED" -eq 1 ]; then
        hdiutil detach "$MOUNT_DIR" -quiet || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

APPCAST_PATH="$WORK_DIR/appcast.xml"
if [[ "$SOURCE" == http://* || "$SOURCE" == https://* ]]; then
    echo "==> Download appcast: $SOURCE"
    curl --fail --location --silent --show-error "$SOURCE" --output "$APPCAST_PATH"
else
    cp "$SOURCE" "$APPCAST_PATH"
fi
xmllint --noout "$APPCAST_PATH"

IFS=$'\t' read -r FEED_VERSION FEED_BUILD ENCLOSURE_URL ED_SIGNATURE DECLARED_LENGTH < <(
    python3 - "$APPCAST_PATH" <<'PYEOF'
import sys
import xml.etree.ElementTree as ET

ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
root = ET.parse(sys.argv[1]).getroot()
item = root.find("./channel/item")
if item is None:
    raise SystemExit("The appcast contains no release entries.")
version = item.findtext("sparkle:shortVersionString", namespaces=ns) or ""
build = item.findtext("sparkle:version", namespaces=ns) or ""
enclosure = item.find("enclosure")
if enclosure is None:
    raise SystemExit("The latest appcast entry has no enclosure.")
signature = enclosure.get(f"{{{ns['sparkle']}}}edSignature", "")
print("\t".join([version, build, enclosure.get("url", ""), signature,
                 enclosure.get("length", "")]))
PYEOF
)

if [ -z "$FEED_VERSION" ] || [ -z "$FEED_BUILD" ] || [ -z "$ENCLOSURE_URL" ] \
    || [ -z "$ED_SIGNATURE" ] || [ -z "$DECLARED_LENGTH" ]; then
    echo "error: The latest appcast entry is missing the version, URL, signature, or length." >&2
    exit 1
fi
if [ -n "$EXPECTED_VERSION" ] && [ "$FEED_VERSION" != "$EXPECTED_VERSION" ]; then
    echo "error: Expected feed version ${EXPECTED_VERSION}, found ${FEED_VERSION}." >&2
    exit 1
fi
if [[ ! "$DECLARED_LENGTH" =~ ^[0-9]+$ ]]; then
    echo "error: The enclosure length must be numeric." >&2
    exit 1
fi

DMG_PATH="$WORK_DIR/Clerestory-$FEED_VERSION.dmg"
echo "==> Download $FEED_VERSION ($FEED_BUILD)"
curl --fail --location --silent --show-error "$ENCLOSURE_URL" --output "$DMG_PATH"
ACTUAL_LENGTH="$(stat -f '%z' "$DMG_PATH")"
if [ "$ACTUAL_LENGTH" != "$DECLARED_LENGTH" ]; then
    echo "error: DMG length mismatch. Feed: ${DECLARED_LENGTH}. Actual: ${ACTUAL_LENGTH}." >&2
    exit 1
fi

# Wrap Sparkle's raw 32-byte Ed25519 public key in SPKI DER so OpenSSL can
# verify the appcast enclosure signature.
TRUSTED_KEY="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$REPO_ROOT/Clerestory/App/Info.plist")"
printf '302a300506032b6570032100' | xxd -r -p >"$WORK_DIR/public.der"
printf '%s' "$TRUSTED_KEY" | base64 -D >>"$WORK_DIR/public.der"
printf '%s' "$ED_SIGNATURE" | base64 -D >"$WORK_DIR/signature.bin"
if ! openssl pkeyutl -verify -pubin -keyform DER \
    -inkey "$WORK_DIR/public.der" -rawin -in "$DMG_PATH" \
    -sigfile "$WORK_DIR/signature.bin" >/dev/null; then
    echo "error: Sparkle Ed25519 signature verification failed." >&2
    exit 1
fi

mkdir "$MOUNT_DIR"
hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIR" -quiet
MOUNTED=1
APP_PATH="$MOUNT_DIR/Clerestory.app"
if [ ! -d "$APP_PATH" ]; then
    # Published builds up to 1.0.2 still contain the old bundle filename.
    APP_PATH="$MOUNT_DIR/OpenYoink.app"
fi
if [ ! -d "$APP_PATH" ]; then
    echo "error: DMG does not contain Clerestory.app or OpenYoink.app." >&2
    exit 1
fi

DOWNLOADED_KEY="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$APP_PATH/Contents/Info.plist")"
if [ "$DOWNLOADED_KEY" != "$TRUSTED_KEY" ]; then
    echo "error: The app in the DMG uses a different Sparkle public key from the repository." >&2
    exit 1
fi

SIGN_INFO="$(codesign -dvvv "$APP_PATH" 2>&1)"
MODE="developer-id"
if printf '%s\n' "$SIGN_INFO" | grep -Fq 'Signature=adhoc'; then
    MODE="adhoc"
fi
"$REPO_ROOT/Scripts/verify-distribution.sh" \
    "$APP_PATH" "$MODE" "$FEED_VERSION" "$FEED_BUILD"

echo "Verified the update feed end to end: $FEED_VERSION ($FEED_BUILD), $ACTUAL_LENGTH bytes"
