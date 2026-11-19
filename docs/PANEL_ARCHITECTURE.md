# Panel and Notch architecture

## Display placement and triggers

Clerestory uses the same floating Panel on every display. It opens on the display where it was triggered and stays there until dismissed unless that display disconnects. Display geometry determines placement and available height. The toolbar, rounded surface, content padding, and reveal animation are shared.

The optional Notch companion lives in its own non-key window on the built-in notched display. **Settings → Notch → Show in notch** controls its visibility. The preference is retained on hardware without a notch. Activating the Notch selects its module in the Panel and preserves an existing pin.

When the Notch is unavailable or hidden on the triggering display, the top-center edge is the pointer trigger. Hover and click have independent settings. File and text drag approach can open Shelf even when hover reveal is off. An open Quick Look session pauses hover dismissal.

## Settings and shortcuts

- **General** contains startup, menu bar icon, and update settings.
- **Panel** contains hover, click, and drag behavior, delay controls, the Shelf shortcut, shortcut positions, and ignored apps.
- **Notch** contains companion visibility, the cycling shortcut, and module inclusion and order.
- **Modules** contains the experimental feature gate, module enablement, and module-specific settings. **Storage**, **About**, and **Debug** (in debug builds) have dedicated pages.

Panel shortcuts use a single left-to-right layout with up to eight positions. Visible capacity follows the enabled modules, and Quick Settings occupies one required, movable position. Panel shortcut positions and Notch order are independent. Quick Settings uses the same editors and saved preferences as the Settings window. Legacy shortcut positions migrate once, with saved floating positions taking precedence. The Notch rename preserves the existing preference keys, module identifiers, and accessibility identifiers.

## Code ownership

| Component | Responsibility |
| --- | --- |
| [IslandPresentationController](../Clerestory/Island/IslandPresentationController.swift) | Display selection, native window coordination, hover behavior, and shortcut swipes. |
| [IslandWindowControllers](../Clerestory/Island/IslandWindowControllers.swift) | Separate native windows for Panel and Notch. |
| [IslandExpandedView](../Clerestory/Island/IslandModuleViews.swift) and [IslandNotchView](../Clerestory/Island/IslandNotchView.swift) | Render Panel content and the Notch companion. |
| [IslandSurfaceAnimationHost](../Clerestory/Island/IslandSurfaceAnimationHost.swift) | Drives surface reveal and keeps content mounted until closing completes. Reopening invalidates a pending close. |
| [ShelfWindowController](../Clerestory/Shelf/ShelfWindowController.swift) | Shelf imports, keyboard and Quick Look routing, and the shared drag-host factory. |

The visible Panel surface defines the hit area. Native hit testing and the drag outline use the same rounded geometry as the surface. Shadow margins stay transparent to clicks and file drops. File drags show a complete blue outline, and duplicate drags show a red one. Detached Shelf notices anchor to the visible surface, below its bottom edge.

## Previews and validation

Use the [module preview generator](development/PREVIEWS.md) to render a fresh gallery from the current checkout. It uses synthetic data and the production module host. The [native UI-test guide](development/UI_TESTS.md) covers keyboard focus, window lifecycle, and cross-app drag and drop. The [manual testing guide](MANUAL_TESTING.md) covers real source and destination apps, physical displays, and file recovery.
