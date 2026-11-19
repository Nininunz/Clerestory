# Clerestory

**A modular panel for your Mac.**

Clerestory puts a file shelf and configurable shortcuts in a panel at the top of your display. Use it on any display. On a Mac with a built-in notch, an optional Notch companion gives you a compact way to open the panel and see module activity.

[Download Clerestory](https://github.com/Nininunz/Clerestory/releases/latest) · [Quick start](#quick-start) · [简体中文](README.md)

## Install

Clerestory supports macOS 15 and later on Apple silicon and Intel. Open the signed and notarized DMG from the [latest release](https://github.com/Nininunz/Clerestory/releases/latest) and drag the app to Applications.

To update, choose **Check for Updates…** from the menu bar icon.

## Quick start

| To… | Do this |
| --- | --- |
| Open the Panel | Move to the top center of your display, click the trigger area, press `⌘⇧Space`, or use the menu bar icon. |
| Add to Shelf | Drag a file or selected text toward the top center, then drop it into Shelf. |
| Move a file into Shelf | Hold `⌘` while dropping. Read [File safety and lifecycle](#file-safety-and-lifecycle) first. |
| Park the clipboard | Press `⌘⇧Space` twice with **Double-press saves clipboard** enabled. |
| Search Shelf | Click **Search Shelf** or press `⌘F` while Shelf has keyboard focus. |
| Preview an item | Click it and press Space, or double-click it. |
| Select multiple items | Click **Select**, or use `⌘`-click to toggle individual items. |
| Remove an item | Hover and click **×**, press Delete, or use the item's context menu. Use `⌘Z` to undo manual removal. |

Hover, click, and drag-to-open are enabled by default. Adjust the hover delays or turn off individual triggers in **Settings → Panel**. Drag-to-open has its own switch. Use the panel's pin button to keep it open when you move the pointer away.

## Panel, Notch, and modules

- **Panel.** Opens on the display where you trigger it and stays on that display until dismissed. Use **Settings → Panel → Shortcut Positions** or **Quick Settings** to arrange module shortcuts.
- **Notch.** An optional companion on the built-in display of a Mac with a physical notch. It is on by default. Use **Settings → Notch** to turn it off, choose its module order, and set a cycling shortcut (none is set by default). Hold Shift with that shortcut to cycle backward.
- **Shelf** and **Quick Settings** are available by default. To use other modules, turn on **Experimental Modules** under **Settings → Modules**. Transfers, Timer, Battery and System Status turn on right away; turn on the others individually. Experimental modules include Transfers, Timer, Battery, Now Playing, System Status, Quick Access, Clipboard, and AI Usage.

## File safety and lifecycle

A regular drop only remembers where the file is; nothing gets moved. Removing a card, or setting **After dragging out** to **Remove** in **Settings → Modules → Shelf**, never deletes the original. Dropping onto Finder asks for a copy, and the destination decides whether to take it.

> [!WARNING]
> Holding `⌘` while dropping is a **move**: Clerestory copies the file into its own sandbox, checks the copy, and then moves the original to the Trash. If anything goes wrong, the original stays where it was and the item is kept as a regular reference. You can get the original back until you empty the Trash.

A moved item's card and sandbox copy are deleted only after it has been dropped somewhere successfully, regardless of the **After dragging out** setting. If the drop is cancelled or fails, both stay so you can try again.

<details>
<summary>Where each kind of item is stored, and when it's cleaned up</summary>

| Item                             | How Clerestory stores it                                   |
| -------------------------------- | --------------------------------------------------------- |
| Files and folders                | A sandbox bookmark to the original location; no copy      |
| Plain text and links             | Directly in the shelf data                                |
| Images, HTML, RTF                | As files inside the app sandbox                           |
| Contacts, events, mail messages  | As `.vcf`, `.ics`, `.eml` when the source app provides them |

If an original is moved, deleted, or sits on a disconnected drive, its card shows as unavailable and comes back once the file can be found again.

Text and links live with their cards and disappear when the card is removed. Files generated for images, rich text and mail are usually cleaned up on the next launch after their cards are gone; you can also review and clear them in **Settings → Storage**.

Regular file drags provide both a file URL and a filename Chromium understands. Moved items use a file promise and leave the shelf only after the destination confirms the write. Whether a particular app or website accepts the drop is ultimately up to it.

</details>

## Privacy and permissions

- No account, no analytics, no telemetry. Everything stays in the local sandbox under `Application Support/Clerestory`.
- App Sandbox is on, so Clerestory can only touch files you drag in or pick yourself. Everyday use needs neither Accessibility nor Input Monitoring.
- The only background network traffic is checking for and downloading updates from GitHub Pages / Releases, and you can turn that off.
- AI Usage only talks to TokenTracker on your own Mac (`localhost:7680`). It never goes online and doesn't read TokenTracker's files.
- Now Playing never goes online. It reads playback info through a local helper first, and falls back to AppleScript for Apple Music / Spotify, which may trigger an Automation permission prompt. If the module breaks, the shelf keeps working.
- Quick Access only remembers the folders you add. Removing one doesn't delete the folder, and macOS decides which app opens it.

### Clipboard history

Clipboard recording is off by default. To use it, turn on **Experimental Modules** under **Settings → Modules**, then turn on **Record Clipboard** in the Clipboard History settings there. Until you turn it on, the clipboard is read only at the moment you double-press the shortcut to park it. Once on, only newly copied text, HTTP(S) links and PNG/TIFF images are recorded — nothing from before, and never copied files.

History is stored as plain text on this Mac and is never uploaded or synced. Keep 30, 100 or 300 entries (default 30) for 1, 7 or 30 days (default 7), plus up to 30 favorites that never expire, all within 20 MiB. Turning recording off keeps what's already there; clearing it deletes it.

Items marked private by common password managers, and apps you've set to ignore, are skipped — but not every secret can be detected. Pause recording before you copy a password or token.

## Build from source

You'll need macOS 15+ and Xcode 27.2, the version CI uses.

```bash
git clone https://github.com/Nininunz/Clerestory.git
cd Clerestory

xcodebuild \
  -project Clerestory.xcodeproj \
  -scheme Clerestory \
  -destination 'platform=macOS' \
  build

xcodebuild \
  -project Clerestory.xcodeproj \
  -scheme Clerestory \
  -destination 'platform=macOS' \
  test \
  -only-testing:ClerestoryTests
```

Written in Swift 6 with SwiftUI and AppKit. Local builds don't need a `DEVELOPMENT_TEAM`, and the test command above runs unit tests only, not UI automation.

Releases are built with [`Scripts/make-release.sh`](Scripts/make-release.sh), either with Developer ID signing and notarization or as an explicit `--adhoc` community build. If signing fails, the script stops instead of quietly falling back.

## Contributing

See the [documentation index](docs/README.md) for architecture, testing, previews, and release guides.

Run `python3 Scripts/tree.py` from the repository root to list the source layout, including new files that Git does not ignore. The output omits ignored build artifacts and local configuration.

Use `python3 Scripts/tree.py Clerestory/Island --depth 2` to show one directory and up to two levels beneath it. Paths in the output stay relative to the repository root.

Run `Scripts/doctor.sh` to check the active Xcode, macOS SDK, and local build and test tools. Add `--release` to also check Developer ID signing, Sparkle tools, and notarization access. The release check contacts Apple without uploading a build or printing credentials.

Something feels off, broke, or could be better? Open an [issue](https://github.com/Nininunz/Clerestory/issues). For bugs, your macOS version, Clerestory version and steps to reproduce help a lot — and please keep private files and clipboard contents out of screenshots.

Pull requests are welcome. For bigger changes, open an issue first so we can talk it through, and run the full unit test suite before submitting.

## Credits and license

Clerestory is based on [OpenYoink](https://github.com/MuQY1818/OpenYoink) by weijue and contributors and is released under the [MIT License](LICENSE).

Updates are powered by [Sparkle](https://sparkle-project.org/). Third-party components and their licenses are listed in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

<br>

<div align="center">

© 2026 weijue, Nicholas Nunziata · MIT License

</div>
