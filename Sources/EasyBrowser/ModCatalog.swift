import Foundation

enum ModCatalog {
    // SECURITY REVIEW: user mods must declare bounded HTTP(S) hosts. A bare wildcard host is rejected.
    static func validatedMatchPatterns(in source: String) -> [String]? {
        let lines = source.components(separatedBy: .newlines)
        let declarations = lines.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("// @match ") || trimmed.hasPrefix("/* @match ") else { return nil }
            return trimmed.replacingOccurrences(of: "*/", with: "")
                .components(separatedBy: "@match ").last?.trimmingCharacters(in: .whitespaces)
        }
        guard !declarations.isEmpty else { return nil }
        var patterns: [String] = []
        for declaration in declarations {
            guard let url = URLComponents(string: declaration),
                  let scheme = url.scheme, ["http", "https"].contains(scheme),
                  let host = url.host?.lowercased(), !host.isEmpty,
                  host != "*", !host.contains(".."),
                  host.range(of: #"^(?:\*\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil,
                  url.user == nil, url.password == nil, url.port == nil,
                  url.query == nil, url.fragment == nil,
                  url.path.hasPrefix("/") else { return nil }
            let hostPattern = host.hasPrefix("*.")
                ? #"(?:[a-z0-9-]+\.)*"# + NSRegularExpression.escapedPattern(for: String(host.dropFirst(2)))
                : NSRegularExpression.escapedPattern(for: host)
            let pathPattern = url.path.components(separatedBy: "*")
                .map(NSRegularExpression.escapedPattern(for:)).joined(separator: ".*")
            patterns.append("^" + scheme + "://" + hostPattern + "(?::[0-9]+)?" + pathPattern + "(?:\\?.*)?$" )
        }
        return patterns
    }

    static func guardedSource(_ source: String, bundled: Bool, matchSource: String? = nil) -> String? {
        if bundled { return source }
        guard let patterns = validatedMatchPatterns(in: matchSource ?? source),
              let data = try? JSONSerialization.data(withJSONObject: patterns),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "(() => { if (!(" + json + ").some(p => new RegExp(p, 'i').test(location.href))) return;\n" + source + "\n})();"
    }
    /// Моды, которые остаются модами: они заметно нагружают систему
    /// (скрипт в каждой странице или вторая живая страница рядом).
    static let bundledBaseNames = [
        "aircraft-devtools-webextensions",
        "aircraft-split-view",
        "aircraft-sources"
    ]

    /// Бывшие моды, которые стали частью браузера: «Цветные темы» → Внешний вид,
    /// «История и аккаунты» → меню вкладок. Их файлы больше не подключаются.
    static let retiredBaseNames = [
        "aircraft-color-themes",
        "aircraft-tab-history-accounts"
    ]

    /// Возможность, которую даёт установленный встроенный мод.
    static let capabilities: [String: String] = [
        "aircraft-devtools-webextensions": "devtools",
        "aircraft-split-view": "splitView",
        "aircraft-sources": "sources"
    ]

    static func family(for fileName: String) -> String? {
        family(for: fileName, in: bundledBaseNames)
    }

    static func retiredFamily(for fileName: String) -> String? {
        family(for: fileName, in: retiredBaseNames)
    }

    private static func family(for fileName: String, in names: [String]) -> String? {
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        return names.first { base in
            stem == base || stem.range(of: "^\(NSRegularExpression.escapedPattern(for: base)) [0-9]+$", options: .regularExpression) != nil
        }
    }

    static func isInstalled(_ baseName: String, in files: [String]) -> Bool {
        files.contains { family(for: $0) == baseName }
    }

    /// Возможности установленных встроенных модов — известны сразу, без загрузки страницы.
    static func installedCapabilities(in files: [String]) -> Set<String> {
        Set(files.compactMap { family(for: $0).flatMap { capabilities[$0] } })
    }
}

extension ModCatalog {
    /// Файлы бывших модов убираем в корзину: их работа теперь встроена.
    static func retireOldFiles() {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let folder = support.appendingPathComponent("aircraft/mods", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where retiredFamily(for: file.lastPathComponent) != nil {
            try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
    }
}
