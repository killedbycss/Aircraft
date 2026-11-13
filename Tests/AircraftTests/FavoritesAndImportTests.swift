import XCTest
@testable import aircraft

final class FavoritesAndImportTests: XCTestCase {
    func testOldSessionWithoutFavoritesDecodes() throws {
        let id = UUID()
        let json = #"{"pinned":[{"tab":{"_0":"\#(id.uuidString)"}}],"regular":[]}"#
        let tree = try JSONDecoder().decode(SidebarTree.self, from: Data(json.utf8))
        XCTAssertEqual(tree.favorites, [])
        XCTAssertEqual(tree.pinned, [.tab(id)])
    }

    func testFavoritesZoneHoldsTabsOnly() {
        let tab = UUID()
        var tree = SidebarTree(regular: [.tab(tab)])
        XCTAssertTrue(tree.move(tab, to: .favoritesRoot))
        XCTAssertEqual(tree.zone(of: tab), .favorites)
        XCTAssertEqual(tree.orderedTabIDs, [tab])
        let folder = TabFolder(title: "F", kind: .folder)
        XCTAssertFalse(tree.canInsert(.folder(folder), into: .favoritesRoot))
        XCTAssertFalse(tree.canCreateFolder(in: .favoritesRoot))
    }

    func testFolderColorIsOptional() throws {
        let json = #"{"id":"\#(UUID().uuidString)","title":"A","kind":"folder","colorIndex":0,"isExpanded":true,"children":[]}"#
        let folder = try JSONDecoder().decode(TabFolder.self, from: Data(json.utf8))
        XCTAssertNil(folder.folderColor)
    }

    func testParsesArcSidebar() throws {
        let json = """
        {"sidebar":{"containers":[{"global":{}},{
          "spaces":["s1",{"id":"s1","title":"Home","containerIDs":["unpinned","u1","pinned","p1"]}],
          "topAppsContainerIDs":[{"default":true},"top"],
          "items":[
            "top",{"id":"top","childrenIds":["f1"],"data":{"itemContainer":{"containerType":{"topApps":{}}}}},
            "f1",{"id":"f1","parentID":"top","childrenIds":[],"title":null,"data":{"tab":{"savedURL":"https://mail.example.com/","savedTitle":"Mail"}}},
            "p1",{"id":"p1","childrenIds":["t1","l1"],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"s1"}}}}},
            "t1",{"id":"t1","parentID":"p1","childrenIds":[],"title":"Docs","data":{"tab":{"savedURL":"https://docs.example.com/","savedTitle":"Old"}}},
            "l1",{"id":"l1","parentID":"p1","childrenIds":["t2"],"title":"Work","data":{"list":{}}},
            "t2",{"id":"t2","parentID":"l1","childrenIds":[],"title":null,"data":{"tab":{"savedURL":"https://jira.example.com/","savedTitle":"Jira"}}},
            "u1",{"id":"u1","childrenIds":[],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"s1"}}}}}
          ]}]}}
        """
        let result = try BrowserImport.parseArcSidebar(Data(json.utf8))
        XCTAssertEqual(result.favorites, [.tab(title: "Mail", url: URL(string: "https://mail.example.com/")!)])
        XCTAssertEqual(result.pinned, [
            .tab(title: "Docs", url: URL(string: "https://docs.example.com/")!),
            .folder(title: "Work", children: [.tab(title: "Jira", url: URL(string: "https://jira.example.com/")!)])
        ])
        XCTAssertEqual(result.count, 3)
    }

    @MainActor
    func testImportPinnedSkipsDuplicatesAndKeepsFolders() {
        let manager = TabManager(window: nil, incognito: true)
        let result = PinnedImportResult(
            favorites: [.tab(title: "Mail", url: URL(string: "https://mail.example.com/")!)],
            pinned: [.folder(title: "Work", children: [.tab(title: "Jira", url: URL(string: "https://jira.example.com/")!)])])
        XCTAssertEqual(manager.importPinned(result), 2)
        XCTAssertEqual(manager.importPinned(result), 0, "Повторный импорт не дублирует закрепы")
        XCTAssertEqual(manager.tree.favorites.count, 1)
        guard case .folder(let folder) = manager.tree.pinned.first else { return XCTFail("Ожидалась папка") }
        XCTAssertEqual(folder.title, "Work")
        XCTAssertTrue(manager.tabs.filter { $0.url?.host == "jira.example.com" }.allSatisfy(\.isPinned))
    }

    @MainActor
    func testClosingWindowHandsOverPinnedTabs() {
        let closing = TabManager(window: nil, incognito: true)
        let staying = TabManager(window: nil, incognito: true)
        closing.importPinned(PinnedImportResult(pinned: [.tab(title: "A", url: URL(string: "https://a.example.com/")!)]))
        staying.adoptPinned(from: closing)
        XCTAssertEqual(staying.tabs.filter(\.isPinned).compactMap(\.url?.host), ["a.example.com"])
        staying.adoptPinned(from: closing)
        XCTAssertEqual(staying.tabs.filter(\.isPinned).count, 1)
    }
}

extension FavoritesAndImportTests {
    @MainActor
    func testCommandWKeepsPinnedTabs() {
        let manager = TabManager(window: nil, incognito: true)
        manager.importPinned(PinnedImportResult(
            favorites: [.tab(title: "Tile", url: URL(string: "https://tile.example.com/")!)],
            pinned: [.tab(title: "Pin", url: URL(string: "https://pin.example.com/")!),
                     .folder(title: "F", children: [.tab(title: "Deep", url: URL(string: "https://deep.example.com/")!)])]))
        let pinnedIDs = manager.tabs.filter(\.isPinned).map(\.id)
        XCTAssertEqual(pinnedIDs.count, 3)
        for id in pinnedIDs {
            manager.selectTab(id: id)
            manager.closeActiveTabFromShortcut()
            manager.closeActiveTabFromShortcut()
        }
        XCTAssertEqual(Set(manager.tabs.filter(\.isPinned).map(\.id)), Set(pinnedIDs), "⌘W не удаляет закрепы")
    }
}
