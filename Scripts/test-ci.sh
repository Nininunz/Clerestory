#!/bin/bash
# Run the CI checks. With no argument, run every phase in order, as a local
# pre-merge check. CI runs one phase per job so the jobs can run in parallel.
#
# Usage: Scripts/test-ci.sh [all|identity|module-core|release|helper|unit-tests]
#
# CLERESTORY_CI_OUTPUT  Directory for logs and results (default: a new temp dir).
# CLERESTORY_RELEASE_BUILD
#   fast  Release configuration without optimization, for the current
#         architecture. Catches code that only compiles with DEBUG set.
#   full  Optimized Release build for Apple silicon and Intel, like a
#         shipped build. This is the default.
set -euo pipefail

phase="${1:-all}"
case "$phase" in
  all|identity|module-core|release|helper|unit-tests) ;;
  *) echo "usage: $0 [all|identity|module-core|release|helper|unit-tests]" >&2; exit 64 ;;
esac

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${CLERESTORY_CI_OUTPUT:-$(mktemp -d "${TMPDIR:-/tmp}/clerestory-ci.XXXXXX")}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
cd "$repo_dir"
echo "CI logs and results: $output_dir"

runs() { [ "$phase" = all ] || [ "$phase" = "$1" ]; }

if runs identity; then
  python3 Scripts/check-identity.py
fi

if runs module-core; then
  # Foundation-only package; CI runs this phase on Linux.
  swift --version 2>&1 | tee "$output_dir/module-core-toolchain.log"
  swift test --package-path Packages/ClerestoryModuleCore \
    --scratch-path "$output_dir/module-core" \
    2>&1 | tee "$output_dir/module-core.log"
fi

if runs release || runs unit-tests; then
  {
    sw_vers
    xcodebuild -version
  } 2>&1 | tee "$output_dir/toolchain.log"
fi

common=(
  -project Clerestory.xcodeproj
  -scheme Clerestory
  -derivedDataPath "$output_dir/DerivedData"
  -onlyUsePackageVersionsFromResolvedFile
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES
)

if runs release; then
  case "${CLERESTORY_RELEASE_BUILD:-full}" in
    fast)
      release=(
        -destination "platform=macOS,arch=$(uname -m)" ONLY_ACTIVE_ARCH=YES
        SWIFT_OPTIMIZATION_LEVEL=-Onone SWIFT_COMPILATION_MODE=incremental
        DEBUG_INFORMATION_FORMAT=dwarf
      )
      ;;
    full) release=(-destination "generic/platform=macOS") ;;
    *) echo "error: CLERESTORY_RELEASE_BUILD must be fast or full" >&2; exit 64 ;;
  esac
  echo "==> Release build (${CLERESTORY_RELEASE_BUILD:-full})"
  xcodebuild build "${common[@]}" "${release[@]}" -configuration Release \
    2>&1 | tee "$output_dir/release-build.log"
fi

if runs helper; then
  # Build the Low Power Mode helper and an unsigned package with an ad-hoc
  # signature, then check the package contents. Release packages are signed
  # and notarized by make-release.sh.
  echo "==> Low Power Mode helper"
  {
    Scripts/build-low-power-mode-helper.sh - "$output_dir/helper"
    pkgutil --expand-full "$output_dir/helper/ClerestoryLowPowerMode.pkg" "$output_dir/helper/expanded"
    payload="$output_dir/helper/expanded/Payload"
    service=com.nininunz.Clerestory.LowPowerMode
    archs="$(lipo -archs "$payload/Library/PrivilegedHelperTools/$service")"
    echo "Helper architectures: $archs"
    # Exit explicitly: bash 3.2's set -e ignores a failed [[ ]] test.
    if [[ " $archs " != *" arm64 "* || " $archs " != *" x86_64 "* ]]; then
      echo "error: the helper must be built for arm64 and x86_64" >&2
      exit 1
    fi
    plutil -lint "$payload/Library/LaunchDaemons/$service.plist"
    test -x "$output_dir/helper/expanded/Scripts/postinstall"
  } 2>&1 | tee "$output_dir/helper.log"
fi

if runs unit-tests; then
  # App-hosted unit tests only. The native UI suite requires an interactive
  # desktop; the preview catalog is an explicit artifact-export task. Test
  # classes run in parallel across three workers, one per CI runner core.
  xcodebuild test "${common[@]}" -configuration Debug \
    -destination "platform=macOS,arch=$(uname -m)" \
    -only-testing:ClerestoryTests \
    -skip-testing:ClerestoryTests/IslandModulePreviewTests \
    -parallel-testing-enabled YES \
    -parallel-testing-worker-count 3 \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 60 \
    -maximum-test-execution-time-allowance 120 \
    -resultBundlePath "$output_dir/unit-tests.xcresult" \
    2>&1 | tee "$output_dir/unit-tests.log"
fi
