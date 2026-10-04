#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

migrate_signing=false
launch_app=true
for argument in "$@"; do
  case "$argument" in
    --migrate-signing) migrate_signing=true ;;
    --no-open) launch_app=false ;;
    *) echo "Unknown argument: $argument" >&2; exit 2 ;;
  esac
done
Scripts/build-local.sh
candidate_app=build/LocalDerivedData/Build/Products/Debug/TypoBouncer.app
local_app_destination="$HOME/Applications/TypoBouncer.app"

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
mkdir -p "$HOME/Applications"
staging=$(mktemp -d "$HOME/Applications/.TypoBouncer-install.XXXXXX")
cleanup() {
  if [[ -d "$staging/previous.app" && ! -e "$local_app_destination" ]]; then
    mv "$staging/previous.app" "$local_app_destination"
  fi
  rm -rf "$staging"
}
trap cleanup EXIT
ditto "$candidate_app" "$staging/TypoBouncer.app"
Scripts/verify-local-signing.sh "$staging/TypoBouncer.app"
if [[ -d "$local_app_destination" ]]; then mv "$local_app_destination" "$staging/previous.app"; fi
mv "$staging/TypoBouncer.app" "$local_app_destination"
echo "Installed certificate-signed build at $local_app_destination"
if [[ "$launch_app" == true ]]; then open "$local_app_destination"; fi
