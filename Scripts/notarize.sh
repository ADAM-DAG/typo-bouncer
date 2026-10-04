#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
artifact=${1:?Pass the release app or DMG}
profile=${2:-TypoBouncer}
Scripts/verify-release.sh "$artifact"
mkdir -p build/Release
staging=$(mktemp -d build/Release/.notarization.XXXXXX)
trap 'rm -rf "$staging"' EXIT
if [[ "$artifact" == *.app ]]; then
  upload="$staging/app.zip"
  ditto -c -k --keepParent "$artifact" "$upload"
elif [[ "$artifact" == *.dmg ]]; then
  upload="$artifact"
  hdiutil verify "$artifact"
else
  echo 'Notarization accepts a release app or DMG.' >&2
  exit 2
fi
result="build/Release/$(basename "$artifact").notarization.json"
xcrun notarytool submit "$upload" --keychain-profile "$profile" --wait --output-format json > "$result"
python3 - "$result" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
print('Notarization:', result.get('status'), 'Submission:', result.get('id'))
if result.get('status') != 'Accepted':
    raise SystemExit('Apple did not accept this artifact. Inspect the submission log before proceeding.')
PY
xcrun stapler staple "$artifact"
xcrun stapler validate "$artifact"
Scripts/verify-release.sh "$artifact"
if [[ "$artifact" == *.app ]]; then
  spctl --assess --type execute --verbose=2 "$artifact"
else
  spctl --assess --type open --context context:primary-signature --verbose=2 "$artifact"
fi
echo 'Notarization, stapled ticket and Gatekeeper verified.'
