import AppKit
import SwiftUI

/// The editors share settings bindings and interactions across both hosts.
/// Only control appearance changes between the dark Island and native Settings.
enum ShortcutEditorStyle {
    case island, settings
    var rowColor: Color { self == .island ? .white : .primary }
}

private struct ShortcutEditorToggleStyle: ViewModifier {
    let style: ShortcutEditorStyle
    @ViewBuilder func body(content: Content) -> some View {
        if style == .island {
            content.toggleStyle(IslandClipboardToggleStyle(showsLabel: false))
        } else {
            content.toggleStyle(.switch).controlSize(.small)
        }
    }
}

private struct ShortcutEditorButtonStyle: ViewModifier {
    let style: ShortcutEditorStyle
    @ViewBuilder func body(content: Content) -> some View {
        if style == .island {
            content.buttonStyle(IslandPressFeedbackStyle())
        } else {
            content.buttonStyle(.borderless)
        }
    }
}

struct ExpandedShortcutEditor: View {
    @Environment(SettingsStore.self) private var settings
    private let registry = IslandModuleRegistry()
    var style: ShortcutEditorStyle = .island

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(shortcutIndices, id: \.self) { index in
                positionRow(index)
            }
            HStack {
                Label("One position must contain Quick Settings", systemImage: "lock")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button { settings.restoreDefaultIslandShortcuts() } label: {
                    Text("Restore Defaults")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 28)
                }
                    .modifier(ShortcutEditorButtonStyle(style: style))
                    .help("Restore shortcut positions without changing enabled modules")
            }
            .padding(.vertical, 4)
        }
    }

    private func positionRow(_ index: Int) -> some View {
        HStack(spacing: 12) {
            Text(positionLabel(index))
                .font(.system(size: 12, weight: .medium))
                .frame(width: 90,
                       alignment: .leading)
            Picker(positionLabel(index), selection: Binding<IslandModuleID?>(
                get: { settings.effectiveIslandShortcuts.shortcutPositions[index] },
                set: { settings.assignIslandShortcut($0, at: index) }
            )) {
                Text("Empty").tag(nil as IslandModuleID?)
                    .disabled(settings.effectiveIslandShortcuts.shortcutPositions[index] == .quickSettings)
                Label("Quick Settings", systemImage: "square.grid.2x2")
                    .tag(Optional(IslandModuleID.quickSettings))
                ForEach(registry.descriptors.filter { settings.isIslandModuleAvailable($0.id) && settings.isIslandModuleEnabled($0.id) }) { descriptor in
                    Label(descriptor.title, systemImage: descriptor.systemImage)
                        .tag(Optional(descriptor.id))
                        .disabled(settings.effectiveIslandShortcuts.shortcutPositions[index] == .quickSettings
                                  && !settings.islandModuleConfiguration.isPinned(descriptor.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityIdentifier("island.shortcut.position.\(index)")
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(style.rowColor.opacity(0.055))
        }
    }

    private func positionLabel(_ index: Int) -> String {
        String(localized: "Position \((shortcutIndices.firstIndex(of: index) ?? 0) + 1)")
    }

    private var shortcutIndices: [Int] {
        return settings.effectiveIslandShortcuts
            .visibleShortcutIndices()
    }
}

struct NotchModuleOrderEditor: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let registry = IslandModuleRegistry()
    var style: ShortcutEditorStyle = .island
    var isActive = true
    @State private var draggedNotchModule: IslandModuleID?
    @State private var notchDragOrder: [IslandModuleID]?
    @State private var notchDragTarget: IslandModuleID?
    @State private var hoveredNotchHandle: IslandModuleID?
    @State private var notchRowFrames: [IslandModuleID: CGRect] = [:]
    @GestureState private var notchDragActive = false
    @Namespace private var notchRowMotion

    var body: some View {
        editor
            .onChange(of: notchDragActive) { _, active in
                if !active { clearNotchDrag() }
            }
            .onChange(of: isActive) { _, active in
                if !active { hoveredNotchHandle = nil; clearNotchDrag() }
            }
            .onDisappear { hoveredNotchHandle = nil; clearNotchDrag() }
    }

    private var editor: some View {
        let order = (notchDragOrder ?? settings.notchModuleOrder).filter { settings.isIslandModuleAvailable($0) }
        let rows = order + IslandNotchDisplay.cycleOrder.filter { settings.isIslandModuleAvailable($0) && !order.contains($0) }
        return VStack(spacing: 7) {
            ForEach(rows, id: \.self) { id in
                if !order.isEmpty, id == rows.dropFirst(order.count).first {
                    Rectangle()
                        .fill(style.rowColor.opacity(0.08))
                        .frame(height: 1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .accessibilityHidden(true)
                }
                if let descriptor = registry.descriptor(for: id) {
                    notchRow(descriptor)
                        .matchedGeometryEffect(id: descriptor.id, in: notchRowMotion, properties: .position)
                }
            }
            HStack {
                Label("Drag included modules or use arrows to set cycling order.", systemImage: "arrow.up.arrow.down")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button { settings.notchModuleOrder = IslandNotchDisplay.cycleOrder } label: {
                    Text("Restore Defaults")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 28)
                }
                    .modifier(ShortcutEditorButtonStyle(style: style))
            }
        }
        .coordinateSpace(name: "notchOrder")
        .onPreferenceChange(NotchRowFramesKey.self) { notchRowFrames = $0 }
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: order)
    }

    private func notchRow(_ descriptor: IslandModuleDescriptor) -> some View {
        let order = (notchDragOrder ?? settings.notchModuleOrder).filter { settings.isIslandModuleAvailable($0) }
        let index = order.firstIndex(of: descriptor.id)
        let row = HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: descriptor.systemImage).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.title).font(.system(size: 12, weight: .medium))
                    if !settings.isIslandModuleEnabled(descriptor.id) {
                        Text("Disabled in Modules").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(notchReorderGesture(descriptor.id), including: index != nil ? .all : .none)
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    if index != nil { hoveredNotchHandle = descriptor.id }
                case .ended:
                    if hoveredNotchHandle == descriptor.id { hoveredNotchHandle = nil }
                }
                updateNotchDragCursor()
            }
            Spacer(minLength: 4)
            if let index {
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                        settings.moveNotchModule(descriptor.id, to: order[index - 1])
                    }
                } label: { Image(systemName: "arrow.up").frame(width: 24, height: 24) }
                .disabled(index == 0)
                .accessibilityLabel(Text("Move earlier"))
                Button {
                    withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
                        settings.moveNotchModule(descriptor.id, to: order[index + 1])
                    }
                } label: { Image(systemName: "arrow.down").frame(width: 24, height: 24) }
                .disabled(index == order.count - 1)
                .accessibilityLabel(Text("Move later"))
            }
            Toggle(descriptor.title, isOn: Binding(
                get: { settings.notchModuleOrder.contains(descriptor.id) },
                set: { settings.setNotchModuleIncluded($0, id: descriptor.id) }
            ))
            .labelsHidden()
            .modifier(ShortcutEditorToggleStyle(style: style))
            .accessibilityIdentifier("compact.module.\(descriptor.id.rawValue).included")
        }
        .modifier(ShortcutEditorButtonStyle(style: style))
        .padding(.horizontal, 10)
        .frame(minHeight: 38)
        .background(RoundedRectangle(cornerRadius: 8).fill(style.rowColor.opacity(0.055)))
        return row
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: NotchRowFramesKey.self,
                        value: [descriptor.id: geometry.frame(in: .named("notchOrder"))])
                }
            }
            .opacity(draggedNotchModule == descriptor.id ? 0.65 : 1)
    }

    private func notchReorderGesture(_ id: IslandModuleID) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("notchOrder"))
            .updating($notchDragActive) { _, active, _ in active = true }
            .onChanged { value in
                if draggedNotchModule == nil {
                    notchDragOrder = settings.notchModuleOrder
                    draggedNotchModule = id
                }
                NSCursor.closedHand.set()
                if notchRowFrames[id]?.contains(value.location) == true {
                    notchDragTarget = nil
                    return
                }
                guard var order = notchDragOrder,
                      let target = order.first(where: { $0 != id && notchRowFrames[$0]?.contains(value.location) == true }),
                      notchDragTarget != target,
                      let source = order.firstIndex(of: id),
                      let destination = order.firstIndex(of: target) else { return }
                notchDragTarget = target
                order.remove(at: source)
                order.insert(id, at: destination)
                notchDragOrder = order
            }
            .onEnded { value in
                if let order = notchDragOrder,
                   order.contains(where: { notchRowFrames[$0]?.contains(value.location) == true }) {
                    settings.notchModuleOrder = order
                }
                clearNotchDrag()
            }
    }

    private func clearNotchDrag() {
        draggedNotchModule = nil
        notchDragOrder = nil
        notchDragTarget = nil
        updateNotchDragCursor()
    }

    private func updateNotchDragCursor() {
        if draggedNotchModule != nil {
            NSCursor.closedHand.set()
        } else if hoveredNotchHandle != nil {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

}

private struct NotchRowFramesKey: PreferenceKey {
    static let defaultValue: [IslandModuleID: CGRect] = [:]
    static func reduce(value: inout [IslandModuleID: CGRect], nextValue: () -> [IslandModuleID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
