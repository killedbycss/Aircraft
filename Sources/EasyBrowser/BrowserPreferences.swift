import Foundation

struct SearchEngineOption: Identifiable, Equatable {
    let id: String
    let title: String
    let queryURL: String

    static let popular: [SearchEngineOption] = [
        .init(id: "duckduckgo", title: "DuckDuckGo", queryURL: "https://duckduckgo.com/?q={query}"),
        .init(id: "google", title: "Google", queryURL: "https://www.google.com/search?q={query}"),
        .init(id: "yandex", title: "Яндекс", queryURL: "https://yandex.ru/search/?text={query}"),
        .init(id: "bing", title: "Bing", queryURL: "https://www.bing.com/search?q={query}"),
        .init(id: "brave", title: "Brave", queryURL: "https://search.brave.com/search?q={query}")
    ]

    static func queryTemplate(for id: String, customURL: String) -> String {
        if id == "custom" { return customURL }
        return popular.first(where: { $0.id == id })?.queryURL ?? popular[0].queryURL
    }
}

enum URLSystemStore {
    static func prefixes(json: String, legacyPrefix: String) -> [String] {
        var values: [String] = []
        if let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            values = decoded
        }
        if values.isEmpty, let legacy = URLRouter.normalizedPrefix(legacyPrefix) {
            values = [legacy]
        }
        return values.compactMap(URLRouter.normalizedPrefix).uniqued()
    }

    static func json(for prefixes: [String]) -> String {
        guard let data = try? JSONEncoder().encode(prefixes),
              let result = String(data: data, encoding: .utf8) else { return "[]" }
        return result
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
