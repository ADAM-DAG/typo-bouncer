#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

migrate_signing=false
launch_app=true
developer_id=false
local_app_destination="$HOME/Applications/TypoBouncer.app"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --migrate-signing) migrate_signing=true; shift ;;
    --no-open) launch_app=false; shift ;;
    --developer-id) developer_id=true; shift ;;
    --destination)
      if [[ $# -lt 2 || "$2" != /*/TypoBouncer.app ]]; then
        echo 'Use --destination with an absolute path ending in /TypoBouncer.app.' >&2
        exit 2
      fi
      local_app_destination="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [[ "$developer_id" == true ]]; then
  Scripts/build-release.sh
  candidate_app=build/Release/export/TypoBouncer.app
else
  Scripts/build-local.sh
  candidate_app=build/LocalDerivedData/Build/Products/Debug/TypoBouncer.app
fi
verify_candidate() {
  if [[ "$developer_id" == true ]]; then
    Scripts/verify-release.sh "$1"
  else
    Scripts/verify-local-signing.sh "$1"
  fi
}

if [[ -d "$local_app_destination" ]]; then
  installed_requirement=$(codesign -d -r- "$local_app_destination" 2>&1 | sed -n 's/^.*designated => //p')
  if [[ -z "$installed_requirement" ]] || ! codesign --verify --strict -R "=$installed_requirement" "$candidate_app" >/dev/null 2>&1; then
    if [[ "$migrate_signing" != true ]]; then
      echo 'The update changes the installed signing identity. Installation stopped to preserve permissions.' >&2
      echo 'For an intentional one-time migration, use --migrate-signing; macOS may require permission again.' >&2
      exit 1
    fi
    echo 'Performing the explicitly requested one-time signing migration.'
  fi
fi
if pgrep -x TypoBouncer >/dev/null; then
  echo 'Quit Typo Bouncer before updating the installed copy.' >&2
  exit 1
fi
local_app_parent=$(dirname "$local_app_destination")
mkdir -p "$local_app_parent"
staging=$(mktemp -d "$local_app_parent/.TypoBouncer-install.XXXXXX")
cleanup() {
  if [[ -d "$staging/previous.app" && ! -e "$local_app_destination" ]]; then
    mv "$staging/previous.app" "$local_app_destination"
  fi
  rm -rf "$staging"
}
trap cleanup EXIT
ditto "$candidate_app" "$staging/TypoBouncer.app"
verify_candidate "$staging/TypoBouncer.app"
if [[ -d "$local_app_destination" ]]; then mv "$local_app_destination" "$staging/previous.app"; fi
mv "$staging/TypoBouncer.app" "$local_app_destination"
echo "Installed certificate-signed build at $local_app_destination"
if [[ "$launch_app" == true ]]; then open "$local_app_destination"; fi
