import Foundation
import WebKit

/// Кем Aircraft представляется сайтам (User-Agent).
///
/// WKWebView без настройки отправляет `…AppleWebKit/605.1.15 (KHTML, like Gecko)` без
/// `Version/… Safari/…`: так выглядит встроенное окно приложения, а не браузер. Google
/// из-за этого отдаёт упрощённую выдачу и отказывает во входе («браузер небезопасен»),
/// а часть систем единого входа (SSO вузов, Microsoft) ломает вход. Поэтому всегда
/// добавляем хвост Safari, а по желанию — представляемся Chrome.
enum SiteIdentity: String, CaseIterable, Identifiable {
    case safari, chromeForGoogle, chrome

    static let storageKey = "siteIdentity"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .safari: "Safari (рекомендуется)"
        case .chromeForGoogle: "Chrome — только для Google"
        case .chrome: "Chrome — для всех сайтов"
        }
    }

    static var current: SiteIdentity {
        UserDefaults.standard.string(forKey: storageKey).flatMap(SiteIdentity.init(rawValue:)) ?? .safari
    }

    /// Хвост User-Agent как у установленного Safari: `Version/26.1 Safari/605.1.15`.
    /// Без него (или со старой версией) Google пишет, что браузер устарел.
    static let safariApplicationName: String = "Version/\(safariVersion) Safari/605.1.15"

    /// Версия Safari из системы; если её не прочитать — по версии macOS
    /// (macOS 26 → Safari 26, macOS 15 → 18, macOS 14 → 17).
    static let safariVersion: String = {
        let candidates = ["/Applications/Safari.app/Contents/Info.plist",
                          "/System/Cryptexes/App/System/Applications/Safari.app/Contents/Info.plist",
                          "/System/Applications/Safari.app/Contents/Info.plist"]
        for path in candidates {
            if let version = NSDictionary(contentsOf: URL(fileURLWithPath: path))?["CFBundleShortVersionString"] as? String {
                let parts = version.split(separator: ".").prefix(2)
                if let major = parts.first.flatMap({ Int($0) }), major >= 17 { return parts.joined(separator: ".") }
            }
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let major = os.majorVersion >= 26 ? os.majorVersion : os.majorVersion + 3
        return "\(major).\(os.minorVersion)"
    }()

    /// iPhone для узкого окна — той же версии, что и Safari на Mac.
    static var mobileUserAgent: String {
        let ios = safariVersion.replacingOccurrences(of: ".", with: "_")
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(ios) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) Mobile/15E148 Safari/604.1"
    }

    /// Chrome выходит раз в четыре недели; считаем текущую версию от известной точки,
    /// чтобы сайты не просили «обновить браузер».
    static func chromeMajorVersion(now: Date = Date()) -> Int {
        let reference = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2024, month: 11, day: 12).date!
        let weeks = max(0, now.timeIntervalSince(reference)) / (7 * 24 * 3600)
        return 131 + Int(weeks / 4)
    }

    static var chromeUserAgent: String {
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(chromeMajorVersion()).0.0.0 Safari/537.36"
    }

    /// google.com, google.ru, accounts.google.com, www.google.co.uk…
    static func isGoogle(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let parts = host.split(separator: ".")
        guard let index = parts.firstIndex(of: "google") else { return false }
        let tail = parts.count - index - 1
        return tail == 1 || (tail == 2 && parts[parts.count - 2].count <= 3)
    }

    /// `customUserAgent` для адреса; nil — стандартный (WebKit + хвост Safari).
    static func customUserAgent(for url: URL?) -> String? {
        switch current {
        case .safari: return nil
        case .chrome: return chromeUserAgent
        case .chromeForGoogle: return isGoogle(url?.host) ? chromeUserAgent : nil
        }
    }
}

/// Удобства для локальной разработки: localhost, 127.0.0.1, *.localhost, *.local
/// и адреса домашней сети.
enum LocalDevelopment {
    static let storageKey = "localDevTools"

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: storageKey) as? Bool ?? true }

    static func isLocal(_ url: URL?) -> Bool {
        guard let url, url.scheme == "http" || url.scheme == "https" else { return false }
        return isLocalHost(url.host)
    }

    static func isLocalHost(_ rawHost: String?) -> Bool {
        guard var host = rawHost?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if ["localhost", "127.0.0.1", "0.0.0.0", "::1"].contains(host) { return true }
        if host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".test") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, host.split(separator: ".").count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }

    /// Локальная вкладка с включёнными инструментами: не усыплять и не архивировать.
    static func keepsAlive(_ url: URL?) -> Bool { isEnabled && isLocal(url) }

    /// Порт локального сервера для значка в карточке адреса: «:3000».
    static func portLabel(_ url: URL?) -> String? {
        guard isLocal(url), let url else { return nil }
        if let port = url.port { return ":\(port)" }
        return url.scheme == "https" ? ":443" : ":80"
    }
}
