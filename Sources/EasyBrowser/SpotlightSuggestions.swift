import SwiftUI
import AppKit

/// Строка подсказки в Spotlight.
struct SpotlightSuggestion: Identifiable, Equatable {
    enum Kind: Equatable {
        case autocomplete(String)
        case tab(UUID)
        case bookmark(URL)
        case history(URL)
        case archive(UUID)
        case search(String)
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String
    let symbol: String

    static func == (lhs: SpotlightSuggestion, rhs: SpotlightSuggestion) -> Bool {
        lhs.kind == rhs.kind && lhs.title == rhs.title
    }
}

/// Подбор подсказок: открытые вкладки, закладки, история, архив — локально;
/// подсказки поисковика — по сети с задержкой (отключаются в настройках).
@MainActor
@Observable
final class SpotlightSuggestionEngine {
    private(set) var items: [SpotlightSuggestion] = []
    @ObservationIgnored private var remoteTask: Task<Void, Never>?
    @ObservationIgnored private var remote: [String] = []
    @ObservationIgnored private var lastQuery = ""
    @ObservationIgnored private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        return URLSession(configuration: configuration)
    }()

    func update(query raw: String, manager: TabManager) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        lastQuery = query
        remoteTask?.cancel()
        guard !query.isEmpty else {
            items = []
            remote = []
            return
        }
        items = buildLocal(query, manager: manager)
        guard Self.remoteEnabled, !query.contains("://"), query.count < 120 else { return }
        remoteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let suggestions = await Self.fetchRemote(query)
            guard !Task.isCancelled, let self, self.lastQuery == query else { return }
            self.remote = suggestions
            self.items = self.buildLocal(query, manager: manager)
        }
    }

    static var remoteEnabled: Bool { UserDefaults.standard.object(forKey: "searchSuggestions") as? Bool ?? true }

    private func buildLocal(_ query: String, manager: TabManager) -> [SpotlightSuggestion] {
        var result: [SpotlightSuggestion] = []
        var seenURLs = Set<String>()
        func seen(_ url: URL?) -> Bool {
            guard let url else { return false }
            return !seenURLs.insert(BookmarkStore.key(url)).inserted
        }
        let words = query.lowercased().split(separator: " ").map(String.init)

        if let host = manager.history?.autocompleteHost(query) {
            result.append(.init(kind: .autocomplete(host), title: host, subtitle: "Перейти на сайт", symbol: "arrow.right.circle.fill"))
            seenURLs.insert("https://" + host)
        }

        let tabs = manager.tabs.filter { tab in
            guard tab.id != manager.activeTabID, tab.url != nil else { return false }
            let haystack = (tab.title + " " + (tab.url?.absoluteString ?? "")).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }.prefix(3)
        for tab in tabs {
            _ = seen(tab.url)
            result.append(.init(kind: .tab(tab.id), title: tab.title, subtitle: "Открытая вкладка · \(tab.url?.host ?? "")",
                                symbol: "square.on.square"))
        }

        for match in manager.bookmarks.search(query, limit: 3) where !seen(match.item.url) {
            guard let url = match.item.url else { continue }
            result.append(.init(kind: .bookmark(url), title: match.item.title,
                                subtitle: ([url.host ?? ""] + match.path).joined(separator: " · "), symbol: "bookmark.fill"))
        }

        for entry in manager.history?.search(query, limit: 6) ?? [] where !seen(entry.url) {
            result.append(.init(kind: .history(entry.url), title: entry.title.isEmpty ? entry.url.absoluteString : entry.title,
                                subtitle: Self.shortURL(entry.url), symbol: "clock"))
            if result.count >= 9 { break }
        }

        for entry in manager.archive?.search(query, limit: 2) ?? [] where !seen(entry.tab.url) {
            result.append(.init(kind: .archive(entry.id), title: entry.tab.title, subtitle: "Архив · \(entry.tab.url?.host ?? "")",
                                symbol: "archivebox"))
        }

        for suggestion in remote.prefix(5) where suggestion.lowercased() != query.lowercased() {
            result.append(.init(kind: .search(suggestion), title: suggestion, subtitle: "", symbol: "magnifyingglass"))
        }
        return Array(result.prefix(12))
    }

    private static func shortURL(_ url: URL) -> String {
        var value = url.absoluteString
        for prefix in ["https://", "http://", "www."] where value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        return value
    }

    /// Формат OpenSearch: `["запрос", ["подсказка 1", "подсказка 2", …]]`.
    private static func fetchRemote(_ query: String) async -> [String] {
        let engine = UserDefaults.standard.string(forKey: "searchEngine") ?? "duckduckgo"
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }
        let template: String
        switch engine {
        case "google": template = "https://suggestqueries.google.com/complete/search?client=firefox&q="
        case "yandex": template = "https://suggest.yandex.ru/suggest-ff.cgi?part="
        case "bing": template = "https://api.bing.com/osjson.aspx?query="
        case "brave": template = "https://search.brave.com/api/suggest?q="
        case "custom": return []
        default: template = "https://duckduckgo.com/ac/?type=list&q="
        }
        guard let url = URL(string: template + encoded),
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              json.count > 1, let list = json[1] as? [String] else { return [] }
        return list
    }
}

/// Список подсказок под полем Spotlight.
struct SpotlightSuggestionList: View {
    let items: [SpotlightSuggestion]
    let selectedIndex: Int
    let onSelect: (SpotlightSuggestion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button { onSelect(item) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(index == selectedIndex ? Color.accentColor : .secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.system(size: 12)).lineLimit(1)
                            if !item.subtitle.isEmpty {
                                Text(item.subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if case .tab = item.kind {
                            Text("Перейти").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: item.subtitle.isEmpty ? 30 : 38)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(index == selectedIndex ? Color.accentColor.opacity(0.14) : Color.clear)
            }
        }
        .padding(.vertical, items.isEmpty ? 0 : 4)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
