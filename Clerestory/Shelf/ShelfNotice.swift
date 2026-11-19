import Foundation
import SwiftUI

/// Shelf's wording catalog for runtime notices and the preview catalog. Raw values are the
/// notice keys and the `notice-*` preview ids.
enum ShelfNotice: String, CaseIterable {
    case alreadyOnShelf = "already-on-shelf"
    case reconnected = "reconnected"
    case reconnectFailed = "reconnect-failed"
    case moveAwaitingSave = "move-awaiting-save"
    case receivedAwaitingRecovery = "received-awaiting-recovery"
    case clipboardEmpty = "clipboard-empty"
    case clipboardHasNoImage = "clipboard-has-no-image"
    case moveRecoveryNeedsAttention = "move-recovery-needs-attention"
    case moveRecovered = "move-recovered"
    case partialMoveRecoveryNeedsAttention = "partial-move-recovery-needs-attention"
    case interruptedImportRecovered = "interrupted-import-recovered"
    case importRecoveryNeedsAttention = "import-recovery-needs-attention"
    case unsupportedContent = "unsupported-content"
    case importFailed = "import-failed"
    case removed = "removed"
    case removalFailed = "removal-failed"
    case shareUnavailable = "share-unavailable"
    case copyPathsFailed = "copy-paths-failed"
    case revealFailed = "reveal-failed"
    case shareInProgress = "share-in-progress"
    case shareFailed = "share-failed"

    var text: String {
        switch self {
        case .alreadyOnShelf: String(localized: "Already on Shelf. Existing files were skipped. Any new files were added.")
        case .reconnected: String(localized: "The shelf item was reconnected.")
        case .reconnectFailed: String(localized: "The file could not be reconnected. The original shelf item was kept.")
        case .moveAwaitingSave: String(localized: "The moved item is being kept for recovery because the shelf could not be saved immediately.")
        case .receivedAwaitingRecovery: String(localized: "The received file was kept safely. Open Recovery to finish importing it.")
        case .clipboardEmpty: String(localized: "Clipboard is empty or has nothing the shelf can hold.")
        case .clipboardHasNoImage: String(localized: "No supported image on the clipboard.")
        case .moveRecoveryNeedsAttention: String(localized: "Managed move recovery data needs attention. Automatic cleanup is disabled.")
        case .moveRecovered: String(localized: "Recovered an interrupted managed move.")
        case .partialMoveRecoveryNeedsAttention: String(localized: "Some managed move recovery data needs attention. Automatic cleanup is disabled.")
        case .interruptedImportRecovered: String(localized: "A received file was kept safely. Open Recovery to finish importing it.")
        case .importRecoveryNeedsAttention: String(localized: "Pending import recovery data needs attention. Automatic cleanup is disabled.")
        case .unsupportedContent: String(localized: "That content can't be added to the shelf yet.")
        case .importFailed: String(localized: "Couldn't add the dropped item.")
        case .removed: String(localized: "Removed from Shelf. Undo with ⌘Z, or recover in Settings → Storage.")
        case .removalFailed: String(localized: "Could not save a recovery copy. Nothing was removed.")
        case .shareUnavailable: String(localized: "The selected items could not be shared.")
        case .copyPathsFailed: String(localized: "The selected file paths could not be copied.")
        case .revealFailed: String(localized: "The selected items could not be shown in Finder.")
        case .shareInProgress: String(localized: "A share is already in progress.")
        case .shareFailed: String(localized: "Sharing failed. The selected items remain on the shelf.")
        }
    }

    var notice: IslandNotice {
        let summary: String
        let tone: IslandNotice.Tone
        var action: IslandNoticeAction?
        switch self {
        case .alreadyOnShelf:
            summary = String(localized: "Already on Shelf")
            tone = .warning
        case .reconnected:
            summary = String(localized: "File reconnected.")
            tone = .success
        case .reconnectFailed:
            summary = String(localized: "Couldn't reconnect. Original item kept.")
            tone = .error
        case .moveAwaitingSave:
            summary = String(localized: "Item kept safely for recovery.")
            tone = .warning
            action = .openStorageRecovery
        case .receivedAwaitingRecovery, .interruptedImportRecovered:
            summary = String(localized: "File saved. Finish importing in Recovery.")
            tone = .warning
            action = .openStorageRecovery
        case .clipboardEmpty:
            summary = String(localized: "Nothing to add from the clipboard.")
            tone = .info
        case .clipboardHasNoImage:
            summary = String(localized: "No image to add.")
            tone = .info
        case .moveRecoveryNeedsAttention, .importRecoveryNeedsAttention:
            summary = String(localized: "Recovery needs attention.")
            tone = .warning
            action = .openStorageRecovery
        case .partialMoveRecoveryNeedsAttention:
            summary = String(localized: "Some items need recovery.")
            tone = .warning
            action = .openStorageRecovery
        case .moveRecovered:
            summary = String(localized: "Interrupted move recovered.")
            tone = .success
        case .unsupportedContent:
            summary = String(localized: "This content isn't supported yet.")
            tone = .warning
        case .importFailed:
            summary = String(localized: "Couldn't add this item.")
            tone = .error
        case .removed:
            summary = String(localized: "Removed from Shelf. Undo with ⌘Z.")
            tone = .success
        case .removalFailed:
            summary = String(localized: "Nothing removed. Couldn't save a recovery copy.")
            tone = .error
        case .shareUnavailable:
            summary = String(localized: "Couldn't share the selected items.")
            tone = .error
        case .copyPathsFailed:
            summary = String(localized: "Couldn't copy the selected paths.")
            tone = .error
        case .revealFailed:
            summary = String(localized: "Couldn't show the items in Finder.")
            tone = .error
        case .shareInProgress:
            summary = String(localized: "Sharing is already in progress.")
            tone = .info
        case .shareFailed:
            summary = String(localized: "Sharing failed. Items kept on Shelf.")
            tone = .error
        }
        return IslandNotice(key: rawValue, title: summary, detail: text, tone: tone, action: action)
    }
}

private struct ShelfMessengerEnvironmentKey: EnvironmentKey {
    static let defaultValue: ModuleMessenger? = nil
}

extension EnvironmentValues {
    /// Posts Shelf notices from Shelf views (ShelfWindowController injection; previews leave it nil).
    var shelfMessenger: ModuleMessenger? {
        get { self[ShelfMessengerEnvironmentKey.self] }
        set { self[ShelfMessengerEnvironmentKey.self] = newValue }
    }
}
