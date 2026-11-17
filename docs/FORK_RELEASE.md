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
2. Set up your own Developer ID Application certificate, Apple team ID and
   notarization profile. These are separate from the Sparkle update key.
3. Resolve and test the development-data migration above if retaining that data.
4. Build using `Scripts/make-release.sh` with `DEVELOPER_ID_APPLICATION`,
   `DEVELOPMENT_TEAM_ID`, and `NOTARY_PROFILE`. Do not publish ad-hoc artifacts.
5. Upload the signed/notarized DMG to this fork's matching GitHub release, then
   deploy the generated feed. Validate with `Scripts/verify-update-feed.sh`.
6. Test a real update between two signed fork builds, including relaunch and
   persistence. Source checks do not establish that end-to-end updates work.

No release, feed deployment, or Apple signing identity is created by this change.
The Pages hosting configuration is enabled.
