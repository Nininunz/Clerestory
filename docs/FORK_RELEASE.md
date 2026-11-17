# Fork release ownership

This fork is maintained at https://github.com/Nininunz/OpenYoink and derives
from https://github.com/MuQY1818/OpenYoink. The original MIT license and
contributor attribution remain intact. The app name remains OpenYoink.

## Identity and updates

- App bundle ID: `com.nininunz.OpenYoink` (test targets use the same namespace).
- Feed: `https://nininunz.github.io/OpenYoink/appcast.xml`.
- Downloads and bug reports go to Nininunz/OpenYoink.
- Sparkle Keychain account: `com.nininunz.OpenYoink`.
- Only the public Ed25519 key is stored in `OpenYoink/App/Info.plist`.
  The private key was generated in the maintainer's login Keychain. Back it up
  securely before distributing a release; never add it to this repository.
- `make-release.sh` checks the public key before building and explicitly uses
  this Keychain account when signing the final DMG.

The feed starts empty. Upstream releases use another signing key and must not
be advertised as fork updates. The first fork build defaults to 52, above the
inherited development build 51. Choose the public version before publishing.

For a local signed/notarized candidate without changing the public feed or badges:

```sh
OPENYOINK_RELEASE_CANDIDATE=1 Scripts/make-release.sh 1.8.11 52
```

Candidate metadata is written to `export/appcast-candidate.xml`; the DMG remains
under `export/`. This still submits the artifact to Apple for notarization, but
does not upload it to GitHub or deploy an update feed. Set `SPARKLE_BIN` if the
Sparkle tools are in a custom DerivedData location. Choose a new build number
when creating a subsequent candidate intended to update an installed one.

## Existing development data

Changing the bundle ID creates a separate sandbox. It does not migrate or
delete the old sandbox at `~/Library/Containers/com.weijue.OpenYoink`.
Saved preference key names are unchanged, but their preferences domain changes.
Do not replace the working development app expecting automatic migration.

Before switching the daily-use app, quit both copies and back up the old
container. A migration must import preferences into the new domain, transfer
Application Support/OpenYoink, and handle absolute managed-file paths and
security-scoped bookmarks. Bookmarks may require reauthorization under the new
identity; copying the container alone is not a supported migration. Keep the
old data until files, snippets, clipboard history and settings are verified.
Automatic migration is not implemented by this identity change.

## Before the first public release

1. GitHub Pages is configured with the GitHub Actions source for this fork. The existing
   Pages workflow builds the website and copies `docs/appcast.xml` to its root.
   Deploy after these changes merge; configuring Pages alone does not deploy the feed.
2. Release signing is configured locally using the Developer ID Application
   certificate for team `8KB55P2YKQ` and Keychain profile `OpenYoink-notary`.
   These are separate from the Sparkle update key. Other machines must provision
   their own access and copy `Scripts/release-signing.example` to the ignored
   `Scripts/release-signing.local`, adjusting the identifiers as needed.
   Both release and notarization scripts load that file; explicit environment
   variables override its defaults. Never store passwords or private keys there.
3. Resolve and test the development-data migration above if retaining that data.
4. Build using `Scripts/make-release.sh` with `DEVELOPER_ID_APPLICATION`,
   `DEVELOPMENT_TEAM_ID`, and `NOTARY_PROFILE`. Do not publish ad-hoc artifacts.
5. Upload the signed/notarized DMG to this fork's matching GitHub release, then
   deploy the generated feed. Validate with `Scripts/verify-update-feed.sh`.
6. Test a real update between two signed fork builds, including relaunch and
   persistence. Source checks do not establish that end-to-end updates work.

The Developer ID certificate is installed in the maintainer's login Keychain
(expires December 17, 2027), and the notarization profile has been validated
with Apple. Pages hosting is configured. No public release or feed deployment
has been performed. Local candidate `1.8.11 (52)` passed Apple notarization,
DMG ticket stapling, Gatekeeper checks for both the DMG and mounted app, and
Sparkle signature verification. The candidate is universal (arm64 and x86_64).
An actual installed-app update and daily-use data migration still need testing.
