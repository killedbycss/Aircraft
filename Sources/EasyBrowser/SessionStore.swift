import Foundation
import AppKit

/// Вкладка на диске.
public struct SavedTab: Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL?
    public var isPinned: Bool
    public var pinnedURL: URL?
    public var lastActiveAt: Date?
    /// История «назад/вперёд» (`WKWebView.interactionState`).
    public var interactionState: Data?
}

/// Закрытая или заархивированная вкладка — её можно вернуть на прежнее место.
public struct ClosedTab: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var tab: SavedTab
    public var closedAt: Date
    public var zone: SidebarZone
    public var folderID: UUID?
    public var index: Int
}

/// Вкладки одного профиля в одном окне.
public struct SavedTabSet: Codable, Equatable, Sendable {
    public var tabs: [SavedTab] = []
    public var tree = SidebarTree()
    public var activeTabID: UUID?
    public var closed: [ClosedTab] = []
}

public struct SavedWindow: Codable, Equatable, Sendable {
    public var id: UUID
    public var activeProfileID: UUID
    /// Ключ — id профиля.
    public var sets: [String: SavedTabSet]
}

private struct SessionFile: Codable {
    var windows: [SavedWindow]
}

/// Сессия всех окон: какие окна открыты и какие в них вкладки для каждого профиля.
/// Запись на диск откладывается на секунду, чтобы не писать файл на каждое изменение заголовка.
@MainActor
final class SessionStore {
    static let shared = SessionStore()

    private(set) var windows: [SavedWindow] = []
    private var claimed: Set<UUID> = []
    private var live: [UUID: WeakTabManager] = [:]
    private var flushTask: Task<Void, Never>?
    /// Выход из приложения: закрытие окон не удаляет их из сессии.
    var isTerminating = false

    private struct WeakTabManager { weak var value: TabManager? }

    private var fileURL: URL { AircraftPaths.root.appendingPathComponent("session.json") }

    private init() {
        if let file = JSONFile.load(SessionFile.self, from: fileURL) {
            windows = file.windows
        } else if let migrated = Self.migrateLegacySession() {
            windows = [migrated]
        }
    }

    /// Первое окно из сессии, которое ещё не открыто.
    func claimWindow() -> SavedWindow? {
        guard let window = windows.first(where: { !claimed.contains($0.id) }) else { return nil }
        claimed.insert(window.id)
        return window
    }

    func claimWindow(id: UUID) -> SavedWindow? {
        guard let window = windows.first(where: { $0.id == id }), !claimed.contains(id) else { return nil }
        claimed.insert(id)
        return window
    }

    var unclaimedWindowIDs: [UUID] { windows.map(\.id).filter { !claimed.contains($0) } }

    func register(_ manager: TabManager) {
        claimed.insert(manager.windowID)
        live[manager.windowID] = WeakTabManager(value: manager)
        markDirty()
    }

    func markDirty() {
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.flushTask = nil
            self?.flush()
        }
    }

    /// Снимок всех живых окон и запись на диск.
    func flush() {
        flushTask?.cancel()
        flushTask = nil
        for (id, reference) in live {
            guard let manager = reference.value else {
                live[id] = nil
                continue
            }
            let snapshot = manager.snapshotWindow()
            if let index = windows.firstIndex(where: { $0.id == id }) {
                windows[index] = snapshot
            } else {
                windows.append(snapshot)
            }
        }
        JSONFile.save(SessionFile(windows: windows), to: fileURL)
    }

    /// Окно закрыли. Последнее окно остаётся в сессии, чтобы вкладки вернулись при следующем запуске.
    func windowClosed(_ manager: TabManager) {
        let id = manager.windowID
        guard live[id] != nil else { return }
        if isTerminating {
            flush()
            return
        }
        let othersOpen = live.contains { $0.key != id && $0.value.value != nil }
        if othersOpen {
            live[id] = nil
            claimed.remove(id)
            windows.removeAll { $0.id == id }
            flush()
        } else {
            flush()
            live[id] = nil
            claimed.remove(id)
        }
    }

    func removeProfile(_ profileID: UUID) {
        for index in windows.indices {
            windows[index].sets[profileID.uuidString] = nil
        }
        markDirty()
    }

    /// Сессия версии 0.3 хранилась в UserDefaults одним списком на все окна.
    private static func migrateLegacySession() -> SavedWindow? {
        struct LegacySession: Codable {
            struct Tab: Codable {
                var id: UUID
                var title: String
                var url: URL?
                var isPinned: Bool
                var pinnedURL: URL?
            }
            var tabs: [Tab]
            var activeTabID: UUID?
        }
        guard let data = UserDefaults.standard.data(forKey: "browserSessionV1"),
              let legacy = try? JSONDecoder().decode(LegacySession.self, from: data),
              !legacy.tabs.isEmpty else { return nil }
        var set = SavedTabSet()
        set.tabs = legacy.tabs.map {
            SavedTab(id: $0.id, title: $0.title, url: $0.url, isPinned: $0.isPinned, pinnedURL: $0.pinnedURL)
        }
        set.tree.reconcile(with: set.tabs.map(\.id), pinnedIDs: Set(set.tabs.filter(\.isPinned).map(\.id)))
        set.activeTabID = legacy.activeTabID
        let profileID = ProfileStore.shared.defaultProfile.id
        return SavedWindow(id: UUID(), activeProfileID: profileID, sets: [profileID.uuidString: set])
    }
}
