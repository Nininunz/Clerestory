# Clerestory release and Sparkle guide

Clerestory is maintained in [Nininunz/Clerestory](https://github.com/Nininunz/Clerestory) and derives from [OpenYoink](https://github.com/MuQY1818/OpenYoink). The original MIT license and contributor attribution are preserved. Stable releases use independent semantic versions and strictly increasing build numbers.

## Update compatibility

| Item | Value |
| --- | --- |
| Download | `Clerestory-<VERSION>.dmg` containing `Clerestory.app` |
| App bundle ID and Sparkle Keychain account | `com.nininunz.OpenYoink` |
| Public feed | [Clerestory appcast](https://nininunz.github.io/OpenYoink/appcast.xml) |
| Source appcast | [docs/appcast.xml](appcast.xml) |
| Hosting | [Account Pages repository](https://github.com/Nininunz/nininunz.github.io), at `OpenYoink/appcast.xml` |

Keep the existing feed URL, signing key, and bundle ID for upgrades from earlier versions of this fork. The account Pages repo also hosts a redirect for legacy Help links. The app repo's project Pages site stays disabled. New appcast entries use `Nininunz/Clerestory` release download URLs. Preserve earlier signed entries and legacy download paths for cached feeds and older installations.

The public Sparkle Ed25519 key lives in [Info.plist](../OpenYoink/App/Info.plist). The matching private key stays in the maintainer’s Keychain. Back it up securely outside the repository. The release script checks the public key against the Keychain account before building and signs the final DMG with that account. Upstream OpenYoink releases use a different key and feed.

## Signing setup

Use a Developer ID Application identity, an Apple notarization profile in Keychain, and the fork’s Sparkle signing key. Copy [the signing example](../Scripts/release-signing.example) to the ignored `Scripts/release-signing.local` and configure `DEVELOPER_ID_APPLICATION`, `DEVELOPMENT_TEAM_ID`, and `NOTARY_PROFILE`, or provide them in the environment. The release and notarization scripts load the local file. The example lets existing environment values take precedence. Keep passwords and private keys in Keychain.

Run `Scripts/doctor.sh --release` to check tool availability, Developer ID signing, and notarization access. Set `SPARKLE_BIN` if the Sparkle tools are in a custom DerivedData location.

## Build, verify, and publish

Choose a release version and a build number higher than the latest public build. In the commands below, set `version` and `build` to those values.

1. Build a local candidate with `OPENYOINK_RELEASE_CANDIDATE=1 Scripts/make-release.sh "$version" "$build"`. This signs and notarizes the artifact and writes unpublished metadata to `export/appcast-candidate.xml`. The DMG lands under `export/`. Choose a higher build when testing an update from an already installed candidate.
2. Run the build and test checks in the [CI guide](../Scripts/README-ci.md) and the relevant [manual smoke checks](MANUAL_TESTING.md). Test installing the signed DMG and launching the app in an appropriate test account. Check code signing, notarization stapling, and both architectures. Use supported Intel hardware to verify execution there when available.
3. Build the public package with `Scripts/make-release.sh "$version" "$build"`. Use the Developer ID build for public distribution. The script produces the signed DMG and writes its Sparkle signature and length to `docs/appcast.xml`. Publish the exact DMG referenced by the appcast to the matching GitHub release. Merge the signed appcast entry into `main`.
4. Run `Scripts/publish-update-feed.sh` from a checkout with write access to the account Pages repository. It reads the merged appcast, verifies the new release archive and signature, and checks that the deployed bytes match. Then run `Scripts/verify-update-feed.sh "https://nininunz.github.io/OpenYoink/appcast.xml" "$version"` to check the public download, signature, and bundled app.
5. Confirm Sparkle discovers the update from an earlier signed install using the public feed. Seed disposable Shelf items and a preference first. After installation and relaunch, verify the new build and confirm that the data and setting survived. Record the results with the release evidence.

## Existing installations

Earlier releases of the Nininunz fork share Clerestory’s bundle ID and data container. Sparkle upgrades an existing copy in place. To change an older copy’s filename from `OpenYoink.app` to `Clerestory.app`, quit it and rename the installed bundle in Finder.

Upstream OpenYoink and development builds with different bundle IDs use separate sandboxes. Clerestory has no automatic import for those containers. Keep a backup of the original data before switching builds. Managed paths and security-scoped bookmarks can require relinking or fresh authorization.

See the [first release notes](releases/first-fork-release.md) and [initial validation record](releases/validation-2026-11-17.md) for historical release and test evidence.
