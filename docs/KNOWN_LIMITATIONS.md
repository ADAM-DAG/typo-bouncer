# Known limitations and verification

Typo Bouncer 0.1.0 (build 30) is an early public release.
It requires macOS 27, Apple Silicon and an available Apple Intelligence on-device model.

## Automated verification

The build 30 check passed all 61 core tests and the source policy with its isolated
GitHub updater exception. Native tests ran 163 cases; three cases failed with four
assertions: direct-question Auto eligibility, Dutch proofreading recall and English/Dutch
rewrite quality/facts. All six updater cases passed, including local Developer ID fixtures.
The full check is not green. After the final updater path fix, a targeted check passed
61 core tests, the source policy and all seven updater tests, including directory-URL
and symlink rejection coverage. The certificate-signed release build passed. Both app and DMG were notarized and
stapled, with Gatekeeper acceptance. The final DMG passed the production updater
checksum, signature-continuity, sealed-metadata, Gatekeeper and staging checks against
an older signed fixture; this did not install or relaunch the user’s app.
Test expectations have not been weakened to hide these failures.

Earlier live runs also missed the Dutch corpus threshold and a Dutch rewrite-fact
assertion, or failed with model-service errors/cancellation and asynchronous deadlines.
The local model can miss errors, change correct text or propose wording that changes
meaning. Small development fixtures do not establish general proofreading accuracy.

Hosted CI runs core tests, the source policy, a public-file policy and redacted secret
scans. Native checks require a manually configured Xcode 27 runner. Tests use synthetic
passages and private pasteboards, without capturing real selections.

## Physical acceptance still pending

- App-by-app shortcut, selection and paste behavior across representative fields.
- Ordinary typing, double-tap triggers, changing focus and all correction modes.
- Clipboard competition, secure/excluded fields and representative rich formatting.
- Login enable/disable and an actual logout/login cycle.
- A clean downloaded-DMG installation, permission setup and update continuity.
- An actual GitHub release-to-release update with notarized builds, permissions after
  relaunch and failure recovery. The first public build includes the updater. Automated
  tests cover atomic exchange/rollback and signing checks; they do not establish the
  complete live updater flow.
- Larger independent English/Dutch quality and false-positive checks.

See [field capabilities](COMPATIBILITY.md). Automatic application requires verified
fields; uncertain formatting stays reviewed. Use the target app's own Undo and check
meaning and names when reviewing corrections.
