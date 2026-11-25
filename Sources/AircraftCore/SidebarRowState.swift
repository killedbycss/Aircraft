import Foundation

/// Value snapshot for deciding whether a sidebar row needs a redraw.
/// Loading progress is intentionally owned by a separate view.
public struct SidebarRowState: Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL?
    public var contentKind: String
    public var faviconToken: Int?
    public var isHibernated: Bool
    public var isPinned: Bool
    public var isPlayingAudio: Bool
    public var isMuted: Bool
    public var isCapturingMedia: Bool
    public var isInPictureInPicture: Bool
    public var isActive: Bool
    public var isSelected: Bool
    public var isSplit: Bool

    public init(id: UUID, title: String, url: URL?, contentKind: String, faviconToken: Int?,
                isHibernated: Bool, isPinned: Bool, isPlayingAudio: Bool, isMuted: Bool,
                isCapturingMedia: Bool, isInPictureInPicture: Bool, isActive: Bool,
                isSelected: Bool, isSplit: Bool) {
        self.id = id
        self.title = title
        self.url = url
        self.contentKind = contentKind
        self.faviconToken = faviconToken
        self.isHibernated = isHibernated
        self.isPinned = isPinned
        self.isPlayingAudio = isPlayingAudio
        self.isMuted = isMuted
        self.isCapturingMedia = isCapturingMedia
        self.isInPictureInPicture = isInPictureInPicture
        self.isActive = isActive
        self.isSelected = isSelected
        self.isSplit = isSplit
    }
}
