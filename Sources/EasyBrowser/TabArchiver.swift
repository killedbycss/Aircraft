import Foundation
import AppKit

/// Автоархив: вкладки, которые давно не открывали, уходят в архив профиля.
@MainActor
final class TabArchiver {
    static let shared = TabArchiver()

    /// Часы до архивации; 0 — выключено. По умолчанию — сутки.
    static var interval: TimeInterval? {
        let hours = UserDefaults.standard.object(forKey: "autoArchiveHours") as? Double ?? 24
        return hours > 0 ? hours * 3600 : nil
    }

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            MainActor.assumeIsolated { TabArchiver.shared.run() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { TabArchiver.shared.run() }
        }
        run()
    }

    func run() {
        guard let interval = Self.interval else { return }
        for manager in AgentBrowser.allManagers where !manager.isIncognito {
            manager.archiveStaleTabs(olderThan: interval)
        }
    }
}

extension TabManager {
    /// Кандидаты: незакреплённые вкладки вне папок (группы можно), давно не открытые.
    /// Не трогаем активную, вкладки в сплите, со звуком, камерой или картинкой в картинке
    /// и вкладки из группы, в которой сейчас активная вкладка.
    func staleTabIDs(olderThan interval: TimeInterval, now: Date = Date()) -> [UUID] {
        let activeGroup = activeTabID.flatMap { tree.location(of: $0)?.container.folderID }
        return tabs.compactMap { tab in
            guard !tab.isPinned, tab.url != nil, tab.id != activeTabID,
                  tab.id != splitTabID, tab.id != splitPrimaryTabID, !tab.isBusy,
                  now.timeIntervalSince(tab.lastActiveAt) > interval,
                  let location = tree.location(of: tab.id) else { return nil }
            if let folderID = location.container.folderID {
                guard tree.folder(folderID)?.kind == .group, folderID != activeGroup, location.ancestors.count == 1 else { return nil }
            }
            return tab.id
        }
    }

    func archiveStaleTabs(olderThan interval: TimeInterval) {
        let ids = staleTabIDs(olderThan: interval)
        guard !ids.isEmpty else { return }
        archiveTabs(ids)
    }

    public func archiveTabs(_ ids: [UUID]) {
        guard let archive else { return }
        let records = ids.compactMap { id -> ClosedTab? in
            guard var record = closedRecord(for: id) else { return nil }
            // В архиве храним только адрес, без истории переходов.
            record.tab.interactionState = nil
            return record
        }
        archive.add(records)
        for id in ids { closeTab(id: id, remember: false) }
    }

    public func restoreFromArchive(_ entry: ClosedTab) {
        archive?.remove(entry.id)
        restore(entry)
    }
}
