# Unified Island panel

Current review baseline for `codex/separate-expanded-panel`, following the [separate-panel prototype](../../prototypes/separate-expanded-panel/README.md). The prototype remains a historical checkpoint; this document describes the unified implementation.

## Behavior and ownership

- Every display uses the same floating expanded panel, rounded surface, content padding, toolbar, and animation. Hardware geometry determines placement, not a second expanded presentation.
- A notched display can additionally show compact Island. **Settings → General → Show Compact Island** controls that companion. The preference is preserved when a selected display has no notch.
- Without compact, the top-center screen edge is the pointer trigger. Hover and click triggers each respect their own settings. File/text drag approach remains independent of hover reveal.
- Expanded shortcuts use one left-to-right configuration with up to eight positions. Visible capacity follows enabled modules, and Quick Settings occupies one required, movable position. Existing floating positions win the one-time migration; otherwise saved positions migrate in visual order. Compact ordering remains separate.
- `IslandCompactView` renders the companion; `IslandExpandedView` renders the expanded content. `IslandPresentationController` owns placement, native window coordination, and hover/swipe behavior. `ShelfWindowController` retains Shelf imports, keyboard routing, and the shared drag-host factory.
- `IslandSurfaceAnimationHost` keeps content mounted until closing finishes. A new opening cancels a stale close completion. One reveal value drives the background, border, shadow, and content mask.
- Activating the compact companion preserves an existing pin while selecting its module; reopening an unpinned panel does not pin it.
- The shadow has drawing room outside the interactive surface. Those transparent margins do not accept clicks or file drops. Native hit testing uses the same continuous corner path as the visible surface, verified at regular and extended heights. Detached Shelf notices anchor to the visible panel, not its shadow canvas.
- File drags show a complete blue outline; duplicate drags show red. Insets use the same continuous rounded shape as the panel, including intermediate animation sizes.

## Automated validation — 2026-11-16

- **860 app tests passed**, with preview export run separately. Includes preference migration, display selection, compact visibility, click-trigger settings, shared module layout, drop bounds, rendering geometry, and interrupted close/reopen behavior.
- **146 preview captures exported successfully**: 140 Shelf and six Quick Settings images, covering regular/extended heights, complete blue/red drag outlines, notices, and transfer/recovery states. Representative populated, extended, outline, and Quick Settings captures were visually inspected; the entire gallery is available for review.
- **11 module-core tests passed**, including parameterized shortcut capacities from zero through twelve enabled modules, fixed positions, required Quick Settings, and persistence.
- The corner rendering regression failed with the old inset geometry and passed after using SwiftUI's rounded-shape inset. It compares both drag colors and all four corners at five reveal sizes against an independent rounded-rectangle reference.
- Xcode app tests exited successfully. Existing compiler warnings remain; this change does not claim a warning-free build.
- Native UI-test runner is not included in these counts. The previous runner could not establish its connection; app tests and the production-host rendering fixture are distinct from end-to-end UI coverage.

Commands from the repository root:

```sh
swift test --package-path Packages/OpenYoinkModuleCore
xcodebuild test -quiet -project Open-Yoink.xcodeproj -scheme OpenYoink \
  -destination 'platform=macOS' -derivedDataPath /tmp/openyoink-derived \
  -only-testing:OpenYoinkTests -skip-testing:OpenYoinkTests/IslandModulePreviewTests \
  CODE_SIGNING_ALLOWED=NO
Scripts/render-module-previews.sh --module shelf --module quick-settings \
  --capture snapshot --output /tmp/openyoink-unified-panel-review --no-open
```

## Preview scope

The gallery uses synthetic files and isolated stores with the production module host, expanded surface, height resolver, and drag-outline renderer. Shelf and Quick Settings include regular and extended states. Navigation space is reserved; these module captures do not show live shortcut buttons, the compact companion, or the native window shadow. Snapshot capture does not prove blur/material fidelity, hover timing, scrolling, window stacking, or animation. Live rendering tests cover intermediate animation states separately.

The full generated gallery and manifest are local artifacts under `/tmp/openyoink-unified-panel-review`. The representative images below are tracked so a reviewer can inspect the resulting layout without running the app.

## Live acceptance matrix

Record outcomes separately from fixture/test passes. A simulated notchless display does not substitute for physical monitor attachment, scaling, or Spaces behavior.

| Check | Required observation | Status |
| --- | --- | --- |
| Compact enabled | Compact remains at cutout while expanded opens independently | Companion observed; expanded interaction still unverified |
| Compact disabled | No compact companion; top-edge reveal still works | Settings toggled off/on; top-edge reveal unverified |
| Simulated notchless | Same expanded layout; compact unavailable, preference retained | Preference and explanatory Settings state verified; live reveal unverified |
| Shelf keyboard / Quick Look | Selection, arrows, Space, and Escape stay in the intended window | Pending live check |
| Pin and menus | Pinned panel survives leaving; open menus do not cause collapse | Pending live check |
| File/text drag and duplicates | Approach opens Shelf, drops succeed, duplicate feedback follows release | Pending hands-on check |
| Hover travel and rapid reentry | Gap stays open; leaving closes; reentry interrupts closing safely | Pending hands-on check |
| Show Desktop and Spaces | No stuck or misplaced panel; dragging still works afterward | Pending physical gesture check |
| External display / reconnect | Placement, fallback, and optional compact follow the chosen display | Pending physical display check |
| Reduce Motion / VoiceOver | Immediate reveal with correct focus and readable controls | Pending accessibility check |

Live automation could read and change Settings but did not reliably target the separate expanded window after compact clicks or the keyboard reveal attempt. This is an inconclusive smoke check, not proof of an app failure or a pass. Only the development executable was running. The temporary global-hotkey and notchless-simulation changes were restored; compact remains enabled. Live drag, Quick Look, pin/menu, and hover-travel checks remain outstanding.

## Refreshed captures

| Shelf regular | Shelf extended |
| --- | --- |
| ![Shelf regular](shelf-populated-regular.png) | ![Shelf extended](shelf-populated-extended.png) |

| File drag | Duplicate drag |
| --- | --- |
| ![Complete blue drag outline](shelf-file-drag-regular.png) | ![Complete red duplicate outline](shelf-duplicate-regular.png) |

| Quick Settings regular | Quick Settings extended |
| --- | --- |
| ![Quick Settings regular](quick-settings-default-modules-regular.png) | ![Quick Settings extended](quick-settings-default-modules-extended.png) |

Quick Settings' default-modules fixture enables the experimental gate for configuration coverage. That does not change the app's default gate setting.
