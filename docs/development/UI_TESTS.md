# Native UI tests

For automated PR builds and unit tests, see the [macOS CI guide](CI.md). This native UI suite remains a separate local check.

See the [manual testing guide](../MANUAL_TESTING.md) for Finder and browser workflows, hardware checks, and file recovery.

Run `Scripts/test-ui.sh` from a logged-in macOS desktop. XCTest launches the real app and interacts with its native controls. Quit other Clerestory and OpenYoink builds first and avoid using the mouse or keyboard during the run. The suite fails its preflight if a different build is running, because overlapping Islands can intercept clicks and drops. It never quits your normal app automatically.

The script uses local ad-hoc signing, verifies the app, runner, and drag helper signatures, then runs `ClerestoryUITests` serially. Do not use `CODE_SIGNING_ALLOWED=NO` for this suite: Xcode repackages its runner, and leaving that bundle unsigned can produce macOS's “damaged and can't be opened” alert before tests begin. No signing account is required. During test execution, `caffeinate` keeps the display/system awake and XCTest enforces a 60-second default test budget (90-second maximum); neither changes saved power settings.

By default, each invocation creates a temporary DerivedData directory and prints its path. To reuse a successful build directory:

```sh
OPENYOINK_UI_DERIVED_DATA=/tmp/openyoink-ui-signed Scripts/test-ui.sh
```

Results, screenshots, failure hierarchies, and screen recordings are in that directory's `Logs/Test/*.xcresult` bundles. A failed test must remain a failure; runner startup failure is not a skipped or passed test. If macOS has rejected an old runner, cancel its alert and use a fresh build directory.

## Isolation and launch controls

`OPENYOINK_UI_TESTING=1` selects a reset defaults suite and a fresh temporary application-support directory for each app process. The unique directory is selected before services initialize, so a previous test cannot leak in-memory Shelf items into the next launch. It also suppresses onboarding, updates, and global trigger registration. Normal Island presentation and event handling remain active. Tests temporarily take over the app's bundle identity, so relaunch your development build after the suite.

- `--ui-testing-show-shelf` opens the production expanded Island with keyboard focus, not the disabled side shelf.
- `--ui-testing-open-settings` opens General settings.
- `--ui-testing-hover` starts collapsed with hover reveal enabled in the isolated preferences.
- `--ui-testing-shelf-files` seeds two synthetic text files for keyboard and Quick Look coverage (Debug only).
- `--ui-testing-drag-source` enables the production drag monitor (Debug only). The tests launch the separate `ClerestoryUITestDragSource` helper app, which creates disposable file/text payloads and starts native mouse drag sessions. Drops use the production receiver, import pipeline, and duplicate handling; internal-drag rejection stays unchanged. The helper is a UI-test target dependency with `SKIP_INSTALL=YES`, not part of the shipped app.
- `--ui-testing-hide-compact` suppresses the optional companion in the isolated preferences.
- `-OpenYoinkSimulateNoNotch YES` overrides notch detection for that process through the argument domain, without changing the saved debug preference.

The app exposes `island.window.expanded` and `island.window.compact`. Query by identifier across accessibility element types: AppKit exposes these borderless panels as dialogs, so `app.windows` misses them. Expanded controls have stable `island.pin`, `island.collapse`, and `island.module.<moduleID>` identifiers.

## Coverage and limits

The suite covers empty Shelf launch, module navigation, pin/unpin, compact activation retaining the pin, hover open/leave/reopen and remaining open while pinned, collapse, compact-off and simulated-notchless presentation, Settings navigation, separate Panel/Notch destinations and preference retention, General/Panel/Shelf settings pickers, a core accessibility audit, native cross-app file/text drops with hover reveal disabled, duplicate feedback after release without adding a second item, and Quick Look Space/arrow/Escape navigation with focus returned to Shelf. The compact activation, hover, and drag-approach cases explicitly skip on hardware without a notch; a missing companion on notched hardware fails.

The drag cases exercise approach below the notch display, the native pasteboard/session, and real imports from a separate helper app. Pinned duplicate feedback is checked for a nonempty, finite frame below the visible panel, with the pin retained and no extra file card. Repeated hover reentry is checked within a configured one-second leave grace. These do not replace Finder/browser-specific checks (file promises, Show Desktop, sandbox permissions), subframe animation inspection, physical Spaces gestures, or external-display reconnect. Static module previews and unit tests remain separate from this native UI suite.

## Latest verified run

2026-11-17, Notch naming: four native checks passed with zero failures or skips: Notch settings labels and preference retention, notch activation retaining the pin, panel behavior with the notch display disabled, and Quick Settings navigation/collapse. Result: `/tmp/openyoink-ui-signed/Logs/Test/Test-OpenYoink-2026.11.17_15-11-28--0600.xcresult`. Release build, 866 app unit tests, and 11 package tests passed; legacy preference keys are explicitly covered. The renamed development build was reopened.

2026-11-17, settings cleanup: focused native checks passed for separate Panel/Notch destinations and retained toggle state, General/Panel/Shelf picker menus, the core accessibility audit, and Quick Settings navigation. The first runner location timed out enabling macOS automation; rerunning from `/tmp/openyoink-ui-signed` worked. Results: `Test-OpenYoink-2026.11.17_05-40-48--0600.xcresult` (three passing existing cases) and `Test-OpenYoink-2026.11.17_05-42-08--0600.xcresult` (new navigation case after correcting the checkbox assertion). The Release build, 11 package tests, and 865 app unit tests also passed.

2026-11-17, final pre-merge run: `Scripts/test-ui.sh` passed all 14 native UI tests with zero failures, including both follow-up regressions and the unpin fix. App, runner, and helper signatures passed verification. Result bundle: `/tmp/openyoink-ui-signed/Logs/Test/Test-OpenYoink-2026.11.17_04-28-23--0600.xcresult`. The development app was reopened afterward. PR CI runs the Xcode 27 main check; Xcode 26 compatibility is manual-only, and native UI tests remain local.

2026-11-17: `Scripts/test-ui.sh` completed all 12 UI tests with zero failures in 148.7 seconds on the notched development Mac. App, runner, and helper signature verification passed. The local result bundle is `/tmp/openyoink-ui-signed/Logs/Test/Test-OpenYoink-2026.11.17_03-51-58--0600.xcresult`.

After the unpin fix, all 39 `IslandActivityCoordinatorTests` and the updated native hover test passed. The latter now verifies pin → leave → return → unpin → leave dismisses the panel, then hover reopens it. Its result bundle is `/tmp/openyoink-ui-signed/Logs/Test/Test-OpenYoink-2026.11.17_04-09-42--0600.xcresult`. The development build also passed; the toolbar Settings action and Quick Settings header height control were checked live.

Follow-up live checks on 2026-11-17 passed pinned duplicate placement and three hover exit/reentry cycles (`Test-OpenYoink-2026.11.17_04-17-35--0600.xcresult`). The pinned case was rerun with explicit finite/nonempty geometry assertions and a full-screen capture; it passed and the capture was visually inspected (`Test-OpenYoink-2026.11.17_04-19-23--0600.xcresult`, whose separate Finder setup case failed).

Finder-after-Show-Desktop passed manual verification on 2026-11-17: the user clicked the wallpaper to reveal Desktop, then dragged files toward the reopened development app repeatedly and confirmed that every drop expanded the Island and was accepted. This is a user-verified result, not an automated pass. Direct fixture creation had been blocked by the test runner's sandbox; Finder UI fixture setup succeeded, but XCTest then attempted to scroll the desktop and reactivate windows, invalidating the automated scenario. That unreliable experimental test was removed. Its disposable Desktop file was removed, and the normal development app was reopened.
