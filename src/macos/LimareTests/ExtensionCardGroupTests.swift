import XCTest
@testable import Limare

@MainActor
final class ExtensionCardGroupTests: XCTestCase {
    private func makeCard(
        id: String,
        title: String,
        isEnabled: Bool = true,
        addedAt: Date = .distantPast,
        usageCount: Int = 0
    ) -> ExtensionCardItem {
        ExtensionCardItem(
            id: id,
            origin: id == ExtensionGroupStore.builtInComputerUseCardID ? .builtInComputerUse : .skill(id: id),
            title: title,
            subtitle: title,
            description: "",
            iconSymbol: nil,
            monogram: String(title.prefix(1)),
            color: .slate,
            scopeLabel: "Global",
            isWorkspaceScoped: false,
            examples: [],
            isEnabled: isEnabled,
            readiness: isEnabled ? .ready : .disabled,
            primarySkill: nil,
            linkedMCPServers: [],
            linkedHooks: [],
            addedAt: addedAt,
            usageCount: usageCount
        )
    }

    func testCreateRenameMoveDeleteAndPersistGroups() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("limare-ext-groups-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ExtensionGroupStore(storageRootURL: root)
        // Fresh store automatically seeds the Built-in preset group with Computer Use.
        XCTAssertEqual(store.groups.count, 1)
        XCTAssertEqual(store.groups[0].id, ExtensionGroupStore.builtInPresetGroupID)
        XCTAssertEqual(store.groups[0].cardIDs, [ExtensionGroupStore.builtInComputerUseCardID])

        XCTAssertNil(store.createGroup(name: "   "))

        let daily = try XCTUnwrap(store.createGroup(name: "  Daily Tools ", cardIDs: ["a", "b", "a"]))
        let coding = try XCTUnwrap(store.createGroup(name: "Coding", cardIDs: ["b", "c"]))

        XCTAssertEqual(store.groups.count, 3)
        XCTAssertEqual(store.groups[1].name, "Daily Tools")
        // Moving "b" into Coding must remove it from Daily Tools.
        XCTAssertEqual(store.groups[1].cardIDs, ["a"])
        XCTAssertEqual(store.groups[2].cardIDs, ["b", "c"])
        XCTAssertEqual(store.currentGroupID(for: "a"), daily.id)
        XCTAssertEqual(store.currentGroupID(for: "b"), coding.id)

        store.renameGroup(id: daily.id, name: "Everyday")
        store.renameGroup(id: daily.id, name: "   ")
        XCTAssertEqual(store.groups[1].name, "Everyday")

        store.toggleCollapsed(id: daily.id)
        XCTAssertTrue(store.groups[1].isCollapsed)
        store.setCollapsed(false, for: daily.id)
        XCTAssertFalse(store.groups[1].isCollapsed)

        store.moveGroup(id: coding.id, direction: -1)
        XCTAssertEqual(store.groups.map(\.id), [ExtensionGroupStore.builtInPresetGroupID, coding.id, daily.id])
        // Out-of-bounds move is a no-op.
        store.moveGroup(id: ExtensionGroupStore.builtInPresetGroupID, direction: -1)
        XCTAssertEqual(store.groups.map(\.id), [ExtensionGroupStore.builtInPresetGroupID, coding.id, daily.id])

        // Re-open from disk and verify persistence.
        let reloaded = ExtensionGroupStore(storageRootURL: root)
        XCTAssertEqual(reloaded.groups, store.groups)

        reloaded.assignCards(["c"], toGroup: nil)
        XCTAssertNil(reloaded.currentGroupID(for: "c"))

        reloaded.deleteGroup(id: coding.id)
        XCTAssertEqual(reloaded.groups.map(\.id), [ExtensionGroupStore.builtInPresetGroupID, daily.id])
        XCTAssertNil(reloaded.currentGroupID(for: "b"))

        // Deleting the preset Built-in group stays deleted across reloads.
        reloaded.deleteGroup(id: ExtensionGroupStore.builtInPresetGroupID)
        let reloadedAfterDelete = ExtensionGroupStore(storageRootURL: root)
        XCTAssertEqual(reloadedAfterDelete.groups.map(\.id), [daily.id])
    }

    func testAdoptsExistingBuiltInGroupAndInsertsWhenMissing() throws {
        // 1. Existing manual "内置" group is adopted without creating a duplicate.
        let rootManual = FileManager.default.temporaryDirectory.appendingPathComponent("limare-ext-manual-\(UUID())")
        defer { try? FileManager.default.removeItem(at: rootManual) }
        try FileManager.default.createDirectory(at: rootManual, withIntermediateDirectories: true)

        let manualGroupID = UUID()
        let manualPayload = ExtensionGroupsPayload(groups: [
            ExtensionCustomGroup(id: manualGroupID, name: "内置", cardIDs: [ExtensionGroupStore.builtInComputerUseCardID, "skill:plugin"]),
            ExtensionCustomGroup(name: "Web", cardIDs: ["skill:search"])
        ])
        let manualData = try JSONEncoder().encode(manualPayload)
        try manualData.write(to: rootManual.appendingPathComponent("extension_groups_v1.json"))

        let adoptedStore = ExtensionGroupStore(storageRootURL: rootManual)
        XCTAssertEqual(adoptedStore.groups.count, 2)
        XCTAssertEqual(adoptedStore.groups[0].id, manualGroupID)
        XCTAssertEqual(adoptedStore.groups[0].name, "内置")
        XCTAssertEqual(adoptedStore.groups[0].cardIDs, [ExtensionGroupStore.builtInComputerUseCardID, "skill:plugin"])

        // 2. Existing groups file without any Built-in group gets preset inserted at index 0.
        let rootLegacy = FileManager.default.temporaryDirectory.appendingPathComponent("limare-ext-legacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: rootLegacy) }
        try FileManager.default.createDirectory(at: rootLegacy, withIntermediateDirectories: true)

        let legacyPayload = ExtensionGroupsPayload(groups: [
            ExtensionCustomGroup(name: "Coding", cardIDs: ["skill:git"])
        ])
        try JSONEncoder().encode(legacyPayload).write(to: rootLegacy.appendingPathComponent("extension_groups_v1.json"))

        let migratedStore = ExtensionGroupStore(storageRootURL: rootLegacy)
        XCTAssertEqual(migratedStore.groups.count, 2)
        XCTAssertEqual(migratedStore.groups[0].id, ExtensionGroupStore.builtInPresetGroupID)
        XCTAssertEqual(migratedStore.groups[0].cardIDs, [ExtensionGroupStore.builtInComputerUseCardID])
        XCTAssertEqual(migratedStore.groups[1].name, "Coding")
    }

    func testBuildSectionsHandlesFlatCustomUngroupedAndFiltering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("limare-ext-sections-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ExtensionGroupStore(storageRootURL: root)
        let cardCU = makeCard(id: ExtensionGroupStore.builtInComputerUseCardID, title: "Computer Use")
        let cardA = makeCard(id: "a", title: "Alpha")
        let cardB = makeCard(id: "b", title: "Beta")
        let cardC = makeCard(id: "c", title: "Gamma", isEnabled: false)
        let allCards = [cardCU, cardA, cardB, cardC]

        // Default preset group -> Built-in + Ungrouped.
        let initialSections = store.buildSections(from: allCards, isFiltering: false)
        XCTAssertEqual(initialSections.map(\.kind), [.custom(ExtensionGroupStore.builtInPresetGroupID), .ungrouped])
        XCTAssertEqual(initialSections[0].cards.map(\.id), [ExtensionGroupStore.builtInComputerUseCardID])
        XCTAssertEqual(initialSections[1].cards.map(\.id), ["a", "b", "c"])

        // Create two groups: one populated, one empty.
        let work = try XCTUnwrap(store.createGroup(name: "Work", cardIDs: ["a", "b"]))
        let empty = try XCTUnwrap(store.createGroup(name: "Empty"))

        let unfiltered = store.buildSections(from: allCards, isFiltering: false)
        XCTAssertEqual(
            unfiltered.map(\.kind),
            [.custom(ExtensionGroupStore.builtInPresetGroupID), .custom(work.id), .custom(empty.id), .ungrouped]
        )
        XCTAssertEqual(unfiltered[1].cards.map(\.id), ["a", "b"])
        XCTAssertTrue(unfiltered[2].cards.isEmpty)
        XCTAssertEqual(unfiltered[3].cards.map(\.id), ["c"])

        // When filtering, empty groups with 0 matching cards are omitted.
        let filtered = store.buildSections(from: [cardA], isFiltering: true)
        XCTAssertEqual(filtered.map(\.kind), [.custom(work.id)])
        XCTAssertEqual(filtered[0].cards.map(\.id), ["a"])

        // When filtering yields no cards, sections are empty so empty state displays.
        XCTAssertTrue(store.buildSections(from: [], isFiltering: true).isEmpty)

        // Removing all groups falls back to a single flat section without title.
        store.deleteGroup(id: ExtensionGroupStore.builtInPresetGroupID)
        store.deleteGroup(id: work.id)
        store.deleteGroup(id: empty.id)
        let flatSections = store.buildSections(from: [cardA, cardB, cardC], isFiltering: false)
        XCTAssertEqual(flatSections.count, 1)
        XCTAssertEqual(flatSections[0].kind, .flat)
        XCTAssertNil(flatSections[0].title)
        XCTAssertEqual(flatSections[0].cards, [cardA, cardB, cardC])
    }

    func testCardSortOrders() {
        let older = Date(timeIntervalSince1970: 1_000)
        let middle = Date(timeIntervalSince1970: 2_000)
        let newer = Date(timeIntervalSince1970: 3_000)

        let alpha = makeCard(id: "alpha", title: "Alpha", isEnabled: true, addedAt: older, usageCount: 2)
        let beta = makeCard(id: "beta", title: "beta", isEnabled: false, addedAt: newer, usageCount: 10)
        let gamma = makeCard(id: "gamma", title: "Gamma", isEnabled: true, addedAt: middle, usageCount: 2)

        let byName = ExtensionCardItem.sorted([gamma, beta, alpha], by: .name)
        XCTAssertEqual(byName.map(\.id), ["alpha", "beta", "gamma"])

        let byUsage = ExtensionCardItem.sorted([alpha, beta, gamma], by: .usageFrequency)
        XCTAssertEqual(byUsage.map(\.id), ["beta", "alpha", "gamma"])

        let byDate = ExtensionCardItem.sorted([alpha, beta, gamma], by: .dateAdded)
        XCTAssertEqual(byDate.map(\.id), ["beta", "gamma", "alpha"])
    }
}
