import XCTest
@testable import aircraft

final class SidebarTreeTests: XCTestCase {
    private func ids(_ count: Int) -> [UUID] { (0..<count).map { _ in UUID() } }

    func testOpenedLinkCreatesGroupWithOpener() {
        let tabs = ids(3)
        var tree = SidebarTree(regular: [.tab(tabs[0]), .tab(tabs[1])])
        let group = tree.insertOpenedTab(tabs[2], opener: tabs[1], anchor: tabs[1], grouping: true, groupTitle: "example.com")
        XCTAssertNotNil(group)
        XCTAssertEqual(tree.orderedTabIDs, [tabs[0], tabs[1], tabs[2]])
        guard case .folder(let folder) = tree.regular[1] else { return XCTFail("Ожидалась группа") }
        XCTAssertEqual(folder.kind, .group)
        XCTAssertEqual(folder.title, "example.com")
        XCTAssertEqual(folder.children, [.tab(tabs[1]), .tab(tabs[2])])
    }

    func testOpenedLinkInsideGroupJoinsIt() {
        let tabs = ids(4)
        var tree = SidebarTree(regular: [.tab(tabs[0])])
        tree.insertOpenedTab(tabs[1], opener: tabs[0], anchor: tabs[0], grouping: true, groupTitle: "a")
        tree.insertOpenedTab(tabs[2], opener: tabs[0], anchor: tabs[1], grouping: true, groupTitle: "a")
        tree.insertOpenedTab(tabs[3], opener: tabs[2], anchor: tabs[2], grouping: true, groupTitle: "b")
        XCTAssertEqual(tree.regular.count, 1, "Вкладки из группы остаются в той же группе")
        XCTAssertEqual(tree.orderedTabIDs, tabs)
    }

    func testOpenedLinkInsideFolderDoesNotCreateGroup() {
        let tabs = ids(2)
        let folder = TabFolder(title: "Работа", kind: .folder, children: [.tab(tabs[0])])
        var tree = SidebarTree(regular: [.folder(folder)])
        let group = tree.insertOpenedTab(tabs[1], opener: tabs[0], anchor: tabs[0], grouping: true, groupTitle: "x")
        XCTAssertNil(group)
        XCTAssertEqual(tree.folder(folder.id)?.children, [.tab(tabs[0]), .tab(tabs[1])])
    }

    func testGroupingCanBeDisabled() {
        let tabs = ids(2)
        var tree = SidebarTree(regular: [.tab(tabs[0])])
        tree.insertOpenedTab(tabs[1], opener: tabs[0], anchor: tabs[0], grouping: false, groupTitle: "x")
        XCTAssertEqual(tree.regular, [.tab(tabs[0]), .tab(tabs[1])])
    }

    func testSmallGroupsDissolve() {
        let tabs = ids(2)
        var tree = SidebarTree(regular: [.tab(tabs[0])])
        tree.insertOpenedTab(tabs[1], opener: tabs[0], anchor: tabs[0], grouping: true, groupTitle: "x")
        tree.removeNode(tabs[1])
        tree.dissolveSmallGroups()
        XCTAssertEqual(tree.regular, [.tab(tabs[0])])
    }

    func testFolderDepthLimit() {
        let tab = UUID()
        var tree = SidebarTree(regular: [.tab(tab)])
        var parent: UUID?
        for level in 1...SidebarTree.maxFolderDepth {
            let container = SidebarContainer(zone: .regular, folderID: parent)
            XCTAssertTrue(tree.canCreateFolder(in: container), "Уровень \(level) разрешён")
            let folder = TabFolder(title: "L\(level)", kind: .folder)
            XCTAssertTrue(tree.insert(.folder(folder), into: container))
            parent = folder.id
        }
        let deepest = SidebarContainer(zone: .regular, folderID: parent)
        XCTAssertFalse(tree.canCreateFolder(in: deepest))
        XCTAssertFalse(tree.insert(.folder(TabFolder(title: "too deep", kind: .folder)), into: deepest))
        XCTAssertTrue(tree.move(tab, to: deepest), "Вкладку на последний уровень положить можно")
    }

    func testMovingFolderRespectsDepthOfItsContents() {
        let inner = TabFolder(title: "inner", kind: .folder, children: [.folder(TabFolder(title: "innermost", kind: .folder))])
        let target = TabFolder(title: "target", kind: .folder, children: [.folder(TabFolder(title: "child", kind: .folder))])
        var tree = SidebarTree(regular: [.folder(inner), .folder(target)])
        let child = tree.folder(target.id)!.children[0].id
        // target(1) → child(2) → inner(3) → innermost(4): нельзя.
        XCTAssertFalse(tree.move(inner.id, to: SidebarContainer(zone: .regular, folderID: child)))
        XCTAssertTrue(tree.move(inner.id, to: SidebarContainer(zone: .regular, folderID: target.id)))
    }

    func testFolderCannotMoveIntoItself() {
        let child = TabFolder(title: "child", kind: .folder)
        let parent = TabFolder(title: "parent", kind: .folder, children: [.folder(child)])
        var tree = SidebarTree(regular: [.folder(parent)])
        XCTAssertFalse(tree.move(parent.id, to: SidebarContainer(zone: .regular, folderID: child.id)))
        XCTAssertFalse(tree.move(parent.id, to: SidebarContainer(zone: .regular, folderID: parent.id)))
    }

    func testGroupsHoldOnlyTabs() {
        let tabs = ids(2)
        var tree = SidebarTree(regular: [.tab(tabs[0])])
        let group = tree.insertOpenedTab(tabs[1], opener: tabs[0], anchor: tabs[0], grouping: true, groupTitle: "g")!
        XCTAssertFalse(tree.canCreateFolder(in: SidebarContainer(zone: .regular, folderID: group)))
        XCTAssertFalse(tree.insert(.folder(TabFolder(title: "f", kind: .folder)), into: SidebarContainer(zone: .regular, folderID: group)))
    }

    func testMoveBeforeAndAcrossZones() {
        let tabs = ids(3)
        var tree = SidebarTree(regular: tabs.map { .tab($0) })
        XCTAssertTrue(tree.move(tabs[2], before: tabs[0]))
        XCTAssertEqual(tree.orderedTabIDs, [tabs[2], tabs[0], tabs[1]])
        XCTAssertTrue(tree.move(tabs[1], to: .pinnedRoot))
        XCTAssertEqual(tree.zone(of: tabs[1]), .pinned)
        XCTAssertEqual(tree.orderedTabIDs.first, tabs[1], "Закреплённые идут первыми")
    }

    func testMoveDownWithinSameContainer() {
        let tabs = ids(3)
        var tree = SidebarTree(regular: tabs.map { .tab($0) })
        XCTAssertTrue(tree.move(tabs[0], to: .regularRoot, at: 3))
        XCTAssertEqual(tree.orderedTabIDs, [tabs[1], tabs[2], tabs[0]])
    }

    func testCreateFolderFromSelectionKeepsPosition() {
        let tabs = ids(4)
        var tree = SidebarTree(regular: tabs.map { .tab($0) })
        let folder = tree.createFolder(title: "F", containing: [tabs[1], tabs[2]])
        XCTAssertNotNil(folder)
        XCTAssertEqual(tree.regular.count, 3)
        XCTAssertEqual(tree.regular[1].id, folder)
        XCTAssertEqual(tree.orderedTabIDs, tabs)
    }

    func testReconcileDropsMissingAndAddsNewTabs() {
        let tabs = ids(3)
        var tree = SidebarTree(regular: [.tab(tabs[0]), .tab(UUID())])
        tree.reconcile(with: tabs, pinnedIDs: [tabs[2]])
        XCTAssertEqual(tree.regular, [.tab(tabs[0]), .tab(tabs[1])])
        XCTAssertEqual(tree.pinned, [.tab(tabs[2])])
    }

    func testVisibleTabsSkipCollapsedFolders() {
        let tabs = ids(3)
        var folder = TabFolder(title: "F", kind: .folder, children: [.tab(tabs[1])])
        folder.isExpanded = false
        var tree = SidebarTree(regular: [.tab(tabs[0]), .folder(folder), .tab(tabs[2])])
        XCTAssertEqual(tree.visibleTabIDs, [tabs[0], tabs[2]])
        tree.reveal(tabs[1])
        XCTAssertEqual(tree.visibleTabIDs, tabs)
    }

    func testTreeRoundTripsThroughJSON() throws {
        let tabs = ids(2)
        var tree = SidebarTree(regular: [.tab(tabs[0])])
        tree.insertOpenedTab(tabs[1], opener: tabs[0], anchor: tabs[0], grouping: true, groupTitle: "g")
        let data = try JSONEncoder().encode(tree)
        XCTAssertEqual(try JSONDecoder().decode(SidebarTree.self, from: data), tree)
    }
}
