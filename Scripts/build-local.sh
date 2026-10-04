#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Installable local builds use an existing certificate. No account access,
# certificate creation, automatic provisioning, or ad-hoc fallback.
if [[ ! -f Config/Signing.local.xcconfig ]]; then
  echo 'Configure Config/Signing.local.xcconfig from its example before building for installation.' >&2
  exit 1
fi
xcodebuild -project TypoBouncer.xcodeproj -scheme TypoBouncer \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/LocalDerivedData \
  -xcconfig Config/Signing.local.xcconfig \
  CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS=--timestamp=none build "$@"
Scripts/verify-local-signing.sh build/LocalDerivedData/Build/Products/Debug/TypoBouncer.app
