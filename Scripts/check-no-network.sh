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
# Explicit user-authorized exception: software updates only. Never exempt a directory,
# correction/model code, raw sockets or arbitrary remote URLs outside this one client.
exceptions = {
    'App/Updates/UpdateTransport.swift': {'URLSession', 'URLRequest', 'https://'},
    'App/Updates/UpdateInstaller.swift': {'Process', 'import Darwin'},
}
for root in (pathlib.Path('App'), pathlib.Path('Packages/BouncerCore/Sources')):
    for path in sorted(root.rglob('*.swift')):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if any(match.group(0) not in exceptions.get(str(path), set()) for match in forbidden.finditer(line)):
                violations.append(f'{path}:{number}: source policy violation')
if violations:
    print('\n'.join(violations), file=sys.stderr)
    sys.exit(1)
print('On-device source policy passed (isolated GitHub software updater exception).')
PY
