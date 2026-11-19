#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${CLERESTORY_CI_OUTPUT:-$(mktemp -d "${TMPDIR:-/tmp}/clerestory-ci.XXXXXX")}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
cd "$repo_dir"
python3 Scripts/check-identity.py

echo "CI logs and results: $output_dir"
{
  sw_vers
  xcodebuild -version
  swift --version
} 2>&1 | tee "$output_dir/toolchain.log"

swift test --package-path Packages/ClerestoryModuleCore \
  --scratch-path "$output_dir/module-core" \
  2>&1 | tee "$output_dir/module-core.log"

common=(
  -project Clerestory.xcodeproj
  -scheme Clerestory
  -destination "platform=macOS,arch=$(uname -m)"
  -derivedDataPath "$output_dir/DerivedData"
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES
)

xcodebuild build "${common[@]}" -configuration Release \
  2>&1 | tee "$output_dir/release-build.log"

# App-hosted unit tests only. The native UI suite requires an interactive
# desktop; the preview catalog is an explicit artifact-export task.
xcodebuild test "${common[@]}" -configuration Debug \
  -only-testing:ClerestoryTests \
  -skip-testing:ClerestoryTests/IslandModulePreviewTests \
  -parallel-testing-enabled NO \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 120 \
  -resultBundlePath "$output_dir/unit-tests.xcresult" \
  2>&1 | tee "$output_dir/unit-tests.log"
