# Privacy

Typo Bouncer uses Apple's on-device Foundation Models API and native spelling dictionaries.
Spelling candidates are checked by the local model before being proposed in the preview.
Extra contextual spelling candidates are limited to content words; they exclude adverbs,
function words and negations. Sentence completion uses local language analysis, with a
separate on-device pass for longer unpunctuated statements. Bare protected tokens, such
as a URL or code-only selection, need no model request. Ordinary trailing spaces/tabs
outside protected code can still be removed locally.
There is no cloud fallback, app networking, analytics, telemetry, text logging, update
checker, or third-party code.

Selections, selected-text formatting snapshots, the current correction and clipboard
snapshots stay in memory. There is no built-in editor or correction history. They are discarded when the process quits. Text is never written to
UserDefaults, files, or app logs. Speed caches contain only token counts of fixed
instructions and schemas. A prewarmed empty session is consumed once; user passages
and responses are never reused in subsequent requests. Preferences store only shortcut and trigger choices, the selected correction action,
Auto mode, focused-field selection, the shorthand preference and excluded bundle identifiers. Automated model tests use deliberately synthetic fixtures.

Accessibility is explained and requested only when you click its setup button after
choosing to use the app in other apps. No permission prompt appears at launch. The app
offers optional keyboard listening access only from **Allow keyboard access…** after
choosing a double-tap trigger. This uses macOS's event-listening permission (Input
Monitoring), separate from the regular Carbon shortcut. It does not request Screen
Recording, Automation or file access. Launch-at-login registration requires its
explicit Settings toggle.

Selection capture refuses secure fields and excluded apps. Replacement verifies the
original field, selection, editability and formatting, and preserves every clipboard
item and type, up to a
256 MiB safety limit. Clipboard restoration occurs only while the temporary ownership
marker and change count still match. If another app copies something, that copy wins.
Explicit Copy actions replace the clipboard as requested by the user. While feedback is visible, the app rechecks only that captured field to dismiss feedback
when its draft changes or is cleared. These bounded reads stay in memory, work without
keyboard listeners, and stop when feedback closes. They never start a new correction.

Auto runs only when you trigger a correction, with the same focus, full-value, selection
and formatting checks as manual Apply. This is a shared capability-based integration
across apps, not a background typing observer. Selected RTF stays in memory; supported
rich-text corrections include both plain text and RTF in the temporary clipboard payload.
Multiple selections are refused. Read-only and disabled controls cannot be replaced. It uses native local dictionaries to accept small spelling
repairs, missing spaces and trailing-space removal, and aligns words before allowing capitalization, explicit
contractions and sentence punctuation. Rewording requires review in Off and Clean; Full Auto applies validated wording changes. Auto shows
a compact status capsule with no selected text; changes needing approval open review.
No global or pass-through local NSEvent keyboard monitors are installed. Opt-in
Fn/Globe and Control double-taps use a passive Core Graphics event tap that cannot
consume, modify or replay events. It reads only modifier key identity, flags, timing,
and the foreground app identifier; ordinary keys and pointer events interrupt the
detector without decoding typed text. No event history is recorded. The listener is
removed when Key combination is selected or while recording a shortcut. Use the
registered backup shortcut if listening access is unavailable, and your target app's
own ⌘Z to undo. An open review no longer registers
global bare Return/Escape bindings. The
shortcut recorder consumes keys only while explicitly recording. No user text or
selection handles are persisted.

The app cannot control operating-system diagnostics, clipboard managers, memory paging,
or how another app handles pasted text. The source policy check is not a network sandbox.

The local development build uses its existing development certificate; test builds
are signed ad hoc. GitHub DMG releases use a separate Developer ID Application
certificate. The distribution signature exposes Apple's registered organization name
and Team ID. Notarization sends the built app/disk image to Apple, without selections,
text history or credentials bundled inside. Signing credentials are never committed.

The optional Select text when nothing is selected preference is off by default.
When a correction is triggered with an empty selection, it may select the whole focused
editable field through Accessibility after checking the original caret, complete value,
editability, foreground app and text limit. It reads the selection back before model
work and uses the existing selection/focus/formatting checks before replacement.
No new permission or keyboard monitor is added, and no synthetic Select All is sent.
Existing selections, secure fields, excluded apps and unsupported controls retain the
same behavior. This never triggers correction merely because a field receives focus.

Empty-selection feedback reads only the focused editable field’s bounds after capture
fails. It does not read or select text for placement, create a replacement target,
or invoke the model. The last indicator geometry and its source process ID stay
in memory so an unavailable field does not move feedback into a screen corner.
This stores no text or selection handle and is never written to preferences or files.

Launch at login is opt-in and managed locally by macOS Service Management. The app
reads registration status at launch and in Settings; it only registers or unregisters
in response to the Settings toggle. No login helper, network service or text storage
is added. Login starts the existing menu-bar app without opening a window.
