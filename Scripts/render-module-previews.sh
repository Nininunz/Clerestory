#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild test -quiet -project Open-Yoink.xcodeproj -scheme OpenYoink \
  -destination 'platform=macOS' -derivedDataPath /tmp/openyoink-derived \
  -only-testing:OpenYoinkTests/IslandModulePreviewTests CODE_SIGNING_ALLOWED=NO
open /tmp/openyoink-module-previews/index.html
