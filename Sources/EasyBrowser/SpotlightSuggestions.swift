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
        /// Готовый адрес (URL-система).
        case direct(String)
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let subtitle: String
    let symbol: String
    /// Адрес страницы — для значка сайта.
    var url: URL? = nil

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
            // Название сайта из истории, а не голый адрес.
            let known = manager.history?.search(host, limit: 6).first { HistoryStore.displayHost($0.url) == host && !$0.title.isEmpty }
            result.append(.init(kind: .autocomplete(host), title: known?.title ?? host, subtitle: host,
                                symbol: "arrow.right.circle.fill", url: URL(string: "https://" + host)))
            seenURLs.insert("https://" + host)
        }

        let tabs = manager.tabs.filter { tab in
            guard tab.id != manager.activeTabID, tab.url != nil else { return false }
            let haystack = (tab.title + " " + (tab.url?.absoluteString ?? "")).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }.prefix(3)
        for tab in tabs {
            _ = seen(tab.url)
            result.append(.init(kind: .tab(tab.id), title: tab.title.isEmpty ? Self.shortURL(tab.url!) : tab.title,
                                subtitle: "Открытая вкладка · \(tab.url.map(Self.shortURL) ?? "")",
                                symbol: "square.on.square", url: tab.url))
        }

        for match in manager.bookmarks.search(query, limit: 3) where !seen(match.item.url) {
            guard let url = match.item.url else { continue }
            result.append(.init(kind: .bookmark(url), title: match.item.title.isEmpty ? Self.shortURL(url) : match.item.title,
                                subtitle: ([Self.shortURL(url)] + match.path).joined(separator: " · "), symbol: "bookmark.fill", url: url))
        }

        for entry in manager.history?.search(query, limit: 6) ?? [] where !seen(entry.url) {
            result.append(.init(kind: .history(entry.url), title: entry.title.isEmpty ? Self.shortURL(entry.url) : entry.title,
                                subtitle: Self.shortURL(entry.url), symbol: "clock", url: entry.url))
            if result.count >= 9 { break }
        }

        for entry in manager.archive?.search(query, limit: 2) ?? [] where !seen(entry.tab.url) {
            result.append(.init(kind: .archive(entry.id), title: entry.tab.title, subtitle: "Архив · \(entry.tab.url?.host ?? "")",
                                symbol: "archivebox", url: entry.tab.url))
        }

        for suggestion in remote.prefix(5) where suggestion.lowercased() != query.lowercased() {
            result.append(.init(kind: .search(suggestion), title: suggestion, subtitle: "", symbol: "magnifyingglass"))
        }
        return Array(result.prefix(12))
    }

    nonisolated static func shortURL(_ url: URL) -> String {
        var value = url.absoluteString
        for prefix in ["https://", "http://", "www."] where value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        if value.hasSuffix("/") { value.removeLast() }
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

/// Список подсказок под полем Spotlight: видно не больше пяти строк, остальное — прокруткой.
struct SpotlightSuggestionList: View {
    let items: [SpotlightSuggestion]
    let selectedIndex: Int
    let onSelect: (SpotlightSuggestion) -> Void

    static let rowHeight: CGFloat = 46
    static let visibleRows = 5

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        SpotlightRow(item: item, selected: index == selectedIndex) { onSelect(item) }
                            .id(index)
                    }
                }
                .padding(6)
            }
            .scrollIndicators(items.count > Self.visibleRows ? .automatic : .never)
            .frame(height: CGFloat(min(items.count, Self.visibleRows)) * (Self.rowHeight + 2) + 12)
            .onChange(of: selectedIndex) { _, index in
                guard index >= 0 else { return }
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(index) }
            }
        }
    }
}

private struct SpotlightRow: View {
    let item: SpotlightSuggestion
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Group {
                    if item.url != nil, item.symbol != "magnifyingglass" {
                        FaviconImage(url: item.url, size: 18)
                    } else {
                        Image(systemName: item.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selected ? Color.white : .secondary)
                    }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(selected ? Color.white : .primary)
                        .lineLimit(1)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                if let hint {
                    Text(hint)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: SpotlightSuggestionList.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.06 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var hint: String? {
        switch item.kind {
        case .tab: "Переключиться"
        case .archive: "Вернуть"
        default: selected ? "↩" : nil
        }
    }
}
