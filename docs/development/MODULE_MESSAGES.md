# How a module posts a message

A module tells the user about itself in three ways. Pick by one rule: **if it will still be true in a minute, it is a status; if it describes something that just happened, it is a notice.** A lasting condition that belongs on the module's own page, needs a control there, or stays until the user fixes it, is an `IslandStatusRow` in the page instead.

| What | Example | Where it shows | API |
| --- | --- | --- | --- |
| Status | "Battery low", "Timer finished", "Disk space is low" | The Notch's icon, tint and VoiceOver label; once in the notice pill when raised | `ModuleMessenger.setStatus`, `setStatuses`, `clearStatus` |
| Notice | "Power connected", "Copied to Clipboard", "You can keep up to 30 favorites." | The notice pill, until it times out | `ModuleMessenger.post` |
| Status row | "History storage is full…", AI Usage's refresh failure with **Retry** | The module's own page, while the condition holds | `IslandStatusRow` (plain view content) |

[Panel and Notch architecture](../PANEL_ARCHITECTURE.md#statuses-notices-and-the-notch) describes how the message center queues, raises and shows them.

## Getting a messenger

Each module writes through its own `ModuleMessenger`, so it can only change its own messages. Stores take one in their initializer or through a `messenger` property, defaulting to `ModuleMessenger.inert`, which goes nowhere:

```swift
init(..., messenger: ModuleMessenger = .inert)
```

The app's one `IslandMessageCenter` lives in AppDelegate. ShelfWindowController (or AppDelegate, for stores it creates) passes `messages.messenger(for: .yourModule)`. Previews and tests that don't care keep `.inert`; tests that do use `IslandMessageCenter.forTesting()` with a `ManualMessageClock`, and previews use `IslandMessageCenter.preview(notice:from:)`.

## Statuses

```swift
// Replace the module's whole set in one change, for example on every sample.
messenger.setStatuses(percent <= 20
    ? [IslandStatus(key: "low", title: "Battery low", detail: "\(percent)%",
                    systemImage: "battery.25percent", tone: .critical, level: percent <= 10 ? 1 : 0)]
    : [])

messenger.setStatus(IslandStatus(key: "running", title: "Focus", systemImage: "timer"))
messenger.clearStatus("running")
```

- `key` only has to be unique within the module.
- `tone` is `neutral`, `progress`, `warning` or `critical`. It sets the Notch tint: white, accent, orange or red. Only a critical status shows when the Notch displays another module.
- `level` orders statuses of the same tone. A higher level means the condition got worse.
- A status is *raised* when it is new, its tone goes up, or its level goes up at the same tone. A raised warning or critical status shows its text once in the pill and is spoken, unless `announcesWhenRaised` is false or the open Panel already shows the module. A title or detail change alone is silent. The pill has a **Show** button (`.openModule`) that opens the Panel on the module, which withdraws the pill.
- Setting an equal value changes nothing. Statuses are ignored until the module has started, and stopping the module clears them.
- `isDismissible` lets the module's page hide one with `messenger.dismissStatus(key)` until it clears. `expiresAt` (from `messenger.expiry(after:)`) removes one on the center's clock.

## Notices

```swift
messenger.post(IslandNotice(key: "copy", title: String(localized: "Copied to Clipboard"), tone: .success))
messenger.post(IslandNotice(key: "power", title: "Power connected", detail: "Power connected, 15%",
                            systemImage: "bolt.fill", duration: 2.5))
messenger.withdrawNotice("copy")
```

- `key` is stable within the module. Posting the same key again replaces the earlier notice in place, so repeats never pile up.
- `title` is the pill text. `detail` is the full text for the tooltip and VoiceOver; it defaults to the title.
- `tone` is `info`, `success`, `warning` or `error`, and picks the symbol unless `systemImage` is set.
- `duration` is visible time in seconds: 4 s by default, 8 s with an action, clamped to 2–10 s. Time spent waiting, during a drag, or with the pointer on the pill's button does not count.
- `action` is at most one `IslandNoticeAction`, such as `.openStorageRecovery`. It is a closed enum: adding one is a case plus a switch arm in `ShelfWindowController.performNoticeAction`. A module-specific button belongs on an `IslandStatusRow` instead.
- Every notice shows in the one notice pill, under the notch or below the open Panel, even when it comes from a module's own window such as Clipboard History's. A notice from the module the unpinned Panel shows appears right away; other modules' notices wait for the Panel to close.

## Status rows

Use `IslandStatusRow` for a condition on the page you are looking at, such as a load or save failure, that needs an in-place control or lasts until it is fixed. It is ordinary view content driven by the store's own state, not a message in the center, and it has no dismiss button:

```swift
if store.didFailToLoad {
    IslandStatusRow(message: String(localized: "…"), isError: true)
}
IslandStatusRow(message: message, isError: true,
                action: .init(title: "Retry") { store.requestRefresh() })
```

Pass `style: .window` in a regular window. Full-page states, such as an empty module or a service that can't be reached, stay `IslandModuleState`.

## VoiceOver

- Every notice is spoken when it is posted, even while it waits behind an open Panel or a drag. Replacing a notice with the same text is not spoken again.
- A raised warning or critical status is spoken once as "title, detail". When it also shows a pill, "Show is available." follows.
- Priority is high for errors, critical statuses and notices with a button, medium for warnings, and low otherwise.
- A notice with a button adds its title, such as "Open Recovery is available.", because the pill never takes keyboard focus.
- The Notch's label adds the status its icon shows, such as "Battery, 15 percent, Battery low".
- An `IslandStatusRow` is not announced; it is read with the rest of the page.

Keep every user-facing string localizable with `String(localized:)` or a SwiftUI literal, and add its `en` entry to `Clerestory/Resources/Localizable.xcstrings`.
