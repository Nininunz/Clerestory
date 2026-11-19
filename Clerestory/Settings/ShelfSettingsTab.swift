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
        if SideShelfAvailability.isEnabled {
        Section("Side Shelf") {
            Toggle("Enable Side Shelf", isOn: $settings.classicShelfEnabled)

            if settings.classicShelfEnabled {
                Picker("Position", selection: $settings.shelfPosition) {
                    Text("Left").tag(SettingsStore.ShelfPosition.left)
                    Text("Right").tag(SettingsStore.ShelfPosition.right)
                    Text("Custom").tag(SettingsStore.ShelfPosition.custom)
                }
                .pickerStyle(.segmented)
            }

            if settings.classicShelfEnabled && settings.shelfPosition == .custom {
                // S9: custom mode —— panel is draggable, and the frame is persisted after dragging ends;
                // the first selection starts from the default position on the right edge. Edge triggering
                // pauses when there is no attached edge.
                Text("Drag the shelf by its title bar to place it anywhere. The edge trigger is unavailable in custom mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.classicShelfEnabled {
                LabeledContent("Width") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.shelfWidth, in: 240...480, step: 10)
                        Text("\(Int(settings.shelfWidth)) pt")
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }

                Toggle("Hide after dragging out", isOn: $settings.autoHide)

                Toggle("Keep expanded after dropping", isOn: $settings.keepShelfOpenAfterDrop)
                Text("Applies only to the side shelf opened automatically during a drag. Drag-out and empty-shelf settings still apply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // UX6: When transitioning from non-empty to empty, it automatically retracts (manually
                // summoned empty frames are unaffected).
                Toggle("Hide automatically when empty", isOn: $settings.autoHideWhenEmpty)

                // EdgeTab: The handle only displays along the screen edge when the shelf is hidden
                // (mutually exclusive model; when the shelf is expanded, the panel's outer edge takes over
                // the same position for collapsing). In custom mode, there is no attached edge, so the
                // switch has no effect (explanation text overrides).
                Toggle("Show edge tab while shelf is hidden", isOn: $settings.edgeTabEnabled)
                Text("Click the tab to show the shelf, drag it along the edge to reposition, or drop files onto it. Not shown in custom position mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        }

        Section("Shelf Behavior") {
            if SideShelfAvailability.isEnabled && settings.classicShelfEnabled && settings.islandEnabled {
                Text("With Side Shelf enabled, the shelf shortcut controls it. Otherwise it opens the panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
