import XCTest
import AppKit
@testable import aircraft

final class MarkdownRendererTests: XCTestCase {
    private func html(_ markdown: String) -> String { MarkdownRenderer.render(markdown).html }

    func testHeadingsGetUniqueIDs() {
        let result = MarkdownRenderer.render("# Привет мир\n\n## Раздел\n\n## Раздел")
        XCTAssertEqual(result.headings.map(\.id), ["привет-мир", "раздел", "раздел-1"])
        XCTAssertTrue(result.html.contains("<h1 id=\"привет-мир\">"))
    }

    func testInlineFormatting() {
        let output = html("**жирный**, *курсив*, ~~зачёркнутый~~ и `код <b>`")
        XCTAssertTrue(output.contains("<strong>жирный</strong>"))
        XCTAssertTrue(output.contains("<em>курсив</em>"))
        XCTAssertTrue(output.contains("<del>зачёркнутый</del>"))
        XCTAssertTrue(output.contains("<code>код &lt;b&gt;</code>"))
    }

    func testLinksImagesAndReferences() {
        let output = html("[сайт](https://example.com \"Пример\") ![logo](img/logo.png) [ref]\n\n[ref]: https://ref.example")
        XCTAssertTrue(output.contains("<a href=\"https://example.com\" title=\"Пример\">сайт</a>"))
        XCTAssertTrue(output.contains("<img src=\"img/logo.png\" alt=\"logo\""))
        XCTAssertTrue(output.contains("<a href=\"https://ref.example\">ref</a>"))
    }

    func testJavascriptLinksAreNeutralised() {
        XCTAssertTrue(html("[x](javascript:alert(1))").contains("href=\"#\""))
    }

    func testFencedCodeIsEscaped() {
        let output = html("```swift\nlet a = \"<script>\"\n```")
        XCTAssertTrue(output.contains("<pre><code class=\"language-swift\" data-lang=\"swift\">"))
        XCTAssertTrue(output.contains("&lt;script&gt;"))
    }

    func testListsAndTasks() {
        let output = html("- one\n- two\n  - nested\n- [x] done\n\n1. first\n2. second")
        XCTAssertTrue(output.contains("<ul>"))
        XCTAssertTrue(output.contains("<li>one"))
        XCTAssertTrue(output.contains("<li>nested"))
        XCTAssertTrue(output.contains("<input type=\"checkbox\" disabled checked>"))
        XCTAssertTrue(output.contains("<ol>"))
    }

    func testTable() {
        let output = html("| A | B |\n|:--|--:|\n| 1 | 2 |")
        XCTAssertTrue(output.contains("<th style=\"text-align:left\">A</th>"))
        XCTAssertTrue(output.contains("<td style=\"text-align:right\">2</td>"))
    }

    func testBlockquoteAndRule() {
        let output = html("> цитата\n\n---")
        XCTAssertTrue(output.contains("<blockquote>\n<p>цитата</p>"))
        XCTAssertTrue(output.contains("<hr>"))
    }

    func testPageHasContentSecurityPolicy() {
        let page = MainActor.assumeIsolated { MarkdownViewer.page(markdown: "# T", title: "t.md", scrollY: 0) }
        XCTAssertTrue(page.contains("Content-Security-Policy"))
        XCTAssertTrue(page.contains("script-src 'nonce-"))
    }
}

@MainActor
final class StoreTests: XCTestCase {
    func testBookmarksFoldersRespectDepthLimit() {
        let store = BookmarkStore(url: nil)
        var parent: UUID?
        for _ in 1...BookmarkStore.maxFolderDepth {
            parent = store.addFolder(title: "F", in: parent)?.id
            XCTAssertNotNil(parent)
        }
        XCTAssertNil(store.addFolder(title: "too deep", in: parent))
        let bookmark = store.add(title: "Example", url: URL(string: "https://example.com/")!, to: parent)
        XCTAssertTrue(store.contains(URL(string: "https://example.com")))
        XCTAssertEqual(store.search("exam").first?.item.id, bookmark.id)
        XCTAssertEqual(store.search("exam").first?.path.count, BookmarkStore.maxFolderDepth)
    }

    func testImportedFoldersAreFlattenedAtLimit() {
        let store = BookmarkStore(url: nil)
        let leaf = BookmarkItem(title: "leaf", url: URL(string: "https://leaf.example")!)
        var deep = BookmarkItem(title: "L5", url: nil, children: [leaf])
        for level in (1...4).reversed() { deep = BookmarkItem(title: "L\(level)", url: nil, children: [deep]) }
        store.addImported(deep)
        XCTAssertTrue(store.contains(URL(string: "https://leaf.example")))
        XCTAssertLessThanOrEqual(store.items.map(\.folderHeight).max() ?? 0, BookmarkStore.maxFolderDepth)
    }

    func testHistorySearchAndAutocomplete() {
        let history = HistoryStore(url: nil)
        history.recordVisit(url: URL(string: "https://github.com/killedbycss/Aircraft")!, title: "Aircraft — GitHub")
        history.recordVisit(url: URL(string: "https://github.com/")!, title: "GitHub")
        history.recordVisit(url: URL(string: "https://news.ycombinator.com/")!, title: "Hacker News")
        XCTAssertEqual(history.autocompleteHost("git"), "github.com")
        XCTAssertEqual(history.search("airc").first?.title, "Aircraft — GitHub")
        XCTAssertEqual(history.search("hacker").count, 1)
        history.deleteHost("github.com")
        XCTAssertNil(history.autocompleteHost("git"))
        XCTAssertFalse(history.isEmpty)
        history.clearAll()
        XCTAssertTrue(history.isEmpty)
    }

    func testSiteSettingsZoomAndPermissions() {
        let store = SiteSettingsStore(url: nil)
        store.setZoom(1.25, for: "www.example.com")
        XCTAssertEqual(store.zoom(for: "example.com"), 1.25)
        store.setDecision(.allow, .camera, for: "example.com")
        XCTAssertEqual(store.decision(.camera, for: "www.example.com"), .allow)
        store.setZoom(1, for: "example.com")
        store.setDecision(nil, .camera, for: "example.com")
        XCTAssertTrue(store.sites.isEmpty, "Пустые настройки сайта удаляются")
    }

    func testArchiveKeepsLimit() {
        let archive = TabArchive(url: nil)
        let entries = (0..<(TabArchive.limit + 5)).map { index in
            ClosedTab(id: UUID(), tab: SavedTab(id: UUID(), title: "Tab \(index)", url: URL(string: "https://e.com/\(index)"),
                                                 isPinned: false, pinnedURL: nil),
                      closedAt: Date(), zone: .regular, folderID: nil, index: 0)
        }
        archive.add(entries)
        XCTAssertEqual(archive.entries.count, TabArchive.limit)
        XCTAssertEqual(archive.search("Tab 3", limit: 50).isEmpty, false)
    }
}

final class BrowserImportTests: XCTestCase {
    func testParsesNetscapeBookmarks() {
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <TITLE>Bookmarks</TITLE><H1>Bookmarks</H1>
        <DL><p>
            <DT><H3>Работа</H3>
            <DL><p>
                <DT><A HREF="https://github.com/" ADD_DATE="1">GitHub</A>
                <DT><H3>Docs</H3>
                <DL><p>
                    <DT><A HREF="https://developer.apple.com/documentation/">Apple &amp; Docs</A>
                </DL><p>
            </DL><p>
            <DT><A HREF="https://example.com">Example</A>
            <DT><A HREF="javascript:void(0)">Bookmarklet</A>
        </DL><p>
        """
        let root = BrowserImport.parseNetscape(html)
        XCTAssertEqual(BrowserImport.countBookmarks(root), 3)
        XCTAssertEqual(root.children.first?.title, "Работа")
        XCTAssertEqual(root.children.first?.children.last?.children.first?.title, "Apple & Docs")
        XCTAssertEqual(root.children.last?.url?.absoluteString, "https://example.com")
    }
}

@MainActor
final class WebAppMakerTests: XCTestCase {
    func testBuildsSignedAppBundle() throws {
        let helper = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/debug/aircraft-webapp")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: helper.path), "Сначала swift build")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("aircraft-webapp-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let icon = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let app = try WebAppMaker.build(name: "Example", url: URL(string: "https://example.com/app")!, icon: icon,
                                        helper: helper, in: folder)
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(info?["AircraftWebAppURL"] as? String, "https://example.com/app")
        XCTAssertEqual(info?["CFBundleIdentifier"] as? String, "com.taras.aircraft.webapp.example-com")
        XCTAssertEqual(info?["CFBundleIconFile"] as? String, "AppIcon")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Resources/AppIcon.icns").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/aircraft-webapp").path))
    }
}
