import SwiftUI

struct ShelfSettingsTab: View {
    var body: some View {
        SettingsForm { ShelfSettingsSections() }
    }
}

struct ShelfSettingsSections: View {
    @Environment(SettingsStore.self) private var settings

    @ViewBuilder
    var body: some View {
        @Bindable var settings = settings
        Section("Shelf Behavior") {
            Picker("After dragging out", selection: $settings.dragOutRemovalPolicy) {
                Text("Keep on Shelf").tag(SettingsStore.DragOutRemovalPolicy.keep)
                Text("Remove").tag(SettingsStore.DragOutRemovalPolicy.remove)
                Text("Ask Every Time").tag(SettingsStore.DragOutRemovalPolicy.ask)
            }
            .accessibilityIdentifier("settings.dragOutRemovalPolicy")

            // F-05: Dual Mode Drag-and-Drop Instructions (Static Text).
            Text("Dropping files keeps a reference. Hold ⌘ while dropping to move the original into the shelf — the original goes to the Trash, so it can be restored.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("After a successful drop, the receiving shelf stays open so you can drag the item to its destination.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

    }
}
