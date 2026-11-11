import CryptoKit
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
    static let yandexEnabledKey = "yandexAdBlockEnabled"
    static let googleEnabledKey = "googleAdBlockEnabled"
    static let allowlistKey = "adBlockAllowlist"
    private static let ruleListIdentifier = "aircraft-adblock"
    private static let siteRuleListIdentifier = "aircraft-adblock-sites"
    private static let filterListPrefix = "aircraft-lists-"
    private static let probeIdentifier = "aircraft-probe"
    private static let compiledKeyKey = "adBlockCompiledListsKey"
    private static let compiledCountKey = "adBlockCompiledListsCount"
    private static let compiledRulesKey = "adBlockCompiledRuleCount"

    /// Скомпилированные списки правил: встроенные, Яндекс/Google и подписки (по частям).
    /// Списки собираются отдельно, чтобы ошибка в одном не отключала другие.
    private(set) var ruleLists: [WKContentRuleList] = []
    private var compileGeneration = 0
    private var buildTask: Task<Void, Never>?

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var blocksTrackers: Bool { UserDefaults.standard.bool(forKey: Self.trackerEnabledKey) }
    /// Реклама Яндекса: Поиск, Карты, Маркет, Музыка, РСЯ и Adfox на любых сайтах.
    var blocksYandexAds: Bool { UserDefaults.standard.bool(forKey: Self.yandexEnabledKey) }
    /// Реклама Google: поиск, AdSense/Ad Manager на сайтах и YouTube.
    var blocksGoogleAds: Bool { UserDefaults.standard.bool(forKey: Self.googleEnabledKey) }
    /// Есть ли свои правила (они работают и при выключенном основном блокировщике).
    var hasCustomRules: Bool { !FilterListStore.shared.customRules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// Работает ли хоть одна из защит.
    var isActive: Bool { isEnabled || blocksTrackers || blocksYandexAds || blocksGoogleAds || hasCustomRules }

    /// Сайты, на которых реклама разрешена (без «www.»).
    var allowlist: [String] { UserDefaults.standard.stringArray(forKey: Self.allowlistKey) ?? [] }

    private init() {
        rebuild(reloadPages: false)
        // Списки фильтров обновляются в фоне, когда подходит срок.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            FilterListStore.shared.refreshIfNeeded()
        }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in FilterListStore.shared.refreshIfNeeded() }
        }
    }

    /// Подключает правила к вкладке (новые загрузки страниц будут фильтроваться).
    func attach(to controller: WKUserContentController) {
        if isActive { ruleLists.forEach(controller.add) }
        installPageScript(into: controller)
    }

    /// Скрипт против рекламы YouTube и анти-адблока Яндекса (см. `SiteAdRules.pageScript`).
    /// Заменяет прежнюю версию скрипта и не трогает остальные скрипты вкладки (моды).
    func installPageScript(into controller: WKUserContentController) {
        let wanted = (blocksYandexAds || blocksGoogleAds)
            ? SiteAdRules.pageScript(yandex: blocksYandexAds, google: blocksGoogleAds, allowlist: allowlist)
            : nil
        let scripts = controller.userScripts
        let ours = scripts.filter { $0.source.hasPrefix(SiteAdRules.scriptMarker) }
        if ours.count == (wanted == nil ? 0 : 1), ours.first?.source == wanted { return }
        if !ours.isEmpty {
            controller.removeAllUserScripts()
            scripts.filter { !$0.source.hasPrefix(SiteAdRules.scriptMarker) }.forEach(controller.addUserScript)
        }
        guard let wanted else { return }
        // Мир страницы и все фреймы: так скрипт видит JSON.parse плеера и встроенные ролики YouTube.
        controller.addUserScript(WKUserScript(
            source: wanted, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
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

    // MARK: - Сборка

    /// Пересобирает правила после включения/выключения, обновления списков или изменения исключений.
    func rebuild(reloadPages: Bool) {
        compileGeneration += 1
        let generation = compileGeneration
        buildTask?.cancel()
        buildTask = Task { [weak self] in await self?.build(generation: generation, reloadPages: reloadPages) }
    }

    private func build(generation: Int, reloadPages: Bool) async {
        let store = FilterListStore.shared
        // Свои исключения (@@…) действуют и на встроенные правила.
        let customExceptions = FilterConverter.convert(store.customRules).exceptions

        // 1. Встроенные правила — маленькие, собираются за доли секунды.
        var builtin: [WKContentRuleList] = []
        var builtinRuleCount = 0
        if isEnabled || blocksTrackers {
            let json = Self.rulesJSON(ads: isEnabled, trackers: blocksTrackers, allowlist: allowlist, extraExceptions: customExceptions)
            if let list = await compile(identifier: Self.ruleListIdentifier, json: json) { builtin.append(list) }
            builtinRuleCount += Self.blockedDomains.count + Self.trackerDomains.count
        }
        if blocksYandexAds || blocksGoogleAds {
            let json = Self.siteRulesJSON(yandex: blocksYandexAds, google: blocksGoogleAds, allowlist: allowlist, extraExceptions: customExceptions)
            if let list = await compile(identifier: Self.siteRuleListIdentifier, json: json) { builtin.append(list) }
            builtinRuleCount += SiteAdRules.rules(yandex: blocksYandexAds, google: blocksGoogleAds).count
        }
        guard generation == compileGeneration else { return }

        guard isEnabled || hasCustomRules else {
            ruleLists = builtin
            store.activeRuleCount = builtinRuleCount
            store.buildStatus = nil
            notify(reloadPages: reloadPages)
            return
        }
        // Пока собираются подписки, работают хотя бы встроенные правила.
        ruleLists = builtin + ruleLists.filter { $0.identifier.hasPrefix(Self.filterListPrefix) }
        notify(reloadPages: false)

        // 2. Подписки и свои правила.
        let lists = await buildFilterLists(generation: generation)
        guard generation == compileGeneration else { return }
        ruleLists = builtin + lists.lists
        store.activeRuleCount = builtinRuleCount + lists.ruleCount
        store.buildStatus = nil
        notify(reloadPages: reloadPages)
    }

    /// Входные данные сборки подписок; по их хэшу находим уже скомпилированные правила.
    private struct ListInputs: Sendable {
        var files: [(id: String, url: URL)]
        var customRules: String
        var allowlist: [String]

        var key: String {
            var parts = ["v\(FilterConverter.version)"]
            for file in files {
                let attributes = try? FileManager.default.attributesOfItem(atPath: file.url.path)
                let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                parts.append("\(file.id):\(size):\(Int(modified))")
            }
            parts.append(customRules)
            parts.append(allowlist.joined(separator: ","))
            let digest = SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
            return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
        }
    }

    private struct ListPlan: Sendable {
        var chunks: [[String]] = []
        var stats: [String: (Int, Int)] = [:]
        var custom: (Int, Int) = (0, 0)
    }

    private func buildFilterLists(generation: Int) async -> (lists: [WKContentRuleList], ruleCount: Int) {
        let store = FilterListStore.shared
        let inputs = ListInputs(files: isEnabled ? store.activeListFiles : [], customRules: store.customRules, allowlist: allowlist)
        guard !inputs.files.isEmpty || !inputs.customRules.isEmpty else {
            await removeStaleLists(keeping: [])
            return ([], 0)
        }
        let key = inputs.key
        let defaults = UserDefaults.standard

        // Правила не менялись — берём скомпилированные с прошлого раза (мгновенно).
        if defaults.string(forKey: Self.compiledKeyKey) == key {
            let count = defaults.integer(forKey: Self.compiledCountKey)
            var found: [WKContentRuleList] = []
            for index in 0..<count {
                if let list = await lookUp(Self.filterListPrefix + "\(key)-\(index)") { found.append(list) }
            }
            if count > 0 && found.count == count { return (found, defaults.integer(forKey: Self.compiledRulesKey)) }
        }

        store.buildStatus = "Обработка списков фильтров…"
        let plan = await Task.detached(priority: .userInitiated) { Self.makePlan(inputs) }.value
        guard generation == compileGeneration else { return ([], 0) }
        store.recordStats(plan.stats, custom: plan.custom)

        var lists: [WKContentRuleList] = []
        var ruleCount = 0
        for (index, chunk) in plan.chunks.enumerated() {
            store.buildStatus = plan.chunks.count > 1
                ? "Сборка правил: часть \(index + 1) из \(plan.chunks.count)…"
                : "Сборка правил…"
            let identifier = Self.filterListPrefix + "\(key)-\(index)"
            var rules = chunk
            var list = await compile(identifier: identifier, json: "[" + rules.joined(separator: ",") + "]")
            if list == nil {
                // В части есть правило, которое WebKit не принимает: находим и выкидываем.
                store.buildStatus = "Поиск неподдерживаемых правил…"
                let bad = await invalidRuleIndices(rules[...], offset: 0, budget: 24)
                if !bad.isEmpty {
                    let badSet = Set(bad)
                    rules = rules.enumerated().filter { !badSet.contains($0.offset) }.map(\.element)
                    list = await compile(identifier: identifier, json: "[" + rules.joined(separator: ",") + "]")
                }
            }
            guard generation == compileGeneration else { return ([], 0) }
            if let list {
                lists.append(list)
                ruleCount += rules.count
            }
        }
        if lists.count == plan.chunks.count {
            defaults.set(key, forKey: Self.compiledKeyKey)
            defaults.set(lists.count, forKey: Self.compiledCountKey)
            defaults.set(ruleCount, forKey: Self.compiledRulesKey)
        }
        await removeStaleLists(keeping: Set(lists.map(\.identifier)))
        return (lists, ruleCount)
    }

    /// WebKit принимает не больше 150 000 правил в одном списке; берём с запасом.
    nonisolated private static let maxRulesPerList = 60_000

    nonisolated private static func makePlan(_ inputs: ListInputs) -> ListPlan {
        var plan = ListPlan()
        var combined = FilterConverter.Result()
        for file in inputs.files {
            guard let text = try? String(contentsOf: file.url, encoding: .utf8) else { continue }
            let result = FilterConverter.convert(text)
            plan.stats[file.id] = (result.converted, result.skipped)
            combined.append(result)
        }
        let custom = FilterConverter.convert(inputs.customRules)
        plan.custom = (custom.converted, custom.skipped)
        combined.append(custom)

        func encode(_ rule: [String: Any]) -> String? {
            guard let data = try? JSONSerialization.data(withJSONObject: rule) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let blocks = combined.blocks.compactMap(encode)
        let hiding = combined.hiding.compactMap(encode)
        // Исключения, блокировка страниц и белый список нужны в каждой части:
        // ignore-previous-rules действует только внутри своего списка.
        var tail = combined.documentBlocks.compactMap(encode) + combined.exceptions.compactMap(encode)
        if let allow = allowlistRule(inputs.allowlist).flatMap(encode) { tail.append(allow) }
        let topFrame = encode(FilterConverter.topFrameAllowance)!

        let perChunk = max(1_000, maxRulesPerList - tail.count - 1)
        let items = blocks.map { (true, $0) } + hiding.map { (false, $0) }
        var start = 0
        repeat {
            let slice = items[start..<min(start + perChunk, items.count)]
            let chunkBlocks = slice.filter(\.0).map(\.1)
            let chunkHiding = slice.filter { !$0.0 }.map(\.1)
            plan.chunks.append(chunkBlocks + [topFrame] + chunkHiding + tail)
            start += perChunk
        } while start < items.count
        return plan
    }

    // MARK: - WebKit

    private func compile(identifier: String, json: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let error { print("Aircraft AdBlocker: не удалось собрать \(identifier): \(error)") }
                continuation.resume(returning: list)
            }
        }
    }

    private func lookUp(_ identifier: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    /// Делением пополам находит правила, из-за которых WebKit отклоняет весь список.
    private func invalidRuleIndices(_ rules: ArraySlice<String>, offset: Int, budget: Int) async -> [Int] {
        guard !rules.isEmpty, budget > 0 else { return [] }
        if await compile(identifier: Self.probeIdentifier, json: "[" + rules.joined(separator: ",") + "]") != nil { return [] }
        if rules.count == 1 { return [offset] }
        let middle = rules.startIndex + rules.count / 2
        let left = await invalidRuleIndices(rules[rules.startIndex..<middle], offset: offset, budget: budget - 1)
        let right = await invalidRuleIndices(rules[middle...], offset: offset + (middle - rules.startIndex), budget: budget - 1)
        return left + right
    }

    private func removeStaleLists(keeping: Set<String>) async {
        let store = WKContentRuleListStore.default()
        let identifiers: [String] = await withCheckedContinuation { continuation in
            store?.getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0 ?? []) }
        }
        for identifier in identifiers
        where (identifier.hasPrefix(Self.filterListPrefix) || identifier == Self.probeIdentifier) && !keeping.contains(identifier) {
            store?.removeContentRuleList(forIdentifier: identifier) { _ in }
        }
    }

    private func notify(reloadPages: Bool) {
        NotificationCenter.default.post(name: .adBlockRulesDidChange, object: nil, userInfo: ["reload": reloadPages])
    }

    nonisolated static func normalizedHost(_ host: String?) -> String? {
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

    static func rulesJSON(ads: Bool = true, trackers: Bool = false, allowlist: [String], extraExceptions: [[String: Any]] = []) -> String {
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
        return encoded(rules + extraExceptions, allowlist: allowlist)
    }

    /// Правила против рекламы Яндекса и Google (см. `SiteAdRules`).
    static func siteRulesJSON(yandex: Bool, google: Bool, allowlist: [String], extraExceptions: [[String: Any]] = []) -> String {
        encoded(SiteAdRules.rules(yandex: yandex, google: google) + extraExceptions, allowlist: allowlist)
    }

    /// Белый список: на этих сайтах все предыдущие правила отменяются.
    nonisolated static func allowlistRule(_ allowlist: [String]) -> [String: Any]? {
        let domains = allowlist.compactMap { normalizedHost($0) }.map { "*\($0)" }
        guard !domains.isEmpty else { return nil }
        return ["trigger": ["url-filter": ".*", "if-domain": domains], "action": ["type": "ignore-previous-rules"]]
    }

    private static func encoded(_ rules: [[String: Any]], allowlist: [String]) -> String {
        var rules = rules
        if let allow = allowlistRule(allowlist) { rules.append(allow) }
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}

extension Notification.Name {
    static let adBlockRulesDidChange = Notification.Name("AdBlockRulesDidChange")
}
