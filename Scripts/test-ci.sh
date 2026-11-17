#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${OPENYOINK_CI_OUTPUT:-$(mktemp -d "${TMPDIR:-/tmp}/openyoink-ci.XXXXXX")}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
cd "$repo_dir"

echo "CI logs and results: $output_dir"
{
  sw_vers
  xcodebuild -version
  swift --version
} 2>&1 | tee "$output_dir/toolchain.log"

swift test --package-path Packages/OpenYoinkModuleCore \
  --scratch-path "$output_dir/module-core" \
  2>&1 | tee "$output_dir/module-core.log"

common=(
  -project Open-Yoink.xcodeproj
  -scheme OpenYoink
  -destination "platform=macOS,arch=$(uname -m)"
  -derivedDataPath "$output_dir/DerivedData"
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES
)

xcodebuild build "${common[@]}" -configuration Release \
  2>&1 | tee "$output_dir/release-build.log"

# App-hosted unit tests only. The native UI suite requires an interactive
# desktop; the preview catalog is an explicit artifact-export task.
xcodebuild test "${common[@]}" -configuration Debug \
  -only-testing:OpenYoinkTests \
  -skip-testing:OpenYoinkTests/IslandModulePreviewTests \
  -parallel-testing-enabled NO \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 120 \
  -resultBundlePath "$output_dir/unit-tests.xcresult" \
  2>&1 | tee "$output_dir/unit-tests.log"
