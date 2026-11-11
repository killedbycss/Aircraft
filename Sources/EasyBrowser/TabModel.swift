import Foundation
import WebKit

/// Что показывает вкладка: веб-страницу или встроенный просмотрщик файла.
public enum TabContent: Equatable, Sendable {
    case web
    /// PDF: локальная копия файла (адрес вкладки — исходный URL).
    case pdf(URL)
    /// Markdown: локальный или скачанный файл.
    case markdown(URL)

    var isViewer: Bool { self != .web }
}

/// Модель данных для вкладки браузера
public struct TabModel: Identifiable, Equatable {
    public let id: UUID
    public var title: String
    public var url: URL?
    public var isLoading: Bool
    /// Прогресс загрузки страницы от 0 до 1 (WKWebView.estimatedProgress).
    public var loadProgress: Double = 0
    public var isHibernated: Bool
    public var isPinned: Bool
    public var pinnedURL: URL?
    public var favicon: NSImage?
    public var pageBackgroundColor: NSColor
    public var webView: WKWebView?
    /// Когда вкладку последний раз открывали — для автоархива.
    public var lastActiveAt: Date = Date()
    /// История «назад/вперёд» усыплённой вкладки.
    public var interactionState: Data?
    public var content: TabContent = .web
    public var isPlayingAudio = false
    public var isMuted = false
    /// Страница сейчас пользуется камерой или микрофоном.
    public var isCapturingMedia = false
    public var isInPictureInPicture = false

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

    /// Вкладку нельзя усыплять и архивировать: играет звук, идёт запись или картинка в картинке.
    public var isBusy: Bool { isPlayingAudio || isCapturingMedia || isInPictureInPicture }

    public static func == (lhs: TabModel, rhs: TabModel) -> Bool {
        lhs.id == rhs.id &&
        lhs.title == rhs.title &&
        lhs.url == rhs.url &&
        lhs.isLoading == rhs.isLoading &&
        lhs.loadProgress == rhs.loadProgress &&
        lhs.isHibernated == rhs.isHibernated &&
        lhs.isPinned == rhs.isPinned &&
        lhs.pinnedURL == rhs.pinnedURL &&
        lhs.pageBackgroundColor == rhs.pageBackgroundColor &&
        lhs.webView === rhs.webView &&
        lhs.content == rhs.content &&
        lhs.isPlayingAudio == rhs.isPlayingAudio &&
        lhs.isMuted == rhs.isMuted &&
        lhs.isCapturingMedia == rhs.isCapturingMedia &&
        lhs.isInPictureInPicture == rhs.isInPictureInPicture
    }
}
