#!/bin/sh
# Build ClerestoryLowPowerMode.pkg, the optional system helper that lets the
# Battery module toggle Low Power Mode. The package installs the helper as a
# LaunchDaemon and loads it. See docs/LOW_POWER_MODE_HELPER.md.
#
# Usage: build-low-power-mode-helper.sh 'Developer ID Application: …' output-directory ['Developer ID Installer: …']
#   The application identity signs the helper. The optional installer identity
#   signs the package, which notarization requires; without it the package is
#   unsigned and only suitable for local testing.
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "Usage: $0 'Developer ID Application: ...' output-directory ['Developer ID Installer: ...']" >&2
    exit 64
fi

repo=$(cd "$(dirname "$0")/.." && pwd)
identity=$1
installer_identity=${3:-}
mkdir -p "$2"
output=$(cd "$2" && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
service=com.nininunz.Clerestory.LowPowerMode
version=$(sed -n 's/^MARKETING_VERSION *= *//p' "$repo/Version.xcconfig")
binary="$stage/root/Library/PrivilegedHelperTools/$service"
mkdir -p "$(dirname "$binary")" "$stage/root/Library/LaunchDaemons" "$stage/scripts"

xcrun clang -Wall -Wextra -Werror -fblocks -mmacosx-version-min=15 \
    -arch arm64 -arch x86_64 -framework CoreFoundation -framework IOKit \
    "$repo/Helpers/LowPowerMode/main.c" -o "$binary"
codesign --force --options runtime --timestamp --identifier "$service" --sign "$identity" "$binary"
codesign --verify --strict -R="anchor apple generic and identifier \"$service\" and certificate leaf[subject.OU] = \"8KB55P2YKQ\"" "$binary"
install -m 644 "$repo/Helpers/LowPowerMode/$service.plist" "$stage/root/Library/LaunchDaemons/$service.plist"
plutil -lint "$stage/root/Library/LaunchDaemons/$service.plist"

# Load the daemon after installing. A reinstall or upgrade replaces the
# running copy, so unload it first; that fails harmlessly on a first install.
cat > "$stage/scripts/postinstall" <<SCRIPT
#!/bin/sh
/bin/launchctl bootout system/$service 2>/dev/null || true
/bin/launchctl bootstrap system /Library/LaunchDaemons/$service.plist
SCRIPT
chmod 755 "$stage/scripts/postinstall"

set -- --root "$stage/root" --scripts "$stage/scripts" --install-location / \
    --ownership recommended --identifier "$service" --version "${version:-1}"
if [ -n "$installer_identity" ]; then
    set -- "$@" --sign "$installer_identity" --timestamp
fi
pkgbuild "$@" "$output/ClerestoryLowPowerMode.pkg"
echo "Built $output/ClerestoryLowPowerMode.pkg (version ${version:-1})"
