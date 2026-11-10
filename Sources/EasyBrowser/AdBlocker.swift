import Foundation
import WebKit

/// Встроенный блокировщик рекламы.
///
/// Работает на нативных правилах WebKit (`WKContentRuleList`): запросы к рекламным
/// сетям не отправляются вовсе, а рекламные блоки на странице скрываются через CSS.
/// Это быстрее и экономнее, чем JS-мод, и не даёт страницам доступа к правилам.
@MainActor
final class AdBlocker {
    static let shared = AdBlocker()

    static let enabledKey = "adBlockEnabled"
    static let trackerEnabledKey = "trackerBlockEnabled"
    static let allowlistKey = "adBlockAllowlist"
    private static let ruleListIdentifier = "aircraft-adblock"

    /// Скомпилированные правила; nil, пока блокировщик выключен или правила компилируются.
    private(set) var ruleList: WKContentRuleList?
    private var compileGeneration = 0

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var blocksTrackers: Bool { UserDefaults.standard.bool(forKey: Self.trackerEnabledKey) }
    /// Работает ли хоть одна из защит.
    var isActive: Bool { isEnabled || blocksTrackers }

    /// Сайты, на которых реклама разрешена (без «www.»).
    var allowlist: [String] { UserDefaults.standard.stringArray(forKey: Self.allowlistKey) ?? [] }

    private init() {
        rebuild(reloadPages: false)
    }

    /// Подключает правила к вкладке (новые загрузки страниц будут фильтроваться).
    func attach(to controller: WKUserContentController) {
        guard isActive, let ruleList else { return }
        controller.add(ruleList)
    }

    func isAllowed(host: String?) -> Bool {
        guard let host = Self.normalizedHost(host) else { return false }
        return allowlist.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func setAllowed(_ allowed: Bool, host: String?) {
        guard let host = Self.normalizedHost(host) else { return }
        var list = allowlist.filter { $0 != host }
        if allowed { list.append(host) }
        UserDefaults.standard.set(list.sorted(), forKey: Self.allowlistKey)
        rebuild(reloadPages: true)
    }

    /// Пересобирает правила после включения/выключения или изменения исключений.
    func rebuild(reloadPages: Bool) {
        compileGeneration += 1
        let generation = compileGeneration
        guard isActive else {
            ruleList = nil
            notify(reloadPages: reloadPages)
            return
        }
        let json = Self.rulesJSON(ads: isEnabled, trackers: blocksTrackers, allowlist: allowlist)
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: Self.ruleListIdentifier,
            encodedContentRuleList: json
        ) { [weak self] list, error in
            MainActor.assumeIsolated {
                guard let self, generation == self.compileGeneration else { return }
                if let error { print("Aircraft AdBlocker: не удалось собрать правила: \(error)") }
                self.ruleList = list
                self.notify(reloadPages: reloadPages)
            }
        }
    }

    private func notify(reloadPages: Bool) {
        NotificationCenter.default.post(name: .adBlockRulesDidChange, object: nil, userInfo: ["reload": reloadPages])
    }

    static func normalizedHost(_ host: String?) -> String? {
        guard var host = host?.lowercased().trimmingCharacters(in: .whitespaces), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    // MARK: - Правила

    /// Рекламные сети и рекламные трекеры. Блокируются только как сторонние ресурсы,
    /// поэтому сами сайты этих компаний открываются как обычно.
    static let blockedDomains: [String] = [
        // Google
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com",
        "googletagservices.com", "imasdk.googleapis.com",
        // Крупные рекламные биржи и сети
        "amazon-adsystem.com", "adnxs.com", "criteo.com", "criteo.net", "pubmatic.com",
        "rubiconproject.com", "openx.net", "casalemedia.com", "adsrvr.org", "bidswitch.net",
        "contextweb.com", "smartadserver.com", "adform.net", "adroll.com", "yieldmo.com",
        "sharethrough.com", "33across.com", "teads.tv", "media.net", "advertising.com",
        "moatads.com", "scorecardresearch.com", "quantserve.com", "zedo.com", "serving-sys.com",
        "lijit.com", "sovrn.com", "indexww.com", "3lift.com", "gumgum.com", "districtm.io",
        // Нативная реклама и «рекомендации»
        "taboola.com", "outbrain.com", "mgid.com", "revcontent.com", "zergnet.com", "marketgid.com",
        // Поп-апы и агрессивные сети
        "popads.net", "propellerads.com", "exoclick.com", "popcash.net", "adsterra.com",
        "hilltopads.net", "juicyads.com", "trafficjunky.net",
        // Рунет
        "an.yandex.ru", "yabs.yandex.ru", "yandexadexchange.net", "adfox.ru", "adfox.yandex.ru",
        "adriver.ru", "ad.mail.ru", "betweendigital.com", "buzzoola.com", "otm-r.com",
        "directadvert.ru", "relap.io", "smi2.ru", "smi2.net", "24smi.org", "lentainform.com"
    ]

    /// Счётчики, пиксели и сервисы записи сессий, которые следят за посетителем
    /// между сайтами. Блокируются как сторонние ресурсы.
    static let trackerDomains: [String] = [
        // Аналитика и пиксели крупных платформ
        "google-analytics.com", "analytics.google.com", "connect.facebook.net", "pixel.facebook.com",
        "bat.bing.com", "clarity.ms", "analytics.tiktok.com", "ads.tiktok.com", "px.ads.linkedin.com",
        "snap.licdn.com", "static.ads-twitter.com", "analytics.twitter.com", "ct.pinterest.com",
        "sc-static.net", "tr.snapchat.com", "pixel.wp.com", "stats.wp.com",
        // Запись сессий и поведенческая аналитика
        "hotjar.com", "hotjar.io", "mouseflow.com", "fullstory.com", "smartlook.com", "luckyorange.com",
        "crazyegg.com", "inspectlet.com", "logrocket.io", "contentsquare.net",
        // Сбор данных и межсайтовые идентификаторы
        "chartbeat.com", "chartbeat.net", "parsely.com", "comscore.com", "krxd.net", "bluekai.com",
        "demdex.net", "omtrdc.net", "everesttech.net", "rlcdn.com", "liadm.com", "agkn.com",
        "exelator.com", "eyeota.net", "tapad.com", "id5-sync.com", "crwdcntrl.net", "addthis.com",
        // Рунет
        "mc.yandex.ru", "mc.yandex.com", "top-fwz1.mail.ru", "counter.yadro.ru", "top100.rambler.ru",
        "counter.rambler.ru", "tns-counter.ru", "mediametrics.ru", "vk.com/rtrg", "mc.webvisor.org"
    ]

    /// Метки отслеживания в адресах ссылок — убираются при переходе.
    nonisolated static let trackingParameters: Set<String> = [
        "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid", "ysclid",
        "mc_cid", "mc_eid", "igshid", "twclid", "ttclid", "li_fat_id", "_openstat", "_hsenc", "_hsmi",
        "oly_anon_id", "oly_enc_id", "vero_id", "mkt_tok"
    ]

    /// Ссылка без меток отслеживания или nil, если чистить нечего.
    nonisolated static func cleanedURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else { return nil }
        let kept = items.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && !trackingParameters.contains(name)
        }
        guard kept.count != items.count else { return nil }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.url
    }

    /// Типичные контейнеры рекламы — прячем, даже если сам блок загрузился с сайта.
    static let hiddenSelectors: [String] = [
        "ins.adsbygoogle", ".adsbygoogle", "[id^=\"google_ads_iframe\"]", "[id^=\"div-gpt-ad\"]",
        "div[data-ad-slot]", "div[data-google-query-id]", "iframe[src*=\"doubleclick.net\"]",
        "iframe[src*=\"googlesyndication.com\"]", "[id^=\"taboola-\"]", ".trc_related_container",
        ".OUTBRAIN", "[data-widget-id^=\"outbrain\"]", "[id^=\"yandex_rtb\"]", "[id^=\"adfox_\"]",
        "[id^=\"mgid_\"]", ".mgbox", "amp-ad", "amp-embed[type=\"taboola\"]"
    ]

    static func rulesJSON(ads: Bool = true, trackers: Bool = false, allowlist: [String]) -> String {
        var rules: [[String: Any]] = []
        let domains = (ads ? blockedDomains : []) + (trackers ? trackerDomains : [])
        for domain in domains {
            // «vk.com/rtrg» — домен с путём: блокируем только этот путь.
            let parts = domain.split(separator: "/", maxSplits: 1).map(String.init)
            let escapedHost = parts[0].replacingOccurrences(of: ".", with: "\\.")
            let filter = parts.count > 1
                ? "^[^:]+://+([^:/]+\\.)?\(escapedHost)/\(parts[1])"
                : "^[^:]+://+([^:/]+\\.)?\(escapedHost)[:/]"
            rules.append([
                "trigger": ["url-filter": filter, "load-type": ["third-party"]],
                "action": ["type": "block"]
            ])
        }
        // Селекторы группами, чтобы правил было меньше.
        for start in stride(from: 0, to: ads ? hiddenSelectors.count : 0, by: 6) {
            let group = hiddenSelectors[start..<min(start + 6, hiddenSelectors.count)]
            rules.append([
                "trigger": ["url-filter": ".*"],
                "action": ["type": "css-display-none", "selector": group.joined(separator: ", ")]
            ])
        }
        // Исключения: на разрешённых сайтах все предыдущие правила отменяются.
        let allowedDomains = allowlist.compactMap { normalizedHost($0) }.map { "*\($0)" }
        if !allowedDomains.isEmpty {
            rules.append([
                "trigger": ["url-filter": ".*", "if-domain": allowedDomains],
                "action": ["type": "ignore-previous-rules"]
            ])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}

extension Notification.Name {
    static let adBlockRulesDidChange = Notification.Name("AdBlockRulesDidChange")
}
