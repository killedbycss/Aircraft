import Foundation
import WebKit
import Observation
import SwiftUI

/// Профиль: свои cookie и данные сайтов, история, закладки, настройки сайтов и вкладки.
public struct Profile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var colorIndex: Int
    public var symbol: String
    /// Профиль по умолчанию живёт в стандартном хранилище WebKit,
    /// чтобы после обновления никого не разлогинило.
    public var isDefault: Bool

    public static let symbols = ["person.fill", "briefcase.fill", "house.fill", "graduationcap.fill",
                                 "gamecontroller.fill", "cart.fill", "heart.fill", "star.fill", "leaf.fill", "bolt.fill"]

    public static let palette: [Color] = [.blue, .purple, .pink, .orange, .yellow, .green, .teal, .gray]

    public var color: Color { Self.palette[colorIndex % Self.palette.count] }
}

@MainActor
@Observable
public final class ProfileStore {
    public static let shared = ProfileStore()

    public private(set) var profiles: [Profile] = []
    /// Профиль, который откроется в новом окне.
    public var lastUsedProfileID: UUID? {
        didSet { UserDefaults.standard.set(lastUsedProfileID?.uuidString, forKey: "lastUsedProfileID") }
    }

    @ObservationIgnored private var dataStores: [UUID: WKWebsiteDataStore] = [:]
    @ObservationIgnored private var histories: [UUID: HistoryStore] = [:]
    @ObservationIgnored private var bookmarkStores: [UUID: BookmarkStore] = [:]
    @ObservationIgnored private var siteStores: [UUID: SiteSettingsStore] = [:]
    @ObservationIgnored private var archives: [UUID: TabArchive] = [:]

    private var fileURL: URL { AircraftPaths.root.appendingPathComponent("profiles.json") }

    private init() {
        profiles = JSONFile.load([Profile].self, from: fileURL) ?? []
        if !profiles.contains(where: \.isDefault) {
            profiles.insert(Profile(id: UUID(), name: "Личный", colorIndex: 0, symbol: "person.fill", isDefault: true), at: 0)
            save()
        }
        lastUsedProfileID = UserDefaults.standard.string(forKey: "lastUsedProfileID").flatMap(UUID.init(uuidString:))
    }

    public var defaultProfile: Profile { profiles.first(where: \.isDefault) ?? profiles[0] }

    public func profile(_ id: UUID?) -> Profile {
        profiles.first(where: { $0.id == id }) ?? defaultProfile
    }

    @discardableResult
    public func create(name: String) -> Profile {
        let used = Set(profiles.map(\.colorIndex))
        let color = (0..<Profile.palette.count).first { !used.contains($0) } ?? profiles.count % Profile.palette.count
        let symbol = Profile.symbols[profiles.count % Profile.symbols.count]
        let profile = Profile(id: UUID(), name: name, colorIndex: color, symbol: symbol, isDefault: false)
        profiles.append(profile)
        save()
        return profile
    }

    public func update(_ profile: Profile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        save()
    }

    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        profiles.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Удаляет профиль вместе с cookie, историей и закладками.
    public func delete(_ id: UUID) async {
        guard let profile = profiles.first(where: { $0.id == id }), !profile.isDefault else { return }
        profiles.removeAll { $0.id == id }
        save()
        dataStores[id] = nil
        histories[id] = nil
        bookmarkStores[id] = nil
        siteStores[id] = nil
        archives[id] = nil
        SessionStore.shared.removeProfile(id)
        if lastUsedProfileID == id { lastUsedProfileID = defaultProfile.id }
        try? await WKWebsiteDataStore.remove(forIdentifier: id)
        try? FileManager.default.removeItem(at: AircraftPaths.profileDirectory(id))
        NotificationCenter.default.post(name: .profileDeleted, object: nil, userInfo: ["id": id])
    }

    public func dataStore(for id: UUID) -> WKWebsiteDataStore {
        let profile = profile(id)
        if profile.isDefault { return .default() }
        if let store = dataStores[profile.id] { return store }
        let store = WKWebsiteDataStore(forIdentifier: profile.id)
        dataStores[profile.id] = store
        return store
    }

    public func history(for id: UUID) -> HistoryStore {
        let profileID = profile(id).id
        if let store = histories[profileID] { return store }
        let store = HistoryStore(url: AircraftPaths.profileDirectory(profileID).appendingPathComponent("history.sqlite"))
        histories[profileID] = store
        return store
    }

    public func bookmarks(for id: UUID) -> BookmarkStore {
        let profileID = profile(id).id
        if let store = bookmarkStores[profileID] { return store }
        let store = BookmarkStore(url: AircraftPaths.profileDirectory(profileID).appendingPathComponent("bookmarks.json"))
        bookmarkStores[profileID] = store
        return store
    }

    public func sites(for id: UUID) -> SiteSettingsStore {
        let profileID = profile(id).id
        if let store = siteStores[profileID] { return store }
        let store = SiteSettingsStore(url: AircraftPaths.profileDirectory(profileID).appendingPathComponent("sites.json"))
        siteStores[profileID] = store
        return store
    }

    public func archive(for id: UUID) -> TabArchive {
        let profileID = profile(id).id
        if let store = archives[profileID] { return store }
        let store = TabArchive(url: AircraftPaths.profileDirectory(profileID).appendingPathComponent("archive.json"))
        archives[profileID] = store
        return store
    }

    private func save() { JSONFile.save(profiles, to: fileURL) }
}

extension Notification.Name {
    static let profileDeleted = Notification.Name("AircraftProfileDeleted")
}
