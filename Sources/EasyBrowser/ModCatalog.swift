import Foundation

enum ModCatalog {
    static let bundledBaseNames = [
        "aircraft-devtools-webextensions",
        "aircraft-color-themes",
        "aircraft-tab-history-accounts",
        "aircraft-split-view"
    ]

    static func family(for fileName: String) -> String? {
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        return bundledBaseNames.first { base in
            stem == base || stem.range(of: "^\(NSRegularExpression.escapedPattern(for: base)) [0-9]+$", options: .regularExpression) != nil
        }
    }

    static func isInstalled(_ baseName: String, in files: [String]) -> Bool {
        files.contains { family(for: $0) == baseName }
    }
}
