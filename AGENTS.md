# Agent instructions for Clerestory

Clerestory is a sandboxed macOS 15+ menu bar app (SwiftUI and AppKit) with a Panel at the top of the screen, an optional Notch companion, a Shelf, and optional modules. It is derived from [OpenYoink](https://github.com/MuQY1818/OpenYoink) by weijue (MIT). These instructions apply to anyone changing this repository, human or agent. [CONTRIBUTING.md](CONTRIBUTING.md) covers the same workflow for people.

## Layout

- `Clerestory/`: the app, by area: `App`, `Island` (Panel, Notch and modules), `Messages` (the shared notice pill and message center), `Shelf`, `DragDrop`, `Clipboard`, `Settings`, `Services`, `Resources`.
- `ClerestoryTests/` and `ClerestoryUITests/`: unit tests and native UI tests.
- `Packages/ClerestoryModuleCore/`: the Foundation-only module model shared by the app.
- `Helpers/LowPowerMode/`: the optional privileged helper ([guide](docs/LOW_POWER_MODE_HELPER.md)).
- `Scripts/`: build, test, release and maintenance scripts. `python3 Scripts/tree.py` lists the layout.
- `docs/`: guides, indexed in [docs/README.md](docs/README.md).

## Terms

| Term | Meaning |
| --- | --- |
| Panel | The floating surface at the top of the screen. Code still calls it the Island (`Island*` types, `Clerestory/Island/`). Use "Panel" in anything users see. |
| Notch | The optional companion on a built-in notched display. |
| Shelf | The core module that holds files, text, links and images. |
| Module | A Panel feature: Shelf, Quick Settings, and optional (experimental) modules such as Battery, Timer and Clipboard History. |

## Before you open a pull request

- Run `Scripts/test-ci.sh`. It mirrors the required CI check: identity check, module-core package tests, Release build, and unit tests in parallel. Pass a phase (`identity`, `module-core`, `release`, `unit-tests`) to run one part. See [docs/development/CI.md](docs/development/CI.md).
- Add or update tests for behavior changes. Native UI tests (`Scripts/test-ui.sh`) need a logged-in desktop; run them when you change window, hover, drag or Settings behavior.
- Say in the PR what you verified and what you could not, for example hardware, a signed build, or the Low Power Mode helper.

## Git and pull requests

- Branch from `main`. Name branches `<owner>/<short-topic>`, for example `codex/shelf-search-layout`.
- Keep each PR to one change. Pull requests merge with a merge commit, not a squash.
- Commit subjects are short and imperative ("Keep Shelf search controls fixed"). The body explains what changed and why, and ends with `Refs #123` or `Closes #123` when there is an issue.
- PR titles follow the same style. Fill in the PR template: Summary, Related issue, Verification.
- Documentation-only changes (root Markdown, `docs/` except `docs/appcast.xml`, issue and PR templates) skip the macOS build jobs in CI. Every merge to `main` gets the full optimized universal Release build.

## Code and text

- Swift 6. Follow the isolation patterns already in the file you are changing (`@MainActor` types, `nonisolated` helpers and AppKit bridge classes).
- Write code comments and developer docs in English.
- English is the only language for now; localization is planned but low priority (#16). Keep all user-facing text localizable so adding a language later is only translation work: use `String(localized:)` or SwiftUI string literals, and add a manual `en` entry for each new string to `Clerestory/Resources/Localizable.xcstrings` in the same change. Don't add a language without a native-speaker reviewer who can keep it up to date.
- Do not add dependencies without discussing it first. Package versions are pinned in `Clerestory.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`; update them through Xcode and run `Scripts/test-ci.sh`.
- Keep the README and `docs/` accurate in the same PR that changes the behavior they describe.

## Privacy and safety

- The app is sandboxed. It only touches files the user drags in or picks, and it never opens files that were only copied to the clipboard.
- The only background network traffic is Sparkle update checks. Do not add analytics, telemetry or other network calls.
- Clipboard History records nothing until the user turns on Record Clipboard, and skips copies marked private by password managers.
- The Low Power Mode helper runs as root. Changes to `Helpers/LowPowerMode/` or its XPC client need a security review.

## Do not change without asking

- Bundle identifiers (`com.nininunz.Clerestory` and its test targets) and the helper identifier `com.nininunz.Clerestory.LowPowerMode`.
- The Sparkle setup: `SUFeedURL` and `SUPublicEDKey` in `Clerestory/App/Info.plist`, and the signing Keychain account `com.nininunz.OpenYoink`. That account name only identifies where the signing key is stored; renaming it breaks release signing.
- The build-number floor: new releases use build 61 or higher (see [docs/RELEASING.md](docs/RELEASING.md)).
- License and attribution: weijue's copyright notice in `LICENSE`, the bundled copy `Clerestory/Resources/Clerestory-LICENSE.txt` (it must match `LICENSE`; `Scripts/check-identity.py` checks this), the OpenYoink credit in the README and About, and the license texts in `THIRD_PARTY_NOTICES.md`.

## Ported code

Code adapted from upstream OpenYoink keeps its MIT attribution. Credit it in the commit message, for example "Adapted from MuQY1818/OpenYoink@7bb6c34 (weijue, MIT).", and list any intentional differences from upstream.

## Issues and labels

- `bug` for defects, `enhancement` for features and improvements.
- `priority: low` for useful work that is deferred and not a release blocker.
- `help wanted` for checks that need hardware or setups the maintainer doesn't have, such as Intel Macs or multiple displays.
- Larger efforts use one tracking issue with a checklist, linked from each PR with `Refs #123`.
