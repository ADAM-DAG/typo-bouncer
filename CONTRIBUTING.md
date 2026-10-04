# Contributing

Typo Bouncer is a native macOS 27 menu-bar app using Swift 6 strict concurrency.
App code belongs in `App/`; pure logic belongs in `Packages/BouncerCore/`.
Read [README.md](README.md), [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md)
for the product behavior and safety requirements.
Use Apple frameworks only, without app networking or cloud model calls.

## Development

Core tests run independently of app signing:

```sh
swift test --package-path Packages/BouncerCore
Scripts/check-no-network.sh
```

On a supported Apple Silicon Mac with Xcode 27, run `Scripts/check.sh` for the full
core and native suite. Live model tests require an available Apple Intelligence
model and can vary by OS/model version. Report skips and failures accurately;
[known limitations](docs/KNOWN_LIMITATIONS.md) records the current verification limits.

For an installable development build, copy `Config/Signing.local.xcconfig.example`
to `Config/Signing.local.xcconfig` and configure your existing certificate locally.
See [build instructions](README.md#build-and-verify). Never install ad hoc test builds.
Do not commit signing overrides, credentials, private keys or generated artifacts.

## Before a pull request

- Run the checks relevant to your change and `Scripts/check.sh` after code changes.
- Install [Gitleaks](https://github.com/gitleaks/gitleaks) (`brew install gitleaks`),
  then run `Scripts/check-secrets.sh`. It checks current publishable files and Git
  history, with findings redacted. `GITLEAKS_BIN` can select an existing executable.
- Use synthetic test passages. Never attach real selections, clipboard contents,
  credentials, local signing files or unreviewed diagnostic logs.
- Explain the behavior changed, verification performed and remaining limitations.

Hosted CI checks the core, source policy and secrets. Native checks are an explicit
manual workflow on a configured Xcode 27 runner. Publishing binaries or submitting
notarization is a separate maintainer action.

Report vulnerabilities through [private reporting](SECURITY.md#reporting-a-vulnerability).
