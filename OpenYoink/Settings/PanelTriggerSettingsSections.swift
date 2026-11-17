import SwiftUI

struct PanelTriggerSettingsSections: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(HotKeyMonitor.self) private var hotKeyMonitor

    var body: some View {
        @Bindable var settings = settings
        Group {
            if SideShelfAvailability.isEnabled {
            Section("Side Shelf Reveal") {
                Toggle("Preview side shelf on hover", isOn: $settings.classicShelfHoverRevealEnabled)
                    .disabled(!settings.classicShelfEnabled)
                Text("Drag the edge tab to reposition it. File drag reveal is configured below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            }
            Section("Opening and Closing") {
                Toggle("Open panel on hover", isOn: $settings.islandHoverRevealEnabled)
                    .disabled(!settings.islandEnabled)
                Toggle("Open panel on click", isOn: $settings.islandClickRevealEnabled)
                    .disabled(!settings.islandEnabled)
                Text("Use the notch display when visible, or the top-center screen edge when it is hidden.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Open delay") {
                    Slider(value: $settings.islandHoverDelaySeconds, in: 0...0.5, step: 0.05)
                        .frame(width: 180)
                        .accessibilityIdentifier("settings.islandHoverDelay")
                    Text("\(Int((settings.islandHoverDelaySeconds * 1_000).rounded())) ms")
                        .monospacedDigit()
                        .frame(width: 54, alignment: .trailing)
                }
                .disabled(!settings.islandEnabled
                          || !settings.islandHoverRevealEnabled)
                LabeledContent("Close delay") {
                    Slider(value: $settings.islandHoverLeaveDelaySeconds, in: 0...1, step: 0.05)
                        .frame(width: 180)
                        .accessibilityIdentifier("settings.islandHoverLeaveDelay")
                    Text("\(Int((settings.islandHoverLeaveDelaySeconds * 1_000).rounded())) ms")
                        .monospacedDigit()
                        .frame(width: 54, alignment: .trailing)
                }
                .disabled(!settings.islandEnabled
                          || !settings.islandHoverRevealEnabled)
                Text("The panel closes after you move away. Pin it to keep it open.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Open panel when dragging files or text near the top", isOn: $settings.islandDragApproachEnabled)
                    .disabled(!settings.islandEnabled)
                    .accessibilityIdentifier("settings.islandDragApproach")
                Text("File and text drags work independently of Open panel on hover.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Dropping files or text on the notch display always opens Shelf. The wider approach area is optional.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shelf Shortcut") {
                Toggle("Enable shelf shortcut", isOn: $settings.hotKeyEnabled)

                LabeledContent("Shortcut") {
                    HStack(spacing: 8) {
                        ShortcutRecorderView(shortcut: $settings.hotKeyShortcut)
                        Button("Restore Default") {
                            settings.hotKeyShortcut = .default
                        }
                        .disabled(settings.hotKeyShortcut == .default)
                    }
                }

                // UX3: 双击保存剪贴板。开启时单击带一个识别窗的延迟 —— 脚注
                // 说明此取舍；关闭即恢复零延迟单击。
                Toggle("Double-press saves clipboard", isOn: $settings.hotKeyDoublePressSavesClipboard)
                    .disabled(!settings.hotKeyEnabled)
                Text("When enabled, a single press toggles the shelf after a brief delay (0.3 s) so a double press can be recognized.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let error = hotKeyMonitor.registrationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            // UX1/2: 拖拽自动出现（Yoink 核心交互）。三档单控：立即出现 /
            // 拖到贴边唤出 / 无动作。边缘灵敏度沿用旧边缘触发的三档设置。
            if SideShelfAvailability.isEnabled {
            Section("When Dragging Files") {
                Picker("When Dragging Files", selection: $settings.dragAutoAppearMode) {
                    Text("Show immediately").tag(SettingsStore.DragAutoAppearMode.immediate)
                    Text("Show at screen edge").tag(SettingsStore.DragAutoAppearMode.edgeOnly)
                    Text("Do nothing").tag(SettingsStore.DragAutoAppearMode.off)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Picker("Sensitivity", selection: $settings.edgeTriggerSensitivity) {
                    Text("Low").tag(TriggerSensitivity.low)
                    Text("Medium").tag(TriggerSensitivity.medium)
                    Text("High").tag(TriggerSensitivity.high)
                }
                .disabled(settings.dragAutoAppearMode != .edgeOnly)

                Text(dragModeFootnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Drag triggers stay silent while an ignored app is frontmost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            }
            Section("Mouse Shake") {
                Toggle("Shake the mouse to open panel", isOn: $settings.shakeTriggerEnabled)
                Picker("Sensitivity", selection: $settings.shakeSensitivity) {
                    Text("Low").tag(TriggerSensitivity.low)
                    Text("Medium").tag(TriggerSensitivity.medium)
                    Text("High").tag(TriggerSensitivity.high)
                }
                .disabled(!settings.shakeTriggerEnabled)
            }
        }
    }

    /// UX1/2: 随模式变化的说明文案（immediate 无需贴边；edgeOnly 在 custom
    /// 位置下不可用）。
    private var dragModeFootnote: String {
        switch settings.dragAutoAppearMode {
        case .immediate:
            String(localized: "The shelf appears at its configured position as soon as you start dragging — no need to reach the screen edge.")
        case .edgeOnly:
            String(localized: "While dragging, hold the cursor at the shelf's screen edge for a moment to reveal it. Not available in custom position mode.")
        case .off:
            String(localized: "The shelf won't appear automatically while dragging.")
        }
    }
}

