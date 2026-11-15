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
                // S9: custom 模式 —— 面板可拖动，拖动结束持久化 frame；
                // 首次选中从右缘默认位置起步。边缘触发在无贴附缘时暂停。
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

                // UX6: 非空→空迁移时自动收回（手动唤出的空架不受影响）。
                Toggle("Hide automatically when empty", isOn: $settings.autoHideWhenEmpty)

                // EdgeTab: 拉环只在 shelf 隐藏时贴屏幕边缘显示（互斥模型；
                // shelf 展开后由面板外缘隐形热区承担同点位收起）。
                // custom 模式无贴附缘，开关不生效（说明文案覆盖）。
                Toggle("Show edge tab while shelf is hidden", isOn: $settings.edgeTabEnabled)
                Text("Click the tab to show the shelf, drag it along the edge to reposition, or drop files onto it. Not shown in custom position mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        }

        Section("Shelf Behavior") {
            if SideShelfAvailability.isEnabled && settings.classicShelfEnabled && settings.islandEnabled {
                Text("With Side Shelf enabled, the shelf shortcut controls it. Otherwise the shortcut opens Island Shelf.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("After dragging out", selection: $settings.dragOutRemovalPolicy) {
                Text("Keep on Shelf").tag(SettingsStore.DragOutRemovalPolicy.keep)
                Text("Remove").tag(SettingsStore.DragOutRemovalPolicy.remove)
                Text("Ask Every Time").tag(SettingsStore.DragOutRemovalPolicy.ask)
            }
            .accessibilityIdentifier("settings.dragOutRemovalPolicy")

            // F-05: 双模式拖入说明（静态文案）。
            Text("Dropping files keeps a reference. Hold ⌘ while dropping to move the original into the shelf — the original goes to the Trash, so it can be restored.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("After a successful drop, the receiving shelf stays open so you can drag the item to its destination.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

    }
}
