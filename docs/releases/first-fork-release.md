# OpenYoink 1.0.0 (55)

Version: **1.0.0**, build **55**. Released November 17, 2026.

OpenYoink is a free, MIT-licensed file shelf for macOS. This release begins the
Nininunz-maintained fork of MuQY1818/OpenYoink.

## Highlights

- A shared floating panel on notched and notchless displays. Open it on the
  display where you trigger it; the optional Notch stays on the built-in display.
- Shelf supports file and text drops, search, selection, keyboard navigation,
  Quick Look, and duplicate-file feedback.
- Quick Settings configures panel shortcuts and the enabled Notch modules and
  their order. Panel height can be extended per module.
- Shelf and Quick Settings are available by default. Other modules are behind
  the experimental-modules setting.
- Developer ID signing and Apple notarization, with updates delivered through
  this fork's own Sparkle feed and signing key.

## Installing and upgrading

Download the signed DMG from this fork's GitHub release and copy OpenYoink to
Applications. Quit other OpenYoink copies before launching it.

This fork uses a separate application identity. Existing upstream/development
shelf contents and preferences are **not automatically imported**. Keep the old
installation and its data until any manual migration has been verified. Future
updates within this fork use Sparkle.

The side shelf and stack/grouping features are currently disabled. Mouse-shake
activation has been removed. Experimental modules may change between releases.

## Known limitations

An intermittent keyboard-focus issue was observed during testing: Space went to
the previously active app instead of opening Quick Look. Relaunching resolved
it in that session; the cause remains unconfirmed. Physical external-display
and Intel-hardware checks have not been completed.

## Credits

Based on [MuQY1818/OpenYoink](https://github.com/MuQY1818/OpenYoink).
Original MIT license and contributor attribution are retained.
