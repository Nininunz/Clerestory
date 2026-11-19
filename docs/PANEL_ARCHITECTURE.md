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
| [IslandMessageCenter](../Clerestory/Messages/IslandMessageCenter.swift) and [IslandNoticePanelController](../Clerestory/Messages/IslandNoticePanelController.swift) | Hold the statuses modules set and the notices they post through a `ModuleMessenger`. Notices (the visible one plus up to four waiting) are spoken when they are posted and shown in the notice pill's own window. A notice lasts 4 s, or 8 s with a button, counting only time on screen. Every module's notices, including those from the Clipboard History window, show in this one pill. |
| [IslandNotchIndicatorResolver](../Clerestory/Messages/IslandNotchIndicator.swift) | Chooses the Notch's leading icon, tint, and VoiceOver suffix from the message center. |

## Statuses, notices, and the Notch

Modules tell the user things in two ways. A **status** stays true until its module clears it, such as "Battery low" or "Timer finished". A **notice** reports something that just happened, such as "Power connected" or "Already on Shelf". Each module writes both through its own `ModuleMessenger`, so it can only change its own messages. `IslandMessageCenter` keeps statuses and notices in separate stores, so a notice can never remove a status. A lasting condition on a module's own page, such as a load failure, is an `IslandStatusRow` in that page rather than a message. [How a module posts a message](development/MODULE_MESSAGES.md) shows the API.

- **Statuses.** Each module has its own set of statuses, by key. `setStatuses` replaces the whole set in one change, and setting an equal value changes nothing. The module container calls `moduleDidStart` before a module's `start()` and `moduleDidStop` after its `stop()`. Statuses from a module that has not started are ignored, and stopping a module clears its statuses and its waiting notices. A notice already on screen finishes. Notices are never gated, so Shelf can post startup notices before any module starts.
- **Raising.** A status is raised when it is new, its tone goes up, or its tone stays the same and its level goes up. The level orders statuses of the same tone; a higher level means the condition got worse, such as "Battery critically low" after "Battery low". A raised warning or critical status is spoken once and shows its text once in the notice pill, unless the open Panel already shows its module. That pill is withdrawn if the Panel opens on its module or the status clears first. Any other change is silent: a new title or detail, such as 18% becoming 17%, or a lower level. Within a module, the top status has the highest tone, then the highest level, then the latest raise. Statuses can expire on the center's clock, and a dismissible status stays hidden while its module keeps setting it.
- **The shown module.** While an unpinned Panel shows a module, notices from other modules wait for it to close. A notice from the shown module goes ahead of them, and the 2 s handoff only shortens the visible notice when the next one could appear right away. `IslandNoticePanelController` feeds the center the shown module from the same context `IslandNoticePresentation` uses.

The Notch shows statuses as its leading icon, tint, and VoiceOver label. For the module it displays, the first match wins: its notice on screen (a notice that waits, for example during a drag or behind an unpinned Panel, does not count; `IslandNoticePanelController` reports the notice on screen with `setVisibleNotice`); the drag arrow, when it displays Shelf during a drag; its warning or critical status; any other module's critical status, in red; its neutral or progress status. Otherwise it shows the module's default icon at reduced opacity. Critical is red, warning orange, progress the accent colour, and neutral white. Only critical statuses are borrowed from other modules, so a low battery stays red whatever the Notch displays. The VoiceOver label adds the status the icon shows, for example "Battery, 15 percent, Battery low", and keeps it while a notice or the drag arrow covers the icon: "Battery, 15 percent, Battery low, Power connected, 15%". A drag is `IslandActivityCoordinator.isDragInProgress`, not a status.

The module container only starts and stops modules; there is no event stream. Each module writes through the messenger it was given, so a module that stops and starts again keeps updating. What each module writes:

- **Battery:** on every sample, the critical "low" status at 20% or below: "Battery low" at level 0, "Battery critically low" at 10% or below at level 1. Falling into the lower band announces again; charging out of it is silent. Power, Low Power Mode, and full-charge notices last 2.5 s.
- **Timer:** a neutral "running" status while it runs or is paused, and a warning "finished" status when it ends, which is announced once. `IslandTimerStore.onDidFinish` runs once when a timer finishes, and once at launch for a timer that finished while the app was quit; ShelfWindowController opens the Panel on Timer from there unless the Panel is pinned, Timer is unavailable, or there is no Panel display. The open Panel then withdraws the "Timer finished" pill.
- **Now Playing:** a neutral "playing" status with the track, which follows each snapshot.
- **Clipboard History:** "copy" ("Copied to Clipboard" or "Copy failed") and "favorites-limit" notices, in the notice pill under the notch or below the open Panel, also when they come from the Clipboard History window. Full history storage and load or save failures are status rows in the Panel and the window. Storage full clears after the next recorded copy or Clear History.
- **Transfers:** one "transfer" status, in progress tone while a task runs and warning tone when it fails. `TransfersModuleRuntime` observes the current task, so the status follows phase changes as well as the strip appearing and disappearing. It is never announced: TransferStore's strip shows the transfer, and ShelfWindowController speaks it.
- **System Status:** on every sample, the whole set of thermal, memory pressure, disk space, and app resource warnings, all in warning tone. Thermal, memory, and disk warnings are announced once when raised. Critical memory pressure and a critical thermal state are level 1, so getting worse announces once and improving is silent. App resource alerts are not, and they last until the next sample. **Ignore Once** dismisses that status in the center, which hides it until its condition clears and returns.
- **AI Usage:** when a limit crosses a threshold, a warning "limit.<window>" status that expires after 10 minutes. Its level is the threshold (0 for 80%, 1 for 95%), so crossing 95% raises it again. Its raise is the one pill and the speech. A refresh that fails while older data is shown is a status row with **Retry**.

The visible Panel surface defines the hit area. Native hit testing and the drag outline use the same rounded geometry as the surface. Shadow margins stay transparent to clicks and file drops. File drags show a complete blue outline, and duplicate drags show a red one. The notice pill anchors to the visible surface, below its bottom edge.

## Previews and validation

Use the [module preview generator](development/PREVIEWS.md) to render a fresh gallery from the current checkout. It uses synthetic data and the production module host. The [native UI-test guide](development/UI_TESTS.md) covers keyboard focus, window lifecycle, and cross-app drag and drop. The [manual testing guide](MANUAL_TESTING.md) covers real source and destination apps, physical displays, and file recovery.
