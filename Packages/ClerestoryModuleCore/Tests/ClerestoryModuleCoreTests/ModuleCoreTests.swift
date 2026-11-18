import Foundation
import Testing
@testable import ClerestoryModuleCore

@Suite("Island module configuration")
struct ModuleCoreTests {
    @Test("Visible shortcut slots follow enabled modules and include Quick Settings", arguments: 0...12)
    func visibleShortcutCapacity(enabledCount: Int) {
        let ids = (0..<enabledCount).map { IslandModuleID(rawValue: "module.\($0)") }
        let configuration = IslandModuleConfiguration(enabledModuleIDs: ids, pinnedModuleIDs: [])
        let indices = configuration.visibleShortcutIndices()
        #expect(indices.count == min(enabledCount + 1, 8))
        #expect(Set(indices).count == indices.count)
        #expect(indices.contains(configuration.shortcutPositions.firstIndex(of: IslandModuleConfiguration.requiredShortcut)!))
    }

    @Test("Slot shrinking preserves occupied positions and fills from the left edge")
    func visibleShortcutPlacement() {
        let shelf: IslandModuleID = "shelf"
        let timer: IslandModuleID = "timer"
        let required = IslandModuleConfiguration.requiredShortcut
        var configuration = IslandModuleConfiguration(enabledModuleIDs: [shelf], pinnedModuleIDs: [])
        configuration.assignShortcut(required, at: 4)
        configuration.assignShortcut(shelf, at: 3)
        #expect(configuration.visibleShortcutIndices() == [3, 4])
        configuration.setEnabled(true, for: timer)
        #expect(configuration.visibleShortcutIndices() == [0, 3, 4])
        configuration.assignShortcut(timer, at: 7)
        #expect(configuration.visibleShortcutIndices() == [3, 4, 7])
        configuration.setEnabled(false, for: shelf)
        #expect(configuration.visibleShortcutIndices() == [4, 7])
        configuration.setEnabled(false, for: timer)
        #expect(configuration.visibleShortcutIndices() == [4])
    }

    @Test("Configuration removes duplicates and caps pinned modules")
    func normalization() {
        let ids = (0..<8).map { IslandModuleID(rawValue: "module.\($0)") }
        let configuration = IslandModuleConfiguration(
            enabledModuleIDs: ids + [ids[0]],
            pinnedModuleIDs: ids + [ids[1]]
        )

        #expect(configuration.enabledModuleIDs.count == 8)
        #expect(configuration.pinnedModuleIDs == Array(ids.prefix(7)))
    }

    @Test("Pin controls follow shortcut capacity and always allow unpinning")
    func pinControlCapacity() {
        let capacity = IslandModuleConfiguration.maximumPinnedModules
        #expect(capacity == IslandModuleConfiguration.shortcutPositionCount - 1)
        let ids = (0...capacity).map { IslandModuleID(rawValue: "module.\($0)") }
        var configuration = IslandModuleConfiguration(enabledModuleIDs: ids, pinnedModuleIDs: [])
        for id in ids.prefix(capacity) {
            #expect(configuration.canTogglePin(for: id))
            configuration.setPinned(true, for: id)
        }
        #expect(configuration.pinnedModuleIDs.count == capacity)
        #expect(!configuration.canTogglePin(for: ids[capacity]))
        #expect(configuration.canTogglePin(for: ids[0]))
        configuration.setPinned(false, for: ids[0])
        #expect(configuration.canTogglePin(for: ids[capacity]))
        configuration.setEnabled(false, for: ids[capacity])
        #expect(!configuration.canTogglePin(for: ids[capacity]))
    }

    @Test("Shortcut position changes preserve module enablement")
    func shortcutReordering() {
        let ids: [IslandModuleID] = ["shelf", "timer", "battery"]
        var configuration = IslandModuleConfiguration(enabledModuleIDs: ids, pinnedModuleIDs: ids)
        configuration.movePinned(fromOffsets: IndexSet(integer: 0), toOffset: 2)
        #expect(configuration.pinnedModuleIDs == [ids[1], ids[0], ids[2]])
        configuration.movePinned(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(configuration.pinnedModuleIDs == ids)
        configuration.setPinned(false, for: ids[1])
        #expect(configuration.enabledModuleIDs == ids)
        #expect(configuration.pinnedModuleIDs == [ids[0], ids[2]])
    }

    @Test("Fixed positions preserve gaps and swap existing shortcuts")
    func fixedPositions() throws {
        let ids: [IslandModuleID] = ["shelf", "timer", "battery"]
        var configuration = IslandModuleConfiguration(enabledModuleIDs: ids, pinnedModuleIDs: ids)
        configuration.assignShortcut(nil, at: 1)
        #expect(configuration.shortcutPositions[1] == nil)
        #expect(configuration.shortcutPositions[2] == ids[2])
        configuration.assignShortcut(ids[0], at: 2)
        #expect(configuration.shortcutPositions[0] == ids[2])
        #expect(configuration.shortcutPositions[2] == ids[0])
        configuration.assignShortcut(ids[1], at: 6)
        let restored = try JSONDecoder().decode(IslandModuleConfiguration.self,
            from: JSONEncoder().encode(configuration))
        #expect(restored.shortcutPositions == configuration.shortcutPositions)
        #expect(restored.pinnedModuleIDs == [ids[2], ids[0], ids[1]])
        configuration.setEnabled(false, for: ids[0])
        #expect(configuration.shortcutPositions[2] == nil)
        #expect(configuration.shortcutPositions[6] == ids[1])
        configuration.assignShortcut("disabled", at: 0)
        #expect(configuration.shortcutPositions[0] == ids[2])
        configuration.setPinned(true, for: ids[0])
        #expect(configuration.shortcutPositions[1] == ids[0])
    }

    @Test("Legacy packed configurations populate positions without losing pins")
    func legacyPositions() throws {
        let original = IslandModuleConfiguration(enabledModuleIDs: ["shelf", "timer"],
                                                 pinnedModuleIDs: ["timer", "shelf"])
        let data = try JSONEncoder().encode(original)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["pinnedPositions"] == nil)
        let restored = try JSONDecoder().decode(IslandModuleConfiguration.self, from: data)
        #expect(restored.shortcutPositions.count == IslandModuleConfiguration.shortcutPositionCount)
        #expect(restored.shortcutPositions.prefix(3) == ["timer", "shelf", nil])
    }

    @Test("Required shortcut swaps into every slot and cannot be removed")
    func requiredShortcutPositions() throws {
        let required = IslandModuleConfiguration.requiredShortcut
        let ids = (0..<7).map { IslandModuleID(rawValue: "module.\($0)") }
        for target in 0..<IslandModuleConfiguration.shortcutPositionCount {
            var config = IslandModuleConfiguration(enabledModuleIDs: ids, pinnedModuleIDs: ids)
            config.assignShortcut(required, at: target)
            #expect(config.shortcutPositions[target] == required)
            #expect(config.shortcutPositions.filter { $0 == required }.count == 1)
            #expect(Set(config.pinnedModuleIDs) == Set(ids))
            config.assignShortcut(nil, at: target)
            config.setEnabled(false, for: required)
            config.setPinned(false, for: required)
            #expect(config.shortcutPositions[target] == required)
            #expect(config.isEnabled(required))
            let restored = try JSONDecoder().decode(IslandModuleConfiguration.self,
                from: JSONEncoder().encode(config))
            #expect(restored.shortcutPositions == config.shortcutPositions)
        }
        var sparse = IslandModuleConfiguration(enabledModuleIDs: ids, pinnedModuleIDs: [])
        sparse.assignShortcut(required, at: 0)
        #expect(sparse.shortcutPositions[0] == required)
        #expect(sparse.shortcutPositions[7] == nil)
        sparse.assignShortcut(ids[0], at: 0)
        #expect(sparse.shortcutPositions[0] == required)
        sparse.assignShortcut(ids[0], at: 5)
        sparse.assignShortcut(ids[0], at: 0)
        #expect(sparse.shortcutPositions[5] == required)
        #expect(sparse.shortcutPositions[0] == ids[0])
    }

    @Test("Disabling a module also unpins it")
    func disablingUnpins() {
        let id: IslandModuleID = "timer"
        var configuration = IslandModuleConfiguration(
            enabledModuleIDs: [id], pinnedModuleIDs: [id]
        )

        configuration.setEnabled(false, for: id)

        #expect(!configuration.isEnabled(id))
        #expect(!configuration.isPinned(id))
    }

    @Test("Unknown identifiers survive Codable round trip")
    func unknownRoundTrip() throws {
        let unknown: IslandModuleID = "future.provider.module"
        let original = IslandModuleConfiguration(
            enabledModuleIDs: [unknown], pinnedModuleIDs: [unknown]
        )

        let decoded = try JSONDecoder().decode(
            IslandModuleConfiguration.self,
            from: JSONEncoder().encode(original)
        )

        #expect(decoded == original)
    }

    @Test("Pinning enables a module")
    func pinningEnables() {
        let id: IslandModuleID = "system"
        var configuration = IslandModuleConfiguration(
            enabledModuleIDs: [], pinnedModuleIDs: []
        )

        configuration.setPinned(true, for: id)

        #expect(configuration.isEnabled(id))
        #expect(configuration.isPinned(id))
    }
}
