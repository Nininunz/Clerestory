#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
derived_data="${OPENYOINK_UI_DERIVED_DATA:-$(mktemp -d /tmp/openyoink-ui.XXXXXX)}"
common=(
  -project "$repo_dir/Open-Yoink.xcodeproj"
  -scheme Clerestory
  -destination "platform=macOS,arch=$(uname -m)"
  -derivedDataPath "$derived_data"
  -only-testing:ClerestoryUITests
  -parallel-testing-enabled NO
  -test-timeouts-enabled YES
  -default-test-execution-time-allowance 60
  -maximum-test-execution-time-allowance 90
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES
)

echo "UI-test build and results: $derived_data"
# Unlike app/unit tests, the native UI runner needs its generated bundle signed.
# Disabling signing leaves Xcode's runner signature invalid after packaging.
xcodebuild build-for-testing "${common[@]}"
codesign --verify --deep --strict "$derived_data/Build/Products/Debug/ClerestoryUITests-Runner.app"
codesign --verify --deep --strict "$derived_data/Build/Products/Debug/Clerestory.app"
codesign --verify --deep --strict "$derived_data/Build/Products/Debug/ClerestoryUITestDragSource.app"
# Native UI automation requires an awake desktop for the duration of the run.
caffeinate -di xcodebuild test-without-building "${common[@]}"
