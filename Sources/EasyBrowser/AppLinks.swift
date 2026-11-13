import SwiftUI
import AppKit
import WebKit

/// «Открыть в приложении», как в Safari и Chrome.
///
/// Два случая:
/// - страница сама пытается открыть приложение (`zoommtg://`, `tg://`, `slack://`…) —
///   WebKit такие адреса не открывает, поэтому раньше ничего не происходило; теперь
///   появляется вопрос «Открыть в приложении Zoom?» (можно разрешить сайту навсегда);
/// - обычная ссылка, у которой есть приложение (zoom.us/j/…, t.me/…, open.spotify.com/…),
///   и это приложение установлено, — над страницей появляется кнопка «Открыть в приложении».
struct AppLinkOffer: Identifiable, Equatable {
    enum Origin: Equatable {
        /// Страница попросила открыть приложение.
        case requested
        /// Браузер сам заметил, что у ссылки есть приложение.
        case suggested
    }

    let id = UUID()
    let tabID: UUID
    /// Адрес, который отдаётся приложению.
    let target: URL
    let appName: String
    let appURL: URL
    /// Сайт, с которого пришла ссылка (для «Всегда открывать»).
    let host: String
    let origin: Origin

    var icon: NSImage { NSWorkspace.shared.icon(forFile: appURL.path) }

    static func == (lhs: AppLinkOffer, rhs: AppLinkOffer) -> Bool { lhs.id == rhs.id }
}

enum AppLinks {
    static let enabledKey = "appLinksEnabled"
    static let alwaysKey = "appLinksAlwaysOpen"

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// Схемы, которые браузер открывает сам.
    static let webSchemes: Set<String> = ["http", "https", "file", "about", "data", "blob", "javascript", "applewebdata", "webkit-pdfjs-viewer"]
    /// Схемы, которые по клику открываются сразу, без вопроса (как в Safari).
    static let directSchemes: Set<String> = ["mailto", "tel", "facetime", "facetime-audio", "sms", "maps"]

    static func isExternal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return !webSchemes.contains(scheme)
    }

    /// Установленное приложение для адреса — не браузер и не сам Aircraft.
    static func application(for url: URL) -> (url: URL, name: String)? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        if app.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL { return nil }
        if let id = Bundle(url: app)?.bundleIdentifier, id.hasPrefix("com.taras.aircraft") { return nil }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        return (app, name)
    }

    // MARK: Ссылки сайтов → приложения

    /// Адрес в приложении для известной веб-ссылки. Приложение может быть не установлено —
    /// это проверяется отдельно.
    static func appTarget(forWeb url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let parts = url.path.split(separator: "/").map(String.init)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        func make(_ string: String) -> URL? { URL(string: string) }

        // Zoom: zoom.us/j/123, company.zoom.us/j/123?pwd=…, /wc/123/join, /my/name
        if host == "zoom.us" || host.hasSuffix(".zoom.us") || host == "zoom.com" || host.hasSuffix(".zoom.com") {
            var components = URLComponents()
            components.scheme = "zoommtg"
            components.host = host
            components.path = "/join"
            var items = [URLQueryItem(name: "action", value: "join")]
            if parts.count >= 2, ["j", "s", "w"].contains(parts[0]) {
                items.append(URLQueryItem(name: "confno", value: parts[1]))
            } else if parts.count >= 2, parts[0] == "wc" {
                items.append(URLQueryItem(name: "confno", value: parts[1]))
            } else if parts.count >= 2, parts[0] == "my" {
                items.append(URLQueryItem(name: "vanity", value: parts[1]))
            } else {
                return nil
            }
            if let pwd = value("pwd") { items.append(URLQueryItem(name: "pwd", value: pwd)) }
            components.queryItems = items
            return components.url
        }
        // Telegram: t.me/name, t.me/name/123, t.me/+invite, t.me/joinchat/invite
        if host == "t.me" || host == "telegram.me" {
            guard let first = parts.first else { return nil }
            if first.hasPrefix("+") { return make("tg://join?invite=\(first.dropFirst())") }
            if first == "joinchat", parts.count >= 2 { return make("tg://join?invite=\(parts[1])") }
            if first == "s" { return nil }
            guard first.range(of: "^[A-Za-z0-9_]{3,}$", options: .regularExpression) != nil else { return nil }
            if parts.count >= 2, Int(parts[1]) != nil { return make("tg://resolve?domain=\(first)&post=\(parts[1])") }
            return make("tg://resolve?domain=\(first)")
        }
        // Spotify: open.spotify.com/track/ID
        if host == "open.spotify.com" {
            let kinds = ["track", "album", "playlist", "artist", "show", "episode", "user"]
            let clean = parts.first?.hasPrefix("intl-") == true ? Array(parts.dropFirst()) : parts
            guard clean.count >= 2, kinds.contains(clean[0]) else { return nil }
            return make("spotify:\(clean[0]):\(clean[1])")
        }
        // Discord: discord.com/channels/…, discord.gg/code, discord.com/invite/code
        if host == "discord.gg", let code = parts.first { return make("discord://-/invite/\(code)") }
        if host == "discord.com" || host == "discordapp.com" {
            if parts.first == "channels" { return make("discord://-" + url.path) }
            if parts.first == "invite", parts.count >= 2 { return make("discord://-/invite/\(parts[1])") }
            return nil
        }
        // Microsoft Teams: teams.microsoft.com/l/meetup-join/…
        if host == "teams.microsoft.com" || host == "teams.live.com", parts.first == "l" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.scheme = "msteams"
            components?.host = nil
            return components?.url
        }
        // Slack: app.slack.com/client/TEAM/CHANNEL
        if host == "app.slack.com", parts.count >= 3, parts[0] == "client" {
            return make("slack://channel?team=\(parts[1])&id=\(parts[2])")
        }
        // Notion
        if host == "notion.so" || host.hasSuffix(".notion.site") || host == "notion.com" {
            guard !parts.isEmpty, !["login", "signup", "product", "pricing"].contains(parts[0]) else { return nil }
            return make("notion://www.notion.so" + url.path)
        }
        // Figma: figma.com/design/KEY/…, /file/KEY/…, /board/KEY
        if host == "figma.com", parts.count >= 2, ["file", "design", "board", "proto", "slides"].contains(parts[0]) {
            return make("figma://file/\(parts[1])")
        }
        // Linear
        if host == "linear.app", parts.count >= 2 {
            return make("linear://" + parts.joined(separator: "/"))
        }
        // Apple Music
        if host == "music.apple.com", !parts.isEmpty {
            return make("music://music.apple.com" + url.path)
        }
        return nil
    }

    // MARK: «Всегда открывать» для сайта

    static func isAlwaysAllowed(host: String, scheme: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: alwaysKey) ?? []).contains("\(host)|\(scheme)")
    }

    static func allowAlways(host: String, scheme: String) {
        var list = UserDefaults.standard.stringArray(forKey: alwaysKey) ?? []
        let key = "\(host)|\(scheme)"
        if !list.contains(key) { list.append(key) }
        UserDefaults.standard.set(list, forKey: alwaysKey)
    }
}

extension TabManager {
    /// Страница или клик ведут на адрес приложения. Возвращает true, если адрес обработан
    /// (навигацию в WebView надо отменить).
    func handleExternalNavigation(_ url: URL, from webView: WKWebView, userClicked: Bool) -> Bool {
        guard AppLinks.isExternal(url), let scheme = url.scheme?.lowercased() else { return false }
        guard let tab = tabs.first(where: { $0.webView === webView }) else { return true }
        let host = FaviconCache.key(for: webView.url) ?? ""
        guard let app = AppLinks.application(for: url) else {
            if userClicked { showToast("Нет приложения для ссылок «\(scheme):»", symbol: "questionmark.app") }
            return true
        }
        if (userClicked && AppLinks.directSchemes.contains(scheme)) || AppLinks.isAlwaysAllowed(host: host, scheme: scheme) {
            NSWorkspace.shared.open(url)
            return true
        }
        appLinkOffers[tab.id] = AppLinkOffer(tabID: tab.id, target: url, appName: app.name, appURL: app.url,
                                             host: host, origin: .requested)
        return true
    }

    /// Страница сменилась: предлагаем приложение для известных ссылок, убираем старое предложение.
    func refreshAppLinkOffer(tabID: UUID, url: URL?) {
        if let offer = appLinkOffers[tabID] {
            // Вопрос от страницы остаётся, пока пользователь на том же сайте.
            if offer.origin == .requested, FaviconCache.key(for: url) == offer.host { return }
            appLinkOffers[tabID] = nil
        }
        guard AppLinks.isEnabled, let url, let target = AppLinks.appTarget(forWeb: url),
              let key = FaviconCache.key(for: url), !dismissedAppLinkHosts.contains(key),
              let app = AppLinks.application(for: target) else { return }
        appLinkOffers[tabID] = AppLinkOffer(tabID: tabID, target: target, appName: app.name, appURL: app.url,
                                            host: key, origin: .suggested)
    }

    func openAppLink(_ offer: AppLinkOffer, always: Bool = false) {
        if always, let scheme = offer.target.scheme?.lowercased() {
            AppLinks.allowAlways(host: offer.host, scheme: scheme)
        }
        NSWorkspace.shared.open(offer.target)
        appLinkOffers[offer.tabID] = nil
    }

    func dismissAppLink(_ offer: AppLinkOffer) {
        if offer.origin == .suggested { dismissedAppLinkHosts.insert(offer.host) }
        appLinkOffers[offer.tabID] = nil
    }
}

/// Плашка над страницей: «Открыть в приложении Zoom».
struct AppLinkBanner: View {
    let offer: AppLinkOffer
    @Environment(TabManager.self) private var tabManager: TabManager

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: offer.icon)
                .resizable()
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(offer.origin == .requested ? "Открыть в приложении «\(offer.appName)»?" : "Открыть в приложении «\(offer.appName)»")
                    .fontWeight(.semibold)
                Text(offer.origin == .requested
                     ? "\(offer.host.isEmpty ? "Страница" : offer.host) хочет открыть приложение"
                     : "Ссылку можно открыть в установленном приложении")
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if offer.origin == .requested {
                Button("Не открывать") { tabManager.dismissAppLink(offer) }
                if !offer.host.isEmpty {
                    Button("Всегда для сайта") { tabManager.openAppLink(offer, always: true) }
                        .help("Больше не спрашивать на \(offer.host)")
                }
                Button("Открыть") { tabManager.openAppLink(offer) }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Открыть") { tabManager.openAppLink(offer) }
                    .buttonStyle(.borderedProminent)
                Button { tabManager.dismissAppLink(offer) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Не предлагать для \(offer.host) до перезапуска")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassOr(RoundedRectangle(cornerRadius: 12), interactive: true) { Rectangle().fill(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12)) }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .frame(maxWidth: 620)
        .padding(.top, 10)
        .padding(.horizontal, 16)
    }
}

/// Значок приложения в карточке адреса: открыть страницу в приложении.
struct AppLinkAddressButton: View {
    let fontSize: CGFloat
    @Environment(TabManager.self) private var tabManager: TabManager

    var body: some View {
        if let id = tabManager.activeTabID, let offer = tabManager.appLinkOffers[id] {
            Button { tabManager.openAppLink(offer) } label: {
                Image(nsImage: offer.icon)
                    .resizable()
                    .frame(width: fontSize * 1.5, height: fontSize * 1.5)
            }
            .buttonStyle(.plain)
            .help("Открыть в приложении «\(offer.appName)»")
        }
    }
}

/// Настройка в разделе «Основные».
struct AppLinksSettingsSection: View {
    @AppStorage(AppLinks.enabledKey) private var enabled = true
    @State private var remembered: [String] = []

    var body: some View {
        Section {
            Toggle("Предлагать открыть ссылку в приложении", isOn: $enabled)
            if !remembered.isEmpty {
                LabeledContent("Открываются без вопроса") {
                    Text(remembered.map { $0.replacingOccurrences(of: "|", with: " → ") + ":" }.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Button("Снова спрашивать для всех сайтов") {
                    UserDefaults.standard.removeObject(forKey: AppLinks.alwaysKey)
                    remembered = []
                }
            }
        } header: {
            Text("Приложения")
        } footer: {
            Text("Ссылки на созвоны Zoom и Teams, Telegram, Spotify, Discord, Slack, Notion, Figma, Linear и Apple Music можно открыть в установленном приложении. Если страница сама открывает приложение, Aircraft спросит разрешения, как Safari.")
                .foregroundStyle(.secondary)
        }
        .onAppear { remembered = UserDefaults.standard.stringArray(forKey: AppLinks.alwaysKey) ?? [] }
    }
}
