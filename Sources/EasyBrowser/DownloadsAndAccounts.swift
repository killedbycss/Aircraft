import SwiftUI
import AppKit
import WebKit

// MARK: - Загрузки

/// Журнал загрузок всего приложения. Хранится в `downloads.json`, живые загрузки
/// показывают прогресс. Раньше файлы просто молча появлялись в папке.
@MainActor
@Observable
final class DownloadStore {
    static let shared = DownloadStore()

    struct Item: Codable, Identifiable, Equatable {
        enum State: String, Codable { case running, finished, failed }
        var id = UUID()
        var fileName: String
        var file: URL?
        var source: URL?
        var startedAt = Date()
        var state: State = .running
        var progress: Double = 0
        var totalBytes: Int64 = 0
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private var observers: [UUID: NSKeyValueObservation] = [:]
    @ObservationIgnored private var byDownload: [ObjectIdentifier: UUID] = [:]
    private static var fileURL: URL { AircraftPaths.root.appendingPathComponent("downloads.json") }
    static let limit = 200

    private init() {
        items = JSONFile.load([Item].self, from: Self.fileURL) ?? []
        // Прерванные прошлым запуском загрузки не продолжатся.
        for index in items.indices where items[index].state == .running { items[index].state = .failed }
    }

    var activeCount: Int { items.filter { $0.state == .running }.count }

    func started(_ download: WKDownload, destination: URL, source: URL?) {
        let item = Item(fileName: destination.lastPathComponent, file: destination, source: source)
        items.insert(item, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        byDownload[ObjectIdentifier(download)] = item.id
        let id = item.id
        observers[id] = download.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
            let fraction = progress.fractionCompleted
            let total = progress.totalUnitCount
            Task { @MainActor in DownloadStore.shared.update(id) { $0.progress = fraction; $0.totalBytes = max(total, 0) } }
        }
        save()
    }

    func finished(_ download: WKDownload, success: Bool) {
        guard let id = byDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        observers.removeValue(forKey: id)
        update(id) {
            $0.state = success ? .finished : .failed
            if success { $0.progress = 1 }
        }
        save()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func clearFinished() {
        items.removeAll { $0.state != .running }
        save()
    }

    private func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func save() {
        JSONFile.save(items, to: Self.fileURL)
    }
}

struct DownloadsList: View {
    let search: String
    private var store: DownloadStore { .shared }

    var body: some View {
        let items = store.items.filter { search.isEmpty || $0.fileName.localizedCaseInsensitiveContains(search) }
        VStack(spacing: 0) {
            if items.isEmpty {
                ContentUnavailableView(search.isEmpty ? "Загрузок пока нет" : "Ничего не найдено", systemImage: "arrow.down.circle")
            } else {
                List(items) { item in
                    DownloadRow(item: item)
                }
            }
            Divider()
            HStack {
                Button("Очистить список") { store.clearFinished() }
                    .disabled(store.items.allSatisfy { $0.state == .running })
                Spacer()
                Button("Открыть папку загрузок") { NSWorkspace.shared.open(Self.downloadsFolder) }
            }
            .font(.system(size: 11))
            .padding(10)
        }
    }

    static var downloadsFolder: URL {
        let configured = UserDefaults.standard.string(forKey: "downloadFolderPath") ?? ""
        return configured.isEmpty
            ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            : URL(fileURLWithPath: configured, isDirectory: true)
    }
}

private struct DownloadRow: View {
    let item: DownloadStore.Item

    private var exists: Bool { item.file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let file = item.file, exists {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.path)).resizable()
                } else {
                    Image(systemName: "doc").resizable().scaledToFit().foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName).lineLimit(1)
                switch item.state {
                case .running:
                    ProgressView(value: item.progress).controlSize(.small)
                case .finished:
                    Text(status).font(.system(size: 10)).foregroundStyle(.secondary)
                case .failed:
                    Text("Не загружено").font(.system(size: 10)).foregroundStyle(.red)
                }
            }
            Spacer()
            if item.state == .finished, let file = item.file, exists {
                Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Показать в Finder")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let file = item.file, exists { NSWorkspace.shared.open(file) } }
        .contextMenu {
            if let file = item.file, exists {
                Button("Открыть") { NSWorkspace.shared.open(file) }
                Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
            if let source = item.source {
                Button("Скопировать адрес") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source.absoluteString, forType: .string)
                }
            }
            Divider()
            Button("Убрать из списка") { DownloadStore.shared.remove(item.id) }
        }
    }

    private var status: String {
        var parts: [String] = []
        if item.totalBytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file)) }
        parts.append(item.startedAt.formatted(date: .abbreviated, time: .shortened))
        if !exists { parts.append("файл удалён") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Аккаунты

/// Сайты, где выполнен вход: ищем в cookie профиля долгоживущие сессионные cookie.
/// Значения cookie не показываются и никуда не уходят.
struct AccountsList: View {
    let manager: TabManager
    let search: String
    @State private var sites: [Site] = []
    @State private var loading = true

    struct Site: Identifiable, Hashable {
        var id: String { domain }
        let domain: String
        let cookieCount: Int
        let expires: Date?
    }

    private static let markers = ["session", "sess", "sid", "auth", "token", "login", "logged", "user", "uid", "jwt", "remember", "account", "secure"]

    var body: some View {
        let visible = sites.filter { search.isEmpty || $0.domain.localizedCaseInsensitiveContains(search) }
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                ContentUnavailableView(search.isEmpty ? "Входов не найдено" : "Ничего не найдено", systemImage: "person.crop.circle")
            } else {
                List(visible) { site in
                    HStack(spacing: 10) {
                        FaviconImage(host: site.domain, size: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(site.domain)
                            Text(subtitle(site)).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Открыть") { open(site) }.buttonStyle(.borderless)
                    }
                    .contextMenu {
                        Button("Открыть сайт") { open(site) }
                        Button("Выйти (удалить cookie сайта)", role: .destructive) { signOut(site) }
                    }
                }
            }
        }
        .task(id: manager.profileID) { await reload() }
    }

    private func subtitle(_ site: Site) -> String {
        var text = "Активный вход"
        if let expires = site.expires { text += " · до \(expires.formatted(date: .abbreviated, time: .omitted))" }
        return text
    }

    private func reload() async {
        loading = true
        let cookies = await manager.websiteDataStore.httpCookieStore.allCookies()
        var grouped: [String: [HTTPCookie]] = [:]
        for cookie in cookies {
            let name = cookie.name.lowercased()
            guard Self.markers.contains(where: name.contains), !cookie.isSessionOnly || cookie.isSecure else { continue }
            let domain = HistoryStore.displayHost(URL(string: "https://" + cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))!)
            grouped[domain, default: []].append(cookie)
        }
        sites = grouped.map { domain, cookies in
            Site(domain: domain, cookieCount: cookies.count, expires: cookies.compactMap(\.expiresDate).max())
        }
        .sorted { $0.domain < $1.domain }
        loading = false
    }

    private func open(_ site: Site) {
        guard let url = URL(string: "https://" + site.domain) else { return }
        manager.createNewTab(url: url, selectNewTab: true, afterTabID: manager.activeTabID)
        manager.hostWindow?.makeKeyAndOrderFront(nil)
    }

    private func signOut(_ site: Site) {
        let store = manager.websiteDataStore
        store.fetchDataRecords(ofTypes: [WKWebsiteDataTypeCookies]) { records in
            let matching = records.filter { $0.displayName == site.domain || $0.displayName.hasSuffix("." + site.domain) }
            store.removeData(ofTypes: [WKWebsiteDataTypeCookies], for: matching) {
                Task { @MainActor in await reload() }
            }
        }
    }
}
