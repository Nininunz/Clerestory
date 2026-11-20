# Clerestory release and Sparkle guide

Clerestory is maintained in [Nininunz/Clerestory](https://github.com/Nininunz/Clerestory) and derives from [OpenYoink](https://github.com/MuQY1818/OpenYoink). The original MIT license and contributor attribution are preserved. Stable releases use independent semantic versions and strictly increasing build numbers.

## Update compatibility

| Item | Value |
| --- | --- |
| Download | `Clerestory-<VERSION>.dmg` containing `Clerestory.app` |
| Helper download | `ClerestoryLowPowerMode.pkg` ([Low Power Mode helper](LOW_POWER_MODE_HELPER.md)) |
| App bundle ID | `com.nininunz.Clerestory` |
| Sparkle signing Keychain account | `com.nininunz.OpenYoink` |
| Public feed | [Clerestory appcast](https://nininunz.github.io/Clerestory/appcast.xml) |
| Source appcast | [docs/appcast.xml](appcast.xml) |
| Hosting | [Account Pages repository](https://github.com/Nininunz/nininunz.github.io), at `Clerestory/appcast.xml` |

The app uses its own bundle ID and feed path. The signing Keychain account continues to identify the existing Sparkle key. Appcast entries use `Nininunz/Clerestory` release download URLs.

Package versions are pinned in `Clerestory.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, and CI and release builds use only those versions. To update Sparkle, update packages in Xcode, run `Scripts/test-ci.sh`, and commit the new `Package.resolved`.

The public Sparkle Ed25519 key lives in [Info.plist](../Clerestory/App/Info.plist). The matching private key stays in the maintainer’s Keychain. Back it up securely outside the repository. The release script checks the public key against the Keychain account before building and signs the final DMG with that account. Upstream OpenYoink releases use a different key and feed.

## Signing setup

Use a Developer ID Application identity, a Developer ID Installer identity for the helper package, an Apple notarization profile in Keychain, and the Clerestory Sparkle signing key. Copy [the signing example](../Scripts/release-signing.example) to the ignored `Scripts/release-signing.local` and configure `DEVELOPER_ID_APPLICATION`, `DEVELOPER_ID_INSTALLER`, `DEVELOPMENT_TEAM_ID`, and `NOTARY_PROFILE`, or provide them in the environment. The release and notarization scripts load the local file. The example lets existing environment values take precedence. Keep passwords and private keys in Keychain.

Run `Scripts/doctor.sh --release` to check tool availability, Developer ID signing, and notarization access. Set `SPARKLE_BIN` if the Sparkle tools are in a custom DerivedData location.

## Build, verify, and publish

Choose a release version and a build number higher than the latest public build. In the commands below, set `version` and `build` to those values.

Update [Version.xcconfig](../Version.xcconfig) when preparing a release. It sets the default version and build for local builds, while the packaging script passes the requested values directly to Xcode.

1. Build a local candidate with `CLERESTORY_RELEASE_CANDIDATE=1 Scripts/make-release.sh "$version" "$build"`. This signs and notarizes the artifact and writes unpublished metadata to `export/appcast-candidate.xml`. The DMG lands under `export/`. Choose a higher build when testing an update from an already installed candidate.
2. Run the build and test checks in the [CI guide](development/CI.md) and the relevant [manual smoke checks](MANUAL_TESTING.md). Test installing the signed DMG and launching the app in an appropriate test account. Check code signing, notarization stapling, and both architectures. Use supported Intel hardware to verify execution there when available.
3. Build the public package with `Scripts/make-release.sh "$version" "$build"`. Use the Developer ID build for public distribution. The script produces the signed DMG and writes its Sparkle signature and length to `docs/appcast.xml`. The script also builds, signs, notarizes, and staples the [Low Power Mode helper](LOW_POWER_MODE_HELPER.md) package at `export/ClerestoryLowPowerMode.pkg`. Publish the exact DMG referenced by the appcast and the helper package to the matching GitHub release. Settings → Modules → Battery downloads the helper from the latest release, so every release needs a copy, even when the helper hasn't changed. Merge the signed appcast entry into `main`.
4. Run `Scripts/publish-update-feed.sh` from a checkout with write access to the account Pages repository. It reads the merged appcast, verifies the release archive and signature, creates or updates the feed path, and checks that the deployed bytes match. Then run `Scripts/verify-update-feed.sh "https://nininunz.github.io/Clerestory/appcast.xml" "$version"` to check the public download, signature, and bundled app.
5. For updates within the `com.nininunz.Clerestory` identity, confirm Sparkle discovers the update from an earlier signed install using the public feed. Seed disposable Shelf items and a preference first. After installation and relaunch, verify the new build and confirm that the data and setting survived. Record the results with the release evidence.

## Release history

All pre-release builds were removed on 2026-11-18 and Clerestory restarted at 1.0.0. Those builds used Sparkle build numbers up to 60, including a 1.0.5 (60) build with the `com.nininunz.Clerestory` identity, so every new release uses build 61 or higher. `Scripts/make-release.sh` enforces this floor when the appcast is empty. Earlier `com.nininunz.OpenYoink` builds and upstream OpenYoink keep separate data containers and do not update to Clerestory.
