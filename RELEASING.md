# Releasing Forma

Public source, installers, and updates are published to `liquorice-head/forma-app`.

## Development builds

Use Xcode 26+ on Apple Silicon. Run `swift test --disable-sandbox` before preparing a release. A stable signing identity is recommended for local builds; see the README.

Local configuration files such as `.forma-signing-identity` and `.release-config-cloud-profile` are ignored by Git. Never commit credentials, certificate exports, provisioning profiles, private keys, build products, or notarization receipts.

## Distribution prerequisites

- A Developer ID Application certificate and its private key in the local Keychain.
- A notarization credential profile saved securely through `xcrun notarytool store-credentials`.
- The existing Sparkle Ed25519 signing key in Keychain under account `app.forma.updates`. Its public key must match `SUPublicEDKey` in `scripts/Info.plist`. Do not replace this key for the existing release line.
- GitHub CLI authenticated with permission to publish releases to the public repository.

Set `FORMA_SIGN_IDENTITY` to the certificate fingerprint, or save it in the ignored `.forma-signing-identity` file. Provide the notarization profile name with `--notary-profile` or `FORMA_NOTARY_PROFILE`. Keep all private material and machine-specific paths outside Git.

## Optional CloudKit configuration

The official distribution can enable private iCloud sync. Set `FORMA_CLOUD_PROFILE` to a matching Developer ID provisioning profile, or save its path in the ignored `.release-config-cloud-profile` file. The default container is `iCloud.<bundle identifier>`; `FORMA_CLOUD_CONTAINER` can override it when authorized by the profile.

The build validates the certificate, bundle identifier, container, and Production environment, embeds the profile, and signs the required entitlements. Without a profile, iCloud is unavailable in Settings.

The schema is in `scripts/CloudKit.ckdb`. Create and deploy it through CloudKit Console for your own container. `FormaSyncItem` uses a Bytes `payload` field and a Queryable index on `recordName` (`___recordID`). Grant creation to `_icloud` and read/write to `_creator`, without `_world` access. The app uses the private database only.

## Publish

1. Increment the version and numerical build in `scripts/Info.plist` and `Forma.xcodeproj/project.pbxproj`.
2. Run tests, review release notes, then commit and push the exact source to the public repository.
3. Run:

```sh
python3 scripts/release.py --notary-profile YOUR_NOTARY_PROFILE \
  --notes docs/releases/0.7.0.md --publish
```

The script builds and signs the app and Sparkle components, notarizes and staples the app, packages a DMG and update ZIP, notarizes the DMG, generates SHA-256 checksums, and signs both the update archive and appcast. It uploads a draft release before publishing, and refuses an uncommitted tree or a source commit absent from the target repository.

After publication, download the release assets and verify checksums, Gatekeeper acceptance, the app inside the DMG and ZIP, and the signed appcast's version and archive URL. Test the actual update and draft restoration before claiming migration coverage.

## Forks

Configure your own bundle identifier, CloudKit container, signing keys, and repository URLs in `Sources/Forma/GitHubUpdates.swift`, `scripts/Info.plist`, `scripts/release.py`, and the related updater tests. The official update key and iCloud container do not authorize a fork to publish updates or use its own signing identity with the official container.
