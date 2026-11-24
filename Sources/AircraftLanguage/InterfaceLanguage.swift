import Foundation

public enum InterfaceLanguage {
    public static let preferenceKey = "interfaceLanguage"
    public static let code: String = {
        let defaults = UserDefaults.standard
        let choice = Bundle.main.object(forInfoDictionaryKey: "AircraftWebAppURL") == nil
            ? defaults.string(forKey: preferenceKey)
            : defaults.persistentDomain(forName: "com.taras.aircraft")?[preferenceKey] as? String
        if let choice, ["en", "ru"].contains(choice) { return choice }
        return Bundle.preferredLocalizations(from: ["en", "ru"]).first ?? "en"
    }()

    public static func save(_ choice: String) {
        // AppKit also reads its standard language preference at the next launch.
        if choice == "system" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([choice], forKey: "AppleLanguages") }
    }

    public static let resources: Bundle = {
        if let url = Bundle.main.url(forResource: "Aircraft_AircraftLanguage", withExtension: "bundle"),
           let packaged = Bundle(url: url) { return packaged }
        return Bundle.module
    }()

    static let translations: Bundle = {
        guard let path = resources.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return resources }
        return bundle
    }()
}

public func L10n(_ key: String, _ arguments: String...) -> String {
    let template = InterfaceLanguage.translations.localizedString(forKey: key, value: key, table: nil)
    guard !arguments.isEmpty else { return template }
    return String(format: template, locale: Locale(identifier: InterfaceLanguage.code), arguments: arguments)
}
