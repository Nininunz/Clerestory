#!/bin/bash
# Verify version metadata, signatures, and the Sparkle helper entitlement boundaries.
# Usage: verify-distribution.sh <Clerestory.app> <adhoc|developer-id> [VERSION] [BUILD]

set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 4 ]; then
    echo "Usage: $0 <Clerestory.app> <adhoc|developer-id> [VERSION] [BUILD]" >&2
    exit 1
fi

APP_PATH="$1"
RELEASE_MODE="$2"
EXPECTED_VERSION="${3:-}"
EXPECTED_BUILD="${4:-}"

if [ ! -d "$APP_PATH" ]; then
    echo "error: App not found: $APP_PATH" >&2
    exit 1
fi
APP_BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Contents/Info.plist")"
if [ "$RELEASE_MODE" != "adhoc" ] && [ "$RELEASE_MODE" != "developer-id" ]; then
    echo "error: Signing mode must be adhoc or developer-id." >&2
    exit 1
fi

SPARKLE_ROOT="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"
MEDIA_ROOT="$APP_PATH/Contents/Resources/MediaRemoteAdapterResources.bundle"
COMPONENTS=(
    "$MEDIA_ROOT/Contents/Resources/MediaRemoteAdapterTestClient"
    "$MEDIA_ROOT/Contents/Resources/MediaRemoteAdapter.framework"
    "$MEDIA_ROOT"
    "$SPARKLE_ROOT/XPCServices/Installer.xpc"
    "$SPARKLE_ROOT/XPCServices/Downloader.xpc"
    "$SPARKLE_ROOT/Autoupdate"
    "$SPARKLE_ROOT/Updater.app"
    "$APP_PATH/Contents/Frameworks/Sparkle.framework"
    "$APP_PATH"
)

for component in "${COMPONENTS[@]}"; do
    if [ ! -e "$component" ]; then
        echo "error: Missing Sparkle release component: $component" >&2
        exit 1
    fi
    codesign --verify --strict --verbose=2 "$component"

    SIGN_INFO="$(codesign -dvvv "$component" 2>&1)"
    if [ "$RELEASE_MODE" = "adhoc" ]; then
        if ! printf '%s\n' "$SIGN_INFO" | grep -Fq 'Signature=adhoc'; then
            echo "error: Component lacks an ad hoc signature: $component" >&2
            exit 1
        fi
        if printf '%s\n' "$SIGN_INFO" | grep -Eq 'flags=.*runtime'; then
            echo "error: Ad hoc component still has Hardened Runtime enabled: $component" >&2
            exit 1
        fi
    else
        if printf '%s\n' "$SIGN_INFO" | grep -Fq 'Signature=adhoc'; then
            echo "error: Developer ID build contains an ad hoc component: $component" >&2
            exit 1
        fi
        if ! printf '%s\n' "$SIGN_INFO" | grep -Eq 'flags=.*runtime'; then
            echo "error: Developer ID component lacks Hardened Runtime: $component" >&2
            exit 1
        fi
    fi
done

ENTITLEMENTS_DIR="$(mktemp -d /tmp/openyoink-verify.XXXXXX)"
trap 'rm -rf "$ENTITLEMENTS_DIR"' EXIT

for component in "${COMPONENTS[@]}"; do
    file="$ENTITLEMENTS_DIR/$(printf '%s' "$component" | shasum | cut -d' ' -f1).plist"
    codesign -d --entitlements :- "$component" >"$file" 2>/dev/null || true
    if grep -Fq '$(PRODUCT_BUNDLE_IDENTIFIER)' "$file"; then
        echo "error: Signed entitlements contain an unexpanded build variable: $component" >&2
        exit 1
    fi
done

# Signing with --deep previously propagated the app's sandbox and application ID
# to Installer and Updater. Sparkle's helpers need to retain their own entitlements.
for helper in "$SPARKLE_ROOT/XPCServices/Installer.xpc" "$SPARKLE_ROOT/Updater.app"; do
    file="$ENTITLEMENTS_DIR/$(printf '%s' "$helper" | shasum | cut -d' ' -f1).plist"
    if [ "$(plutil -extract com.apple.security.app-sandbox raw -o - "$file" 2>/dev/null || true)" = "true" ]; then
        echo "error: Sparkle helper inherited the main app sandbox entitlement: $helper" >&2
        exit 1
    fi
    if grep -Fq "$APP_BUNDLE_IDENTIFIER" "$file"; then
        echo "error: Sparkle helper inherited the main app application identifier: $helper" >&2
        exit 1
    fi
done

MAIN_ENTITLEMENTS="$ENTITLEMENTS_DIR/$(printf '%s' "$APP_PATH" | shasum | cut -d' ' -f1).plist"
if [ "$(plutil -extract com.apple.security.get-task-allow raw -o - "$MAIN_ENTITLEMENTS" 2>/dev/null || true)" = "true" ]; then
    echo "error: The Release app contains the get-task-allow debugging entitlement." >&2
    exit 1
fi

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
if [ -n "$EXPECTED_VERSION" ] && [ "$SHORT_VERSION" != "$EXPECTED_VERSION" ]; then
    echo "error: Expected version ${EXPECTED_VERSION}, found ${SHORT_VERSION}." >&2
    exit 1
fi
if [ -n "$EXPECTED_BUILD" ] && [ "$BUNDLE_VERSION" != "$EXPECTED_BUILD" ]; then
    echo "error: Expected build ${EXPECTED_BUILD}, found ${BUNDLE_VERSION}." >&2
    exit 1
fi

echo "Verified Clerestory $SHORT_VERSION ($BUNDLE_VERSION) in $RELEASE_MODE mode."
