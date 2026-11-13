import Foundation

enum ModCatalog {
    /// Моды, которые остаются модами: они заметно нагружают систему
    /// (скрипт в каждой странице или вторая живая страница рядом).
    static let bundledBaseNames = [
        "aircraft-devtools-webextensions",
        "aircraft-split-view"
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
        "aircraft-split-view": "splitView"
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
