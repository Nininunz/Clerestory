import Foundation

struct ShelfNoticeContent: Equatable {
    enum Kind: Equatable { case success, info, warning, error }
    let message: String
    let kind: Kind
    var details: String? = nil
    var recoveryAction: RecoveryAction? = nil
}

/// Shared wording for runtime notices and the preview catalog.
enum ShelfNoticeMessage: String, CaseIterable {
    case alreadyOnShelf = "already-on-shelf"
    case reconnected = "reconnected"
    case reconnectFailed = "reconnect-failed"
    case moveAwaitingSave = "move-awaiting-save"
    case receivedAwaitingRecovery = "received-awaiting-recovery"
    case clipboardEmpty = "clipboard-empty"
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

    var presentation: ShelfNoticeContent {
        let summary: String
        let kind: ShelfNoticeContent.Kind
        var recovery: RecoveryAction?
        switch self {
        case .alreadyOnShelf:
            summary = String(localized: "Already on Shelf")
            kind = .warning
        case .reconnected:
            summary = String(localized: "File reconnected.")
            kind = .success
        case .reconnectFailed:
            summary = String(localized: "Couldn't reconnect. Original item kept.")
            kind = .error
        case .moveAwaitingSave:
            summary = String(localized: "Item kept safely for recovery.")
            kind = .warning
            recovery = .openStorageRecovery
        case .receivedAwaitingRecovery, .interruptedImportRecovered:
            summary = String(localized: "File saved. Finish importing in Recovery.")
            kind = .warning
            recovery = .openStorageRecovery
        case .clipboardEmpty:
            summary = String(localized: "Nothing to add from the clipboard.")
            kind = .info
        case .moveRecoveryNeedsAttention, .importRecoveryNeedsAttention:
            summary = String(localized: "Recovery needs attention.")
            kind = .warning
            recovery = .openStorageRecovery
        case .partialMoveRecoveryNeedsAttention:
            summary = String(localized: "Some items need recovery.")
            kind = .warning
            recovery = .openStorageRecovery
        case .moveRecovered:
            summary = String(localized: "Interrupted move recovered.")
            kind = .success
        case .unsupportedContent:
            summary = String(localized: "This content isn't supported yet.")
            kind = .warning
        case .importFailed:
            summary = String(localized: "Couldn't add this item.")
            kind = .error
        case .removed:
            summary = String(localized: "Removed from Shelf. Undo with ⌘Z.")
            kind = .success
        case .removalFailed:
            summary = String(localized: "Nothing removed. Couldn't save a recovery copy.")
            kind = .error
        case .shareUnavailable:
            summary = String(localized: "Couldn't share the selected items.")
            kind = .error
        case .copyPathsFailed:
            summary = String(localized: "Couldn't copy the selected paths.")
            kind = .error
        case .revealFailed:
            summary = String(localized: "Couldn't show the items in Finder.")
            kind = .error
        case .shareInProgress:
            summary = String(localized: "Sharing is already in progress.")
            kind = .info
        case .shareFailed:
            summary = String(localized: "Sharing failed. Items kept on Shelf.")
            kind = .error
        }
        return ShelfNoticeContent(message: summary, kind: kind, details: text, recoveryAction: recovery)
    }

}
