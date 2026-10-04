# Known limitations and verification

Typo Bouncer is pre-release source. No public binary release is available yet.
It requires macOS 27, Apple Silicon and an available Apple Intelligence on-device model.

## Automated verification

The latest local full check passed all 57 core tests and the no-network source policy.
Native tests passed 134 of 154 cases. Live-model suites failed with model-service errors
or cancellation, and three synthetic Auto-mode tests failed at fixed asynchronous wait
deadlines. A targeted recheck reproduced those three failures. The full check is not green.
Test expectations have not been weakened to hide these failures.

Earlier live runs also missed the Dutch corpus threshold and a Dutch rewrite-fact
assertion. The latest model-service failures prevent reassessing those quality issues.
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
- Larger independent English/Dutch quality and false-positive checks.

See [field capabilities](COMPATIBILITY.md). Automatic application requires verified
fields; uncertain formatting stays reviewed. Use the target app's own Undo and check
meaning and names when reviewing corrections.
