# Clerestory manual testing

Use this guide for issues that depend on real source and destination apps, macOS permissions, hardware, or the WindowServer. Run the [CI checks](development/CI.md) and [native UI tests](development/UI_TESTS.md) for automated coverage. Use the [preview generator](development/PREVIEWS.md) to inspect current module layouts with synthetic data.

Record the Clerestory version and build, commit, macOS version and build, hardware, display arrangement and scaling, and relevant settings. Mark cases **Pass**, **Fail**, **Blocked**, or **Untested** for the build under test. For failures, record reproducible steps and evidence using synthetic data. Keep unavailable hardware and untested source or destination apps visible in the results.

## Set up disposable data

- Use a temporary directory with a text file, PNG, PDF, folder, and same-named files in separate folders with different contents. Use a separate test account or disposable data when checking a fresh install, clipboard history, managed moves, or interrupted imports.
- Record original file paths and SHA-256 hashes before testing. For managed Command-drops, inspect the original location, Trash, and the managed copy. Verify the hash of the surviving copy after recovery.
- Exercise each drag-out policy: keep the card, remove it, and ask each time. Canceling a drag should leave the card available. Ordinary imports, card removal, and drag-out must preserve external originals.
- A direct file drag can report **Destination accepted**. A managed export can report **Delivered** after the file-promise completion callback. Verify partial results and recovery messages against the actual files.

## Cross-app drag and drop

| Source and payload | Destination | Checks |
| --- | --- | --- |
| Finder file, folder, or multi-file selection | Another Finder window | Verify order, complete folders, multi-item results, cancellation, and original-file integrity. Try a destination with a same-named file and verify conflict handling preserves both the Shelf item and any existing data. |
| Finder file | Safari and Chromium upload areas using a test destination | Verify the drop is accepted without reporting confirmed delivery for a direct file drag. Retry after a rejected drop. |
| Safari and Chromium images, selected text, and links | Finder, Notes, or Mail, as appropriate | Verify image materialization, snippet text, link URL and title, and the representation received by each destination. |
| Mail attachments and messages | Finder, plus an upload area for attachments | Try single and multiple attachments. Check the transfer status until file promises resolve. Verify staging remains available for later callbacks and messages export in the format Mail provides. |
| Photos single and multiple images | Finder, plus an upload area for a single image | Verify progress, completed images, and useful error feedback. Keep successful items available if part of a batch fails. |
| Notes rich text and embedded images | Mail, a text editor, or Finder, as appropriate | Verify the representation received by the destination. Check for empty or duplicate cards and confirm images open after export. |

With hover reveal off, drag a test file and selected text toward the Panel trigger. Verify the Panel opens, accepts the drop, and shows the expected drag outline. Repeat after using the wallpaper to reveal the desktop. Drop a file already on Shelf and confirm the duplicate notice follows release and the count is stable. Then verify that files with the same name from different paths can coexist. With no image on the clipboard, choose **Add Clipboard Image to Shelf** and confirm the Panel stays closed and the notice appears under the notch.

## File availability and recovery

| Scenario | Checks |
| --- | --- |
| Rename, move, or delete an external original | Check whether its bookmark still resolves. If it becomes unavailable, confirm Shelf shows a missing state. Canceling **Locate…** preserves the old reference. Choosing a replacement updates the path and bookmark. |
| Cloud file or removable drive | Test a downloaded file through relaunch and export. Test an offline placeholder and disconnect a disposable external volume. Check that unavailable files are reported accurately and that reconnecting or locating an original restores access. |
| Ordinary import and card removal | Remove the card and compare the external original’s hash. Undo should restore the Shelf reference when possible. It cannot undo delivery, Trash operations, or external deletion. |
| Managed Command-drop | Check the pending move cue, the readable managed copy, and the original in Trash after a successful move. On a source where the move fails, confirm the original remains and a reference or actionable failure is reported. |
| Unwritable destination, cancellation, and partial failure | Verify failed items remain available for retry. Check that a cancellation leaves no misleading success state, removes incomplete temporary copies, and preserves any files needed for recovery. |
| Interrupted import or managed move | In a disposable account, quit during materialization or interrupt the app at a managed-move boundary. Relaunch and inspect **Settings → Storage → Pending Imports**. Check whether retry or removal is offered and confirm cleanup preserves at least one valid copy and any files needed by pending imports or recovery snapshots. |

Treat file loss, silent overwrites, or unrecoverable failed transfers as release blockers.

Run `Scripts/diagnostics/verify-shelf-volume-availability.sh` to check eject and reconnect with a disposable APFS disk image. It reloads a saved Shelf item in a fresh process and verifies that the volume stays ejected until explicitly reattached. Use a physical removable drive separately when validating hardware behavior.

## Panel, Notch, and keyboard

- On a built-in notched display with an external screen attached, trigger the Panel from each display using hover, click, keyboard, and drag. Confirm the Notch stays on the built-in display. Verify the Panel stays on the triggering display while open and falls back to a visible location on disconnect. Repeat across different scaling settings, Spaces, full-screen windows, and display reconnect.
- Verify hover reveal and dismissal, quick reentry, pin and unpin, and pointer travel into an open menu. Open Quick Look and leave the Panel with the pointer. Close the preview and confirm normal dismissal and Shelf focus resume.
- Put keyboard focus in another app, then click a Shelf card. Check arrows and Shift-arrow selection, Space for Quick Look, navigation while the preview is open, Escape, Return, Delete, and Command-C. Typing and editing shortcuts in Shelf or Clipboard search should act on the search field.
- Check VoiceOver names, selection and transfer status announcements, and recovery actions. Notices are spoken when they are posted, even while they wait behind an open Panel; a notice with a button also names it, such as "Open Recovery is available." Transfer announcements should also be spoken while the Shelf is closed. Check Reduce Motion, Increase Contrast, Differentiate Without Color, and light and dark appearance. Use a small display or larger text to check scrolling, clipping, and control reachability.
- Check the app icon in Finder and the Dock, including small sizes. Use a freshly built app when comparing artwork to rule out a cached icon.

See [Panel and Notch architecture](PANEL_ARCHITECTURE.md) for display ownership and trigger behavior.

## Clipboard and experimental modules

- Enable experimental modules for these cases. Verify Clipboard starts with recording off in clean settings. After enabling it, check new text, links, and images. Pause and resume, then verify clipboard contents from the paused period are absent.
- With disposable values, test exclusions for ignored apps and private pasteboard markers where supported. Check search, favorites, copy, and adding a snippet to Shelf while preserving the current system clipboard. Verify deletion and clear persist across relaunch.
- Check that Clipboard recording status stays readable when the Panel loses focus. Exercise settings limits with synthetic data, including ordinary history eviction and retention of favorites.
- With Now Playing enabled, try Apple Music, Spotify, and a browser that provides a media session. Check track changes, pause and resume, unavailable states, and recovery after sleep. If a title arrives late, confirm it updates without losing playback controls.
- For Quick Access, add a folder, rename or relink its favorite, and open it with the configured file manager. Copy a test file into the favorite, exercise same-name conflict handling, and verify the original stays intact when removing the favorite.
- Exercise Timer presets, custom duration, pause, resume, reset, and relaunch. On battery-powered hardware, check charging and unplugging and verify unavailable readings on a machine without a battery. Check that enabled modules resume normally after wake and that Clipboard does not backfill lock-screen changes.
- On a notched Mac with Battery enabled, let the battery drop to 20% or below (or test at 15%). The Notch shows a red battery icon, a pill reads "Battery low · 15%" once, and VoiceOver speaks it. Plug in: "Power connected · 15%" shows with a bolt in the Notch for 2.5 s of visible time, then the Notch returns to the red "Battery low" without a new pill. While the bolt shows, the Notch's VoiceOver label still says "Battery low" before "Power connected, 15%". With an unpinned Panel open on another module (for example on an external display), the "Power connected" pill waits and the Notch keeps the red icon until the pill appears. Toggling Low Power Mode works the same way. Unplug again within the band: "Running on battery · 15%" shows for 2.5 s, then the red icon returns. At 10% or below, the title becomes "Battery critically low" and is announced once more. With the Panel open on Battery, the "Battery low" pill is skipped but still spoken.
- With the battery low, switch the Notch to another module, such as Now Playing or Shelf. The leading icon turns red with the battery symbol, replacing media artwork, and the Notch's VoiceOver label ends with "Battery low". A warning from another module, such as an AI Usage limit, does not take over the icon. A file drag still shows the drop arrow when the Notch displays Shelf, even right after a Shelf notice (the pill hides during the drag), and the red icon returns after the drop.

For a read-only idle sample, run `swift Scripts/diagnostics/profile-idle.swift PID 300` with the Clerestory process ID. Compare runs with the same modules, playback, Panel state, and machine load.

## Release smoke check

Follow the [signed release and Sparkle guide](RELEASING.md) for packaging and feed validation. A fresh macOS account or VM is needed to establish first-launch and permission behavior. A distinct physical display and supported Intel hardware are separate checks when available.
