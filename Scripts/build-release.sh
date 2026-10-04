#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
config=Config/Signing.release.local.xcconfig
if [[ ! -f "$config" ]]; then
  echo 'Configure Signing.release.local.xcconfig from its example with an existing Developer ID identity.' >&2
  exit 1
fi
read_setting() {
  awk -F= -v key="$1" '$1 ~ "^[[:space:]]*" key "[[:space:]]*$" { sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2); print $2; exit }' "$config"
}
team=$(read_setting DEVELOPMENT_TEAM)
identity=$(read_setting CODE_SIGN_IDENTITY)
if [[ ! "$team" =~ ^[A-Z0-9]{10}$ || ! "$identity" =~ ^[A-Fa-f0-9]{40}$ ]]; then
  echo 'Release signing config needs a ten-character Team ID and certificate SHA-1.' >&2
  exit 1
fi
if ! security find-identity -v -p codesigning | grep -E "$identity .*Developer ID Application:.*\($team\)" >/dev/null; then
  echo 'Configured Developer ID identity and private key are not available for this team.' >&2
  exit 1
fi
mkdir -p build/Release
xcodebuild -project TypoBouncer.xcodeproj -scheme TypoBouncer -configuration Release \
  -destination 'generic/platform=macOS' -archivePath build/Release/TypoBouncer.xcarchive \
  -derivedDataPath build/ReleaseDerivedData -xcconfig "$config" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ENABLE_HARDENED_RUNTIME=YES \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO OTHER_CODE_SIGN_FLAGS=--timestamp archive
python3 - "$team" "$identity" <<'PY'
import plistlib, sys
from pathlib import Path
options = plistlib.loads(Path('Config/ExportOptions.template.plist').read_bytes())
options.update(teamID=sys.argv[1], signingCertificate=sys.argv[2], destination='export')
Path('build/Release/ExportOptions.plist').write_bytes(plistlib.dumps(options))
PY
xcodebuild -exportArchive -archivePath build/Release/TypoBouncer.xcarchive \
  -exportOptionsPlist build/Release/ExportOptions.plist -exportPath build/Release/export
Scripts/verify-release.sh build/Release/export/TypoBouncer.app
echo 'Release app exported. Notarize it before creating the final DMG.'
