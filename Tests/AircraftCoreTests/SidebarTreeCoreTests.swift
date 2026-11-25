import Foundation
import XCTest
import AircraftCore

final class SidebarTreeCoreTests: XCTestCase {
    func testGroupAndOrderSurviveSerialization() throws {
        let opener = UUID()
        let child = UUID()
        var tree = SidebarTree(regular: [.tab(opener)])
        XCTAssertNotNil(tree.insertOpenedTab(child, opener: opener, anchor: opener,
                                             grouping: true, groupTitle: "example.com"))
        let decoded = try JSONDecoder().decode(SidebarTree.self, from: JSONEncoder().encode(tree))
        XCTAssertEqual(decoded, tree)
        XCTAssertEqual(decoded.orderedTabIDs, [opener, child])
    }

    func testMovingFolderIntoDescendantIsRejected() {
        let child = TabFolder(title: "Child", kind: .folder)
        let parent = TabFolder(title: "Parent", kind: .folder, children: [.folder(child)])
        var tree = SidebarTree(regular: [.folder(parent)])
        XCTAssertFalse(tree.move(parent.id, to: SidebarContainer(zone: .regular, folderID: child.id)))
        XCTAssertEqual(tree.regular, [.folder(parent)])
    }

    func testSidebarRowStateChangesOnlyForVisibleState() {
        let id = UUID()
        let first = SidebarRowState(id: id, title: "Example", url: URL(string: "https://example.com"),
                                    contentKind: "web", faviconToken: nil, isHibernated: false,
                                    isPinned: false, isPlayingAudio: false, isMuted: false,
                                    isCapturingMedia: false, isInPictureInPicture: false,
                                    isActive: false, isSelected: false, isSplit: false)
        XCTAssertEqual(first, first)
        var changed = first
        changed.isActive = true
        XCTAssertNotEqual(first, changed)
        changed = first
        changed.title = "Renamed"
        XCTAssertNotEqual(first, changed)
    }
}
