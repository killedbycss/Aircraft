import Foundation
import Observation

public enum PermissionDecision: String, Codable, Sendable {
    case allow, deny
}

public enum SitePermission: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    case camera, microphone, location

    public var title: String {
        switch self {
        case .camera: "Камера"
        case .microphone: "Микрофон"
        case .location: "Геопозиция"
        }
    }

    public var symbol: String {
        switch self {
        case .camera: "video.fill"
        case .microphone: "mic.fill"
        case .location: "location.fill"
        }
    }
}

public struct SiteSettings: Codable, Equatable, Sendable {
    public var zoom: Double?
    public var permissions: [SitePermission: PermissionDecision] = [:]

    public var isEmpty: Bool { zoom == nil && permissions.isEmpty }
}

/// Настройки сайтов профиля: масштаб и решения о разрешениях. Ключ — хост без «www.».
@MainActor
@Observable
public final class SiteSettingsStore {
    public private(set) var sites: [String: SiteSettings] = [:]
    @ObservationIgnored private let url: URL?

    /// `url == nil` — хранилище в памяти (инкогнито).
    init(url: URL?, seed: [String: SiteSettings] = [:]) {
        self.url = url
        sites = url.flatMap { JSONFile.load([String: SiteSettings].self, from: $0) } ?? seed
    }

    static func key(_ host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    public func settings(for host: String?) -> SiteSettings {
        Self.key(host).flatMap { sites[$0] } ?? SiteSettings()
    }

    public func zoom(for host: String?) -> Double { settings(for: host).zoom ?? 1 }

    public func setZoom(_ value: Double, for host: String?) {
        modify(host) { $0.zoom = abs(value - 1) < 0.001 ? nil : value }
    }

    public func decision(_ permission: SitePermission, for host: String?) -> PermissionDecision? {
        settings(for: host).permissions[permission]
    }

    public func setDecision(_ decision: PermissionDecision?, _ permission: SitePermission, for host: String?) {
        modify(host) { $0.permissions[permission] = decision }
    }

    public func reset(_ host: String) {
        sites[host] = nil
        save()
    }

    public func resetAll() {
        sites = [:]
        save()
    }

    private func modify(_ host: String?, _ change: (inout SiteSettings) -> Void) {
        guard let key = Self.key(host) else { return }
        var value = sites[key] ?? SiteSettings()
        change(&value)
        sites[key] = value.isEmpty ? nil : value
        save()
    }

    private func save() {
        if let url { JSONFile.save(sites, to: url) }
    }
}

/// Архив вкладок профиля: автоархив и ручная архивация. До 200 записей.
@MainActor
@Observable
public final class TabArchive {
    public static let limit = 200
    public private(set) var entries: [ClosedTab] = []
    @ObservationIgnored private let url: URL?

    init(url: URL?) {
        self.url = url
        entries = url.flatMap { JSONFile.load([ClosedTab].self, from: $0) } ?? []
    }

    public func add(_ entries: [ClosedTab]) {
        guard !entries.isEmpty else { return }
        self.entries.insert(contentsOf: entries, at: 0)
        if self.entries.count > Self.limit { self.entries.removeLast(self.entries.count - Self.limit) }
        save()
    }

    public func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    public func clear() {
        entries = []
        save()
    }

    public func search(_ query: String, limit: Int = 4) -> [ClosedTab] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return entries.filter { entry in
            let haystack = (entry.tab.title + " " + (entry.tab.url?.absoluteString ?? "")).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }.prefix(limit).map { $0 }
    }

    private func save() {
        if let url {
            // Историю переходов в архиве не храним — только адрес.
            JSONFile.save(entries, to: url)
        }
    }
}
