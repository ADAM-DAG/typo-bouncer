#!/bin/bash
set -euo pipefail
artifact=${1:?Pass a signed app or DMG}
codesign --verify --deep --strict "$artifact"
signature=$(codesign -dvv "$artifact" 2>&1)
if ! grep -q '^Authority=Developer ID Application:' <<< "$signature" || ! grep -q '^Timestamp=' <<< "$signature"; then
  echo 'Release requires Developer ID Application signing and a secure timestamp.' >&2
  exit 1
fi
if [[ "$artifact" == *.app ]]; then
  if ! grep -q 'flags=.*runtime' <<< "$signature"; then
    echo 'Release app requires hardened runtime.' >&2
    exit 1
  fi
  python3 - "$artifact" <<'PY'
import plistlib, subprocess, sys
result = subprocess.run(['codesign', '-d', '--entitlements', '-', '--xml', sys.argv[1]], capture_output=True, check=True)
entitlements = plistlib.loads(result.stdout)
if entitlements.get('com.apple.security.get-task-allow') not in (None, False):
    raise SystemExit('Release app must not contain a debug entitlement.')
if entitlements.get('com.apple.security.app-sandbox') not in (None, False):
    raise SystemExit('The cross-app release must not be sandboxed.')
PY
fi
echo 'Developer ID signature and release protections verified.'
