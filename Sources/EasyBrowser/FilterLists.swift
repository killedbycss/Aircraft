import CryptoKit
import Foundation
import Observation

/// Подписка на список фильтров (EasyList, AdGuard…).
struct FilterListInfo: Codable, Identifiable, Hashable {
    enum Group: String, Codable, CaseIterable {
        case ads, privacy, annoyances, custom

        var title: String {
            switch self {
            case .ads: "Реклама"
            case .privacy: "Приватность"
            case .annoyances: "Раздражители"
            case .custom: "Свои подписки"
            }
        }
    }

    let id: String
    var title: String
    var summary: String
    var url: String
    var group: Group
    var homepage: String?
}

/// Состояние подписки на этом компьютере.
struct FilterListState: Codable, Hashable {
    var enabled: Bool
    var lastUpdated: Date?
    var lastChecked: Date?
    var convertedRules: Int?
    var skippedRules: Int?
    var lastError: String?
}

/// Подписки на списки фильтров: загрузка, обновление, свои правила.
/// Сами правила собирает `AdBlocker` (через `FilterConverter`).
@MainActor
@Observable
final class FilterListStore {
    static let shared = FilterListStore()

    static let catalog: [FilterListInfo] = [
        FilterListInfo(id: "easylist", title: "EasyList",
                       summary: "Основной международный список: рекламные сети, баннеры, рекламные блоки",
                       url: "https://easylist.to/easylist/easylist.txt", group: .ads, homepage: "https://easylist.to"),
        FilterListInfo(id: "adguard-russian", title: "AdGuard — русский",
                       summary: "Реклама на русскоязычных сайтах, Яндекс, VK, Mail.ru. Версия для Safari/WebKit",
                       url: "https://filters.adtidy.org/extension/safari/filters/1.txt", group: .ads, homepage: "https://adguard.com"),
        FilterListInfo(id: "ruadlist", title: "RU AdList",
                       summary: "Русскоязычный список от сообщества easylist-ru",
                       url: "https://easylist-downloads.adblockplus.org/advblock.txt", group: .ads),
        FilterListInfo(id: "adguard-base", title: "AdGuard Base",
                       summary: "Большой основной список AdGuard. Сильно пересекается с EasyList, долго собирается",
                       url: "https://filters.adtidy.org/extension/safari/filters/2.txt", group: .ads, homepage: "https://adguard.com"),
        FilterListInfo(id: "ublock-filters", title: "uBlock filters",
                       summary: "Собственный список uBlock Origin (часть правил требует расширения и пропускается)",
                       url: "https://ublockorigin.github.io/uAssets/filters/filters.txt", group: .ads),
        FilterListInfo(id: "peter-lowe", title: "Peter Lowe’s list",
                       summary: "Компактный список рекламных и следящих серверов",
                       url: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&mimetype=plaintext", group: .ads),
        FilterListInfo(id: "easyprivacy", title: "EasyPrivacy",
                       summary: "Счётчики, пиксели и сбор данных о посетителях",
                       url: "https://easylist.to/easylist/easyprivacy.txt", group: .privacy, homepage: "https://easylist.to"),
        FilterListInfo(id: "adguard-tracking", title: "AdGuard Tracking Protection",
                       summary: "Трекеры и аналитика по версии AdGuard",
                       url: "https://filters.adtidy.org/extension/safari/filters/3.txt", group: .privacy),
        FilterListInfo(id: "adguard-social", title: "Кнопки соцсетей",
                       summary: "Виджеты «Поделиться», «Мне нравится» и встроенные ленты соцсетей",
                       url: "https://filters.adtidy.org/extension/safari/filters/4.txt", group: .privacy),
        FilterListInfo(id: "adguard-cookies", title: "Уведомления о cookie",
                       summary: "Прячет баннеры «Мы используем cookie»",
                       url: "https://filters.adtidy.org/extension/safari/filters/18.txt", group: .annoyances),
        FilterListInfo(id: "adguard-popups", title: "Всплывающие окна",
                       summary: "Подписки на рассылки, push-уведомления и прочие окна поверх сайта",
                       url: "https://filters.adtidy.org/extension/safari/filters/19.txt", group: .annoyances),
        FilterListInfo(id: "adguard-widgets", title: "Виджеты",
                       summary: "Чаты поддержки, онлайн-консультанты и похожие виджеты",
                       url: "https://filters.adtidy.org/extension/safari/filters/22.txt", group: .annoyances),
        FilterListInfo(id: "adguard-other-annoyances", title: "Прочие раздражители",
                       summary: "Баннеры приложений, напоминания и другие отвлекающие элементы",
                       url: "https://filters.adtidy.org/extension/safari/filters/21.txt", group: .annoyances)
    ]
    static let defaultEnabled: Set<String> = ["easylist", "adguard-russian"]

    private static let statesKey = "filterListStates"
    private static let customListsKey = "filterListCustom"
    static let autoUpdateKey = "filterListAutoUpdateDays"

    private(set) var customLists: [FilterListInfo] = []
    private(set) var states: [String: FilterListState] = [:]
    private(set) var updating: Set<String> = []
    private(set) var customRules: String = ""
    /// Через сколько дней обновлять списки (0 — не обновлять автоматически).
    var autoUpdateDays: Int {
        didSet { UserDefaults.standard.set(autoUpdateDays, forKey: Self.autoUpdateKey) }
    }

    /// Что сейчас делает `AdBlocker` — показывается в настройках.
    var buildStatus: String?
    var activeRuleCount = 0
    var customRulesStats: (converted: Int, skipped: Int) = (0, 0)

    var allLists: [FilterListInfo] { Self.catalog + customLists }

    private init() {
        let defaults = UserDefaults.standard
        autoUpdateDays = defaults.object(forKey: Self.autoUpdateKey) as? Int ?? 4
        if let data = defaults.data(forKey: Self.statesKey),
           let decoded = try? JSONDecoder().decode([String: FilterListState].self, from: data) {
            states = decoded
        } else {
            states = Dictionary(uniqueKeysWithValues: Self.defaultEnabled.map { ($0, FilterListState(enabled: true)) })
        }
        if let data = defaults.data(forKey: Self.customListsKey),
           let decoded = try? JSONDecoder().decode([FilterListInfo].self, from: data) {
            customLists = decoded
        }
        customRules = (try? String(contentsOf: Self.customRulesURL, encoding: .utf8)) ?? ""
    }

    // MARK: - Файлы

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Aircraft/FilterLists", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(for id: String) -> URL { directory.appendingPathComponent("\(id).txt") }
    static var customRulesURL: URL { directory.appendingPathComponent("custom-rules.txt") }

    func isDownloaded(_ id: String) -> Bool { FileManager.default.fileExists(atPath: Self.fileURL(for: id).path) }

    /// Включённые и уже загруженные списки — то, из чего собираются правила.
    var activeListFiles: [(id: String, url: URL)] {
        allLists.filter { states[$0.id]?.enabled == true && isDownloaded($0.id) }
            .map { ($0.id, Self.fileURL(for: $0.id)) }
    }

    // MARK: - Управление

    func isEnabled(_ id: String) -> Bool { states[id]?.enabled == true }

    func setEnabled(_ enabled: Bool, id: String) {
        states[id, default: FilterListState(enabled: enabled)].enabled = enabled
        save()
        if enabled && !isDownloaded(id) {
            Task { await update(ids: [id]) }
        } else {
            AdBlocker.shared.rebuild(reloadPages: true)
        }
    }

    func setCustomRules(_ text: String) {
        customRules = text
        try? text.write(to: Self.customRulesURL, atomically: true, encoding: .utf8)
        AdBlocker.shared.rebuild(reloadPages: true)
    }

    /// Добавляет правило (например, из пипетки «Скрыть элемент»).
    func appendCustomRule(_ rule: String) {
        var text = customRules
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        setCustomRules(text + rule + "\n")
    }

    /// Добавляет подписку по адресу. Возвращает текст ошибки.
    func addCustomList(urlString: String) async -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https" || url.scheme == "http", url.host != nil else {
            return "Нужен адрес вида https://…/list.txt"
        }
        guard !allLists.contains(where: { $0.url == trimmed }) else { return "Этот список уже добавлен" }
        let id = "custom-" + String(SHA256.hash(data: Data(trimmed.utf8)).map { String(format: "%02x", $0) }.joined().prefix(10))
        let info = FilterListInfo(id: id, title: url.host ?? trimmed, summary: trimmed, url: trimmed, group: .custom)
        customLists.append(info)
        states[id] = FilterListState(enabled: true)
        save()
        await update(ids: [id])
        if let error = states[id]?.lastError, !isDownloaded(id) {
            removeCustomList(id: id)
            return error
        }
        return nil
    }

    func removeCustomList(id: String) {
        customLists.removeAll { $0.id == id }
        states[id] = nil
        try? FileManager.default.removeItem(at: Self.fileURL(for: id))
        save()
        AdBlocker.shared.rebuild(reloadPages: true)
    }

    /// Загружает списки, у которых подошёл срок обновления или которых ещё нет на диске.
    func refreshIfNeeded() {
        guard AdBlocker.shared.isEnabled else { return }
        let now = Date()
        let due = allLists.filter { list in
            guard let state = states[list.id], state.enabled, !updating.contains(list.id) else { return false }
            guard isDownloaded(list.id), let checked = state.lastChecked ?? state.lastUpdated else { return true }
            return autoUpdateDays > 0 && now.timeIntervalSince(checked) > Double(autoUpdateDays) * 86_400
        }
        guard !due.isEmpty else { return }
        Task { await update(ids: due.map(\.id)) }
    }

    func updateAll() async {
        await update(ids: allLists.filter { isEnabled($0.id) }.map(\.id))
    }

    func update(ids: [String]) async {
        let targets = allLists.filter { ids.contains($0.id) && !updating.contains($0.id) }
        guard !targets.isEmpty else { return }
        updating.formUnion(targets.map(\.id))
        var changed = false
        await withTaskGroup(of: (String, Result<(String, String?), Error>).self) { group in
            for list in targets {
                group.addTask { (list.id, await Self.download(list)) }
            }
            for await (id, result) in group {
                updating.remove(id)
                var state = states[id] ?? FilterListState(enabled: true)
                state.lastChecked = Date()
                switch result {
                case .success(let (text, title)):
                    do {
                        try text.write(to: Self.fileURL(for: id), atomically: true, encoding: .utf8)
                        state.lastUpdated = Date()
                        state.lastError = nil
                        if let title, let index = customLists.firstIndex(where: { $0.id == id }) {
                            customLists[index].title = title
                        }
                        changed = true
                    } catch {
                        state.lastError = error.localizedDescription
                    }
                case .failure(let error):
                    state.lastError = (error as? DownloadError)?.message ?? error.localizedDescription
                }
                states[id] = state
            }
        }
        save()
        if changed { AdBlocker.shared.rebuild(reloadPages: false) }
    }

    private struct DownloadError: Error { let message: String }

    /// Текст списка и его название из заголовка «! Title:».
    nonisolated private static func download(_ list: FilterListInfo) async -> Result<(String, String?), Error> {
        guard let url = URL(string: list.url) else { return .failure(DownloadError(message: "Неверный адрес")) }
        do {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            request.setValue("Aircraft", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .failure(DownloadError(message: "Сервер ответил \(http.statusCode)"))
            }
            // Страница ошибки вместо списка: смотрим только начало файла — в самих правилах «<html» бывает.
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  !text.isEmpty,
                  !text.prefix(512).trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("<") else {
                return .failure(DownloadError(message: "Это не список фильтров"))
            }
            let title = text.split(separator: "\n", maxSplits: 40).lazy
                .first { $0.hasPrefix("! Title:") }
                .map { $0.dropFirst("! Title:".count).trimmingCharacters(in: .whitespaces) }
            return .success((text, title))
        } catch {
            return .failure(error)
        }
    }

    /// Сколько правил удалось перевести из каждого списка (заполняет `AdBlocker`).
    func recordStats(_ stats: [String: (Int, Int)], custom: (Int, Int)) {
        for (id, (converted, skipped)) in stats {
            states[id]?.convertedRules = converted
            states[id]?.skippedRules = skipped
        }
        customRulesStats = custom
        save()
    }

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(states) { defaults.set(data, forKey: Self.statesKey) }
        if let data = try? JSONEncoder().encode(customLists) { defaults.set(data, forKey: Self.customListsKey) }
    }
}
