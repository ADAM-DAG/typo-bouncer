# Cross-app compatibility

Typo Bouncer uses the same macOS Accessibility and guarded paste path in every app.
Select text in an editable field and press the configured correction shortcut (⌃⌘G by
default). Auto applies eligible spelling, capitalization, contraction, missing-space,
sentence-punctuation and trailing-space repairs in place. It is triggered proofreading,
not continuous correction while typing. Larger
changes and sentence improvements require review in Off and Clean; Full Auto can apply
validated changes when the field and formatting checks pass.

## Field capabilities

| Field capability | Behavior | Verification |
|---|---|---|
| Readable value/range, writable value, plain or uniform basic text | Auto eligible | Synthetic capture and full Auto pipeline |
| Selected-text editing or explicit editable attribute | Auto eligible with the same checks | Synthetic capture/editability tests |
| Full text through character count and string-for-range | Supported with complete Unicode snapshot | Synthetic Unicode capture, recheck and confirmation |
| Selected RTF with supported styles | Preserves untouched runs and changed-word style | Synthetic RTF/font/color/link/emoji and clipboard round-trip |
| Unknown/mixed rich formatting without usable RTF | Review; plain Apply warning or Copy | Synthetic formatting refusal |
| Multiple selections, inconsistent range/value, changed focus/text/style | Refused | Synthetic rejection and no-paste checks |
| Secure, disabled or read-only field; excluded app | Replacement blocked | Synthetic field checks and existing exclusion policy |
| Deeply nested browser/Electron editor or custom role with verified text capabilities | Same guarded replacement path | Deep-ancestry, secure-ancestor and cycle regressions |
| Editor exposing selected text without a full value/range | Preview and Copy | Capture and no-replacement regressions |
| Editor hiding both selected text and a readable value/range | Capture refused | Synthetic capture refusal |

## Requested apps

T3 Code, browser fields, Notes, Word, ChatGPT and Codex all use the shared integration;
none is enabled through a hardcoded app exception. Each app can contain several kinds
of editor, and capabilities can differ between versions or fields. The native and
browser-style synthetic fixtures do not establish physical shortcut/paste behavior
in any of these named apps. End-to-end app-by-app verification remains pending.

Normal typing uses no global or pass-through local NSEvent keyboard listener. Opt-in
double-taps use a listen-only Core Graphics event tap.
Automated cross-app Undo and correction history were removed. Use the target app's own ⌘Z.

## Verification limits

Synthetic tests cover capture/editability, Unicode ranges, stale focus and selection,
formatting preservation/refusal, clipboard ownership, single-paste confirmation and
all correction modes. They do not establish end-to-end compatibility with an app.

The complete physical-key/field matrix still needs manual acceptance.
See [known limitations](KNOWN_LIMITATIONS.md) for current verification limits.

A failed Apply disables another paste until a fresh request. Reopening the app opens
Settings. The app has no built-in editor, clipboard correction tool, correction history
or automated external Undo. Unsupported fields must expose their selection or capture
is refused; there is no synthetic Copy or Select All fallback.
