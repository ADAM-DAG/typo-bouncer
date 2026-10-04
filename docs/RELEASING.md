# Maintainer release workflow

Source publication and binary distribution are separate steps. Complete the
[remaining acceptance checks](KNOWN_LIMITATIONS.md) before creating a binary release.

On an Apple Silicon Mac with Xcode 27, copy
`Config/Signing.release.local.xcconfig.example` to
`Config/Signing.release.local.xcconfig` and configure an existing Developer ID
Application certificate and matching distribution team. This file is ignored.
Keep release signing separate from the local development identity.

```sh
Scripts/check.sh
Scripts/check-secrets.sh
Scripts/build-release.sh
Scripts/notarize.sh build/Release/export/TypoBouncer.app
Scripts/package-dmg.sh
Scripts/notarize.sh build/Release/TypoBouncer-0.1.0-macOS-arm64.dmg
```

The notarization script uses an existing Keychain credential profile. Its optional
second argument selects the profile; the default is `TypoBouncer`. Configure credentials
interactively with `xcrun notarytool store-credentials`. Keep passwords, private keys,
signing overrides and notarization logs out of Git and the app.

The release scripts use manual Developer ID signing, hardened runtime and a secure
timestamp, without the debug entitlement. The DMG contains only the app and an
Applications shortcut. `package-dmg.sh --preview` creates an unnotarized layout preview.

Final distribution requires a stapled app inside a signed/stapled DMG. Validate the
signature, notarization tickets and Gatekeeper assessment on a fresh mounted copy,
then verify its checksum. Upload only the final DMG and its `.dmg.sha256` to a GitHub
Release after maintainer approval. Do not distribute previews or ad hoc test builds.
