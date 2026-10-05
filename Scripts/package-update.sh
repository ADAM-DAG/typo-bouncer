#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
image=${1:?Pass the final signed, notarized, stapled DMG}
Scripts/verify-release.sh "$image"
xcrun stapler validate "$image"
hdiutil verify "$image"
mkdir -p build/Release/Updates
staging=$(mktemp -d build/Release/.update.XXXXXX)
mounted=false
cleanup() {
  if [[ "$mounted" == true ]]; then hdiutil detach "$staging/mount" >/dev/null || return; fi
  rm -rf "$staging"
}
trap cleanup EXIT
mkdir "$staging/mount"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$staging/mount" "$image" >/dev/null
mounted=true
app="$staging/mount/TypoBouncer.app"
Scripts/verify-release.sh "$app"
xcrun stapler validate "$app"
spctl --assess --type execute "$app"
python3 - "$app" "$image" <<'PY'
import hashlib, json, pathlib, plistlib, re, shutil, sys
app, image = map(pathlib.Path, sys.argv[1:])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
version, build, minimum = (info[key] for key in ('CFBundleShortVersionString', 'CFBundleVersion', 'LSMinimumSystemVersion'))
if not re.fullmatch(r'[0-9]{1,8}\.[0-9]{1,8}\.[0-9]{1,8}', version) or not re.fullmatch(r'[1-9][0-9]*', build):
    raise SystemExit('Update needs a numeric release version and monotonically increasing build number.')
if not re.fullmatch(r'[0-9]{1,8}\.[0-9]{1,8}(\.[0-9]{1,8})?', minimum):
    raise SystemExit('Invalid minimum macOS version.')
if info['CFBundleIdentifier'] != 'com.itsadamdag.TypoBouncer' or info['CFBundleExecutable'] != 'TypoBouncer':
    raise SystemExit('Unexpected app identity.')
output = pathlib.Path('build/Release/Updates')
destination = output / 'TypoBouncer-update.dmg'
shutil.copyfile(image, destination)
with destination.open('rb') as handle:
    digest = hashlib.file_digest(handle, 'sha256').hexdigest()
manifest = dict(schema=1, version=version, build=int(build), minimumSystemVersion=minimum,
                architecture='arm64', sha256=digest)
(output / 'TypoBouncer-update.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f'Update assets prepared for {version} (build {build}). Nothing was published.')
PY
hdiutil detach "$staging/mount" >/dev/null
mounted=false
