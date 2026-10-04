# Typo Bouncer

Private macOS proofreading using Apple's on-device Foundation Models.
Built from scratch in Swift 6 with Apple frameworks only. MIT © 2026 Adam Daghmah.

## Availability and requirements

Requires **macOS 27**, an **Apple Silicon Mac**, Apple Intelligence enabled and an
available local model. Distribution is a **DMG through GitHub Releases**.

The pre-release source uses the [MIT license](LICENSE). Its GitHub home is
[ADAM-DAG/typo-bouncer](https://github.com/ADAM-DAG/typo-bouncer).
No public binary release is available yet.
A local Developer ID DMG has been signed, notarized and stapled.
See [verification and remaining release checks](docs/KNOWN_LIMITATIONS.md), including known Dutch
model-quality failures, local model-service/test failures and pending clean-Mac
installation acceptance.

When a release is available, open its DMG, drag **Typo Bouncer** to **Applications**,
then open the app. It runs in the menu bar. Reopening opens Settings.

## Correct text

Select text in another app and press **⌃⌘G**, or record your own shortcut in Settings.
Choose **Proofread** for necessary spelling, grammar, capitalization and punctuation
fixes. Choose **Improve sentences** for clearer structure and less unnecessary wording,
even when the grammar is correct. Both work in English/Dutch.

Select an Auto mode:

- **Off:** review before Apply.
- **Clean:** automatically apply small validated proofreading fixes, including missing
  capitals, contractions, dictionary-confirmed missing spaces, punctuation and trailing
  spaces/tabs. Wording and Improve open review.
- **Full Auto:** apply the validated correction for either action automatically.

Automatic modes are opt-in. Clean's conservative rules cover passages up to 400
characters. All modes verify the target field; uncertain formatting needs review.
The local model can miss errors or propose incorrect changes. Check meaning and names.
Use the target app's own **⌘Z** to undo.

Settings also offers:

- **Double-tap Fn / Globe** or **Double-tap Control**, with the key combination retained
  as a backup. These use a passive listener that cannot consume/change/replay keys.
- **Select text when nothing is selected:** use the whole focused editable field after
  verified Accessibility selection. Existing selections take priority. Delayed AX
  updates are handled within the same request; no global Select All keystroke is sent.
- **Expand chat shorthand:** known forms such as `idk` → “I don't know”, off by default.
- **Launch at login:** off by default, reflects the system setting and starts quietly
  in the menu bar. If approval is needed, use Open Login Items.
- Collapsed app exclusions and access setup when needed.

Use **Allow access…** in Settings to enable Typo Bouncer in macOS's Accessibility/
Device Control and Data Access settings. Optional double-taps have a separate explicit
keyboard-listening setup button. No permission prompts appear at launch.

Corrections are limited to 1,500 characters. Trailing spaces/tabs are removed at line
ends while retaining indentation, line separators and protected code whitespace.
Language, tone, names, numbers, links, email addresses, tags, code and emoji are guarded.
New decorative Markdown, em/en dashes and assistant-like introductions are rejected.

## Other apps and privacy

Replacement requires readable full text/range, affirmative editability and unchanged
focus, field contents, selection and formatting. The same capability checks apply in
all apps. Secure, read-only, disabled and excluded fields stay blocked. Multiple selections
are refused. Editors exposing only selected text offer Review and Copy.

Supported RTF preserves untouched style runs. Uncertain formatting stays reviewed.
The clipboard is saved and restored while the app still owns its temporary contents;
a copy made by another app takes priority. A failed paste is never replayed.
See [field compatibility](docs/COMPATIBILITY.md) and [known limitations](docs/KNOWN_LIMITATIONS.md).

The menu has Correct text, Cancel while working, Review when needed, Settings and Quit.
There is no built-in editor, clipboard tool, correction history or automated Undo.
The app has no networking, cloud fallback, analytics or text logging. Selections and
corrections stay in memory. See [privacy](PRIVACY.md) and [security](SECURITY.md).

## Build and verify

Requires Xcode 27. Tests do not require signing credentials:

```sh
Scripts/check.sh
```

For an installable local build, copy `Config/Signing.local.xcconfig.example` to the
ignored `Config/Signing.local.xcconfig` and configure an existing Apple Development
certificate and matching team. Then:

```sh
Scripts/build-local.sh
# Quit the installed app before updating it.
Scripts/install-local.sh
```

Tests use ad hoc signing in `build/DerivedData`; **never install test products**.
Installable local builds use the pinned development identity and `build/LocalDerivedData`.
The installer verifies signing continuity; an identity change stops installation.
Use `--migrate-signing` only for an explicitly intended migration. A move from a local
build to the public organization's signature can require granting access again.

Release signing uses a separate ignored `Config/Signing.release.local.xcconfig`.
The [release workflow](docs/RELEASING.md) describes Developer ID signing, notarization and DMG packaging.
Credentials and private keys never belong in git or the app. Hosted CI runs core/source
checks and redacted secret scans; native checks require the optional self-hosted Xcode
27 runner. Run `Scripts/check-secrets.sh` with [Gitleaks](https://github.com/gitleaks/gitleaks)
before publishing changes. See [contributing](CONTRIBUTING.md) and the
[private vulnerability-reporting policy](SECURITY.md#reporting-a-vulnerability).
