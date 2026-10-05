# Security policy

## System and scope

Typo Bouncer is a local macOS menu-bar app for transforming user-selected text with
Apple's on-device language model. App/ is the native process boundary;
Packages/BouncerCore/ contains pure logic. Scripts, signing configuration and release
packaging are also in scope. The app executes on-device correction, validates output,
and offers guarded replacement with supported in-memory RTF preservation. Automated
safeguard checks use synthetic fixtures; broader cross-app QA is pending.

## Threat model and trust boundaries

Selected text can contain hostile instructions, malformed Unicode, URLs or code. Other
apps can change focus, selection and clipboard contents while a request is running.
Language-model output is untrusted and must pass deterministic validation before being
offered for replacement. The user's text, clipboard, target field and signing credentials
are the principal assets. Accessibility trust enables sensitive operations; it does not
make captured text or model output trustworthy.

## Required security properties

- Model requests use the on-device system model only, in process, with no networking or
  cloud fallback. Text is never executed as instructions, commands or tools.
- Only the isolated software updater may contact GitHub and its release CDN. Release
  metadata is untrusted. Downloads must pass SHA-256, the installed designated
  requirement plus Apple Developer ID/team checks, sealed version/build/minimum-OS
  checks and Gatekeeper assessment before replacement. Refuse downgrades, development
  signing migrations and unsupported/read-only installation locations. Installation
  waits for exit, atomically exchanges same-volume bundles and rolls back on validation
  or relaunch failure. Never pass text, clipboard data or correction services to the updater.
- Original text remains untouched on capture, generation, validation or pre-paste
  verification failure. Refuse secure fields and the app denylist. After a posted paste,
  report an unconfirmed result without retrying or attempting a blind undo.
- Before replacement, re-check the target application, element and selection. A mismatch
  must prevent both paste and the replacement clipboard write.
- Preserve the complete clipboard, restore only if its change count is still ours, and
  refuse to paste when preservation cannot be completed faithfully.
- Never persist or log selected or corrected text. Do not retain correction history. Request permissions only when the user invokes a feature
  that needs them.
- Keep requests single-flight and bounded by input/context budgets and cancellation.
  Preserve protected tokens, language and the command's formatting contract.
- Keep credentials and private signing keys out of git and the app. Releases use the
  configured organization's Developer ID, hardened runtime, secure timestamps and
  notarization, without debug entitlements.

## Findings and limitations

Reachable text disclosure, wrong-target replacement, loss of clipboard data, execution
of selected content, or bypass of a required validation or permission boundary is
reportable. Assess impact from actual reachability and data exposure rather than assuming
every model mistake is an exploitable vulnerability. Spelling quality is a product
limitation; it does not excuse violations of protected-token or replacement safeguards.

No security finding classes are excluded. The controls above are requirements;
[Known limitations](docs/KNOWN_LIMITATIONS.md) distinguishes automated verification from
pending cross-app checks. Prompt delimiters are one layer and do not by themselves
prevent prompt injection. The source policy script is a static check, not a network
sandbox or proof that a future dependency cannot communicate externally.

## Reporting a vulnerability

Use
[GitHub's private vulnerability reporting](https://github.com/ADAM-DAG/typo-bouncer/security/advisories/new)
for suspected text disclosure, wrong-target replacement or other safety-boundary failures.
Include the affected commit/build, macOS version and reproduction steps using synthetic
text. Do not put user text, credentials or private findings in public issues.

Version 0.1.0 is an early public release. Security fixes target the latest release;
there is no long-term supported release series. Fixes are developed on `main`; older development snapshots receive no
maintenance guarantee. Model-quality limitations and pending physical acceptance are
recorded in [known limitations](docs/KNOWN_LIMITATIONS.md).
