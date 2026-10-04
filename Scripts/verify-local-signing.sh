#!/bin/bash
set -euo pipefail
candidate_app=${1:?Pass the local app bundle to verify}
codesign --verify --deep --strict "$candidate_app"
signature=$(codesign -dvv "$candidate_app" 2>&1)
if ! grep -q '^Authority=Apple Development:' <<< "$signature"; then
  echo 'Refusing an installable build without an Apple Development certificate.' >&2
  exit 1
fi
requirement=$(codesign -d -r- "$candidate_app" 2>&1 | sed -n 's/^.*designated => //p')
if [[ -z "$requirement" || "$requirement" == *cdhash* ]]; then
  echo 'Refusing a build whose identity is tied to a changing binary hash.' >&2
  exit 1
fi
printf 'Local certificate signature verified.\n'
