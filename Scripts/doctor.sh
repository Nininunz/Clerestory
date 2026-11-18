#!/bin/bash
set -eo pipefail

usage() {
    printf '%s\n' \
        'Usage: Scripts/doctor.sh [--release]' \
        'Check the local macOS build and test toolchain.' \
        'With --release, also check Developer ID signing, Sparkle tools, and Apple notarization access.'
}

case "${1:-}" in
    "") [[ $# -eq 0 ]] || { usage >&2; exit 2; } ;;
    --release) [[ $# -eq 1 ]] || { usage >&2; exit 2; } ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."
failed=0

pass() {
    printf 'OK   %s\n' "$1"
}

fail() {
    printf 'FAIL %s\n' "$1"
    failed=1
}

check_command() {
    if command -v "$1" >/dev/null 2>&1; then
        pass "$1 is available"
    else
        fail "$1 is unavailable. $2"
    fi
}

check_toolchain() {
    local version swift_version sdk_version
    if version=$(xcodebuild -version 2>/dev/null) &&
       [[ "$version" =~ ^Xcode[[:space:]]+([0-9]+) ]] &&
       (( BASH_REMATCH[1] >= 26 )); then
        pass "${version%%$'\n'*}"
        if xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
            pass 'Xcode first-launch setup is complete'
        else
            fail 'Open Xcode once to finish setup, or run sudo xcodebuild -runFirstLaunch.'
        fi
    else
        fail 'Xcode 26 or newer is required. Set DEVELOPER_DIR or select Xcode with xcode-select.'
    fi

    if sdk_version=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null); then
        pass "macOS SDK $sdk_version"
    else
        fail 'The selected Xcode could not locate a macOS SDK.'
    fi
    if swift_version=$(swift --version 2>/dev/null) &&
       [[ "$swift_version" =~ Swift[[:space:]]version[[:space:]]([0-9]+) ]] &&
       (( BASH_REMATCH[1] >= 6 )); then
        pass "${swift_version%%$'\n'*}"
    else
        fail 'Swift 6 or newer is required on PATH.'
    fi

    check_command git 'Install Git or the Xcode command line tools.'
    check_command python3 'Install Python 3 or the Xcode command line tools.'
    check_command caffeinate 'Native UI tests require the macOS caffeinate command.'
}

check_release() {
    local node_version identities sparkle_bin name candidate
    if [[ -f Scripts/release-signing.local ]] && ! source Scripts/release-signing.local >/dev/null 2>&1; then
        fail 'Could not load Scripts/release-signing.local.'
    fi

    if node_version=$(node --version 2>/dev/null) &&
       [[ "$node_version" =~ ^v([0-9]+)\. ]] &&
       (( BASH_REMATCH[1] >= 18 )); then
        pass "Node.js $node_version"
    else
        fail 'Node.js 18 or newer is required for the release README update.'
    fi
    check_command codesign 'Install the macOS signing tools.'
    check_command hdiutil 'The macOS hdiutil command is required to create DMGs.'

    for name in DEVELOPER_ID_APPLICATION DEVELOPMENT_TEAM_ID NOTARY_PROFILE; do
        if [[ -z "${!name:-}" ]]; then
            fail "$name is missing. Set it in the environment or Scripts/release-signing.local."
        fi
    done
    if [[ -n "${DEVELOPMENT_TEAM_ID:-}" && ! "$DEVELOPMENT_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
        fail 'DEVELOPMENT_TEAM_ID must contain 10 uppercase letters or digits.'
    fi
    if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
        if identities=$(security find-identity -v -p codesigning 2>/dev/null) &&
           [[ "$identities" == *"$DEVELOPER_ID_APPLICATION"* ]]; then
            pass 'Configured Developer ID Application signing identity is available'
        else
            fail 'The configured Developer ID Application signing identity is unavailable in Keychain.'
        fi
    fi

    sparkle_bin=${SPARKLE_BIN:-}
    if [[ -z "$sparkle_bin" ]]; then
        for candidate in "$HOME"/Library/Developer/Xcode/DerivedData/{Clerestory,Open-Yoink}-*/SourcePackages/artifacts/sparkle/Sparkle/bin; do
            if [[ -x "$candidate/sign_update" ]]; then
                sparkle_bin=$candidate
                break
            fi
        done
    fi
    if [[ -x "$sparkle_bin/sign_update" ]]; then
        pass 'Sparkle sign_update is available'
    else
        fail 'Sparkle sign_update is unavailable. Resolve Xcode packages or set SPARKLE_BIN.'
    fi

    if ! xcrun --find notarytool >/dev/null 2>&1 || ! xcrun --find stapler >/dev/null 2>&1; then
        fail 'The selected Xcode must provide notarytool and stapler.'
    elif [[ -n "${NOTARY_PROFILE:-}" ]]; then
        printf '%s\n' '     Checking notarization access with Apple…'
        if python3 - "$NOTARY_PROFILE" >/dev/null 2>&1 <<'PY'
import subprocess
import sys

subprocess.run(
    ["xcrun", "notarytool", "history", "--keychain-profile", sys.argv[1]],
    timeout=30,
    check=True,
)
PY
        then
            pass 'Apple accepted the configured notarization profile'
        else
            fail 'Could not verify notarization access. Check network access and the Keychain profile.'
        fi
    fi
}

check_toolchain
if [[ "${1:-}" == --release ]]; then
    check_release
fi
exit "$failed"
