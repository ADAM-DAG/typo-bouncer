# Maintainer release workflow

Source publication and binary distribution are separate steps. Review the
[remaining acceptance checks](KNOWN_LIMITATIONS.md) before creating a binary release;
early releases must disclose any checks that remain pending.

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
Scripts/package-update.sh build/Release/TypoBouncer-0.1.0-macOS-arm64.dmg
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
then verify its checksum. Upload the final DMG and its `.dmg.sha256`, plus both
`build/Release/Updates/TypoBouncer-update.dmg` and `TypoBouncer-update.json`, to the
same public GitHub Release after maintainer approval. Do not distribute previews or
ad hoc test builds. Keep the release a draft until all assets are attached, then publish
it as a stable release (not a prerelease), with GitHub's latest-release designation.

Every release must increase `CURRENT_PROJECT_VERSION` in both app configurations;
the marketing version must not decrease. The update packaging script reads sealed
app metadata from the final mounted DMG and records its SHA-256. It does not publish
anything or use GitHub credentials. Keep the fixed updater asset names on every
release. Rebuild/repackage if any binary changes after notarization.

The updater uses GitHub's [latest stable release API](https://docs.github.com/en/rest/releases/releases#get-the-latest-release).
It validates the installed designated requirement through Apple's
[Code Signing Services](https://developer.apple.com/documentation/security/code-signing-services),
plus the Apple Developer ID anchor and team. No additional update signing key or
third-party updater framework is needed. Automatic checks run daily; download,
verification, installation and relaunch require the user's Update and relaunch action.
Settings preferences and the installed bundle path survive the update. Signing
continuity is enforced, but permission continuity still needs physical acceptance.

Before shipping, test an installed, downloaded release updating to a second signed
and notarized release, failed download/checksum/signature checks, relaunch rollback,
read-only installs, and permissions after relaunch. Builds before 29 have no updater;
their users need one manual installation of an updater-enabled release. The first
public release, 0.1.0 (build 30), includes the updater.
