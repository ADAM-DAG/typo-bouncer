#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
preview=false
if [[ "${1:-}" == --preview ]]; then preview=true; shift; fi
app=${1:-build/Release/export/TypoBouncer.app}
Scripts/verify-release.sh "$app"
if [[ "$preview" != true ]]; then xcrun stapler validate "$app"; fi
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo 'Invalid release version.' >&2; exit 1; fi
signing_identity=$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p' | head -n 1)
suffix=
if [[ "$preview" == true ]]; then suffix=-preview; fi
dmg="build/Release/TypoBouncer-$version-macOS-arm64$suffix.dmg"
staging=$(mktemp -d build/Release/.dmg.XXXXXX)
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/TypoBouncer.app"
ln -s /Applications "$staging/Applications"
hdiutil create -ov -volname 'Typo Bouncer' -srcfolder "$staging" -fs HFS+ -format UDZO "$dmg"
codesign --force --sign "$signing_identity" --timestamp "$dmg"
Scripts/verify-release.sh "$dmg"
hdiutil verify "$dmg"
if [[ "$preview" == true ]]; then
  echo "Layout preview only; not a notarized release: $dmg"
else
  echo "DMG created: $dmg. Notarize and staple it before distribution."
fi
