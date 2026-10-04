#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# A static source policy check, not an OS-level network sandbox.
python3 - <<'PY'
import pathlib
import re
import sys

forbidden = re.compile(r'\b(?:URLSession|URLRequest|NSURLConnection|WKWebView|NWConnection|NWListener|PrivateCloudCompute\w*|CFStreamCreatePairWithSocketToHost|Process|popen|socket|connect)\b|\bimport\s+(?:Network|Darwin|Glibc)\b|\bhttps?://')
violations = []
for root in (pathlib.Path('App'), pathlib.Path('Packages/BouncerCore/Sources')):
    for path in sorted(root.rglob('*.swift')):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if forbidden.search(line):
                violations.append(f'{path}:{number}: source policy violation')
if violations:
    print('\n'.join(violations), file=sys.stderr)
    sys.exit(1)
print('On-device source policy passed.')
PY
