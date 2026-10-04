#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift test --package-path Packages/BouncerCore
Scripts/check-no-network.sh
xcodebuild -project TypoBouncer.xcodeproj -scheme TypoBouncer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData -resultBundlePath "build/Tests-$(date +%Y%m%d-%H%M%S).xcresult" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= test "$@"
