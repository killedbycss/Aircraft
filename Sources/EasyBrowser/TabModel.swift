import Foundation
import WebKit

/// Модель данных для вкладки браузера
public struct TabModel: Identifiable, Equatable {
    public let id: UUID
    public var title: String
    public var url: URL?
    public var isLoading: Bool
    public var isHibernated: Bool
    public var isPinned: Bool
    public var pinnedURL: URL?
    public var favicon: NSImage?
    public var pageBackgroundColor: NSColor
    public var webView: WKWebView?

    public init(
        id: UUID = UUID(),
        title: String = "Новая вкладка",
        url: URL? = nil,
        isLoading: Bool = false,
        isHibernated: Bool = false,
        isPinned: Bool = false,
        pinnedURL: URL? = nil,
        favicon: NSImage? = nil,
        pageBackgroundColor: NSColor = .windowBackgroundColor,
        webView: WKWebView? = nil
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.isLoading = isLoading
        self.isHibernated = isHibernated
        self.isPinned = isPinned
        self.pinnedURL = pinnedURL
        self.favicon = favicon
        self.pageBackgroundColor = pageBackgroundColor
        self.webView = webView
    }

    public static func == (lhs: TabModel, rhs: TabModel) -> Bool {
        lhs.id == rhs.id &&
        lhs.title == rhs.title &&
        lhs.url == rhs.url &&
        lhs.isLoading == rhs.isLoading &&
        lhs.isHibernated == rhs.isHibernated &&
        lhs.isPinned == rhs.isPinned &&
        lhs.pinnedURL == rhs.pinnedURL &&
        lhs.pageBackgroundColor == rhs.pageBackgroundColor &&
        lhs.webView === rhs.webView
    }
}
