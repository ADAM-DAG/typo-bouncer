#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Gitleaks is development tooling only; the app has no third-party dependencies.
gitleaks_bin=${GITLEAKS_BIN:-gitleaks}
if ! command -v "$gitleaks_bin" >/dev/null 2>&1; then
  echo 'Install Gitleaks (brew install gitleaks), or set GITLEAKS_BIN to its executable.' >&2
  exit 1
fi

scan_dir=$(mktemp -d "${TMPDIR:-/tmp}/typo-bouncer-secrets.XXXXXX")
trap 'rm -rf "$scan_dir"' EXIT

# Export exactly the current tracked and nonignored files. Private local signing
# choices, build output and Git metadata never enter the temporary source copy.
# Reject sensitive paths even if someone force-added them despite .gitignore.
python3 - "$scan_dir" <<'PY'
import pathlib
import re
import shutil
import subprocess
import sys

destination = pathlib.Path(sys.argv[1])
paths = set(subprocess.check_output([
    'git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'
]).decode().split('\0')) - {''}
private_directories = {'build', '.build', '.swiftpm', 'DerivedData', 'xcuserdata'}
private_documents = {'AGENTS.md', 'PLAN.md', 'docs/QA.md', 'docs/corpus-results.md'}
private_suffixes = {
    '.p12', '.pfx', '.p8', '.pem', '.key', '.cer', '.certSigningRequest',
    '.mobileprovision', '.provisionprofile', '.dmg', '.dmg.sha256', '.log',
    '.xcuserstate', '.xcresult', '.xcarchive', '.app',
}
violations = []
count = 0
for name in sorted(paths):
    path = pathlib.Path(name)
    private = (
        name in private_documents
        or path.name in {'AGENTS.md', 'PLAN.md'}
        or bool(set(path.parts) & private_directories)
        or path.name.endswith('.local.xcconfig')
        or (path.name.startswith('.env') and path.name != '.env.example')
        or path.name == '.DS_Store'
        or any(part.endswith(suffix) for part in path.parts for suffix in private_suffixes)
    )
    if private:
        violations.append(f'{name}: private file or generated artifact must not be published')
        continue
    if path.is_symlink():
        violations.append(f'{name}: source export refuses symlinks')
        continue
    if not path.is_file():
        continue  # A deleted tracked file will be removed by git add before commit.
    data = path.read_bytes()
    if re.search(rb'/(?:Users|home)/[^\s/]+/', data):
        violations.append(f'{name}: personal absolute path must not be published')
    target = destination / path
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(path, target)
    count += 1
if violations:
    print('\n'.join(violations), file=sys.stderr)
    sys.exit(1)
print(f'Public file policy passed ({count} files).')
PY

"$gitleaks_bin" dir "$scan_dir" --redact=100 --no-banner --ignore-gitleaks-allow
if [[ -n "$(git for-each-ref --format='%(refname)')" ]]; then
  "$gitleaks_bin" git . --log-opts='--all --reflog' --redact=100 --no-banner --ignore-gitleaks-allow
fi
