import AircraftLanguage
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Вкладки: группы, архив, картинка в картинке

struct TabBehaviorSettings: View {
    @AppStorage("groupOpenedLinks") private var groupOpenedLinks = true
    @AppStorage("autoArchiveHours") private var autoArchiveHours: Double = 24
    @AppStorage("autoPictureInPicture") private var autoPictureInPicture = false

    var body: some View {
        Section {
            Toggle(L10n("Group links opened in new tabs"), isOn: $groupOpenedLinks)
        } header: {
            Text(L10n("Groups and folders"))
        } footer: {
            Text(L10n("New links join their source tab’s group. Create folders in the tab bar menu, up to %1$@ levels deep.", "\(SidebarTree.maxFolderDepth)"))
                .foregroundStyle(.secondary)
        }
        Section {
            Picker(L10n("Archive inactive tabs"), selection: $autoArchiveHours) {
                Text(L10n("Never")).tag(0.0)
                Text(L10n("After 12 hours")).tag(12.0)
                Text(L10n("After one day")).tag(24.0)
                Text(L10n("After one week")).tag(168.0)
                Text(L10n("After 30 days")).tag(720.0)
            }
            .onChange(of: autoArchiveHours) { _, _ in TabArchiver.shared.run() }
        } header: {
            Text(L10n("Auto-archive"))
        } footer: {
            Text(L10n("Pinned tabs, folders and tabs playing media stay out of the archive. Open the archive in Library (⌘Y)."))
                .foregroundStyle(.secondary)
        }
        Section(L10n("Video")) {
            Toggle(L10n("Picture in Picture when leaving a video tab"), isOn: $autoPictureInPicture)
        }
    }
}

// MARK: - Профили

struct ProfilesSettingsPane: View {
    private var store: ProfileStore { ProfileStore.shared }
    @State private var editing: Profile?
    @State private var deleting: Profile?

    var body: some View {
        Form {
            Section {
                ForEach(Array(store.profiles.enumerated()), id: \.element.id) { index, profile in
                    HStack(spacing: 10) {
                        Image(systemName: profile.symbol)
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(profile.color))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).fontWeight(.medium)
                            Text(profile.isDefault ? L10n("Default · ⌃%1$@", "\(index + 1)") : "⌃\(index + 1)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n("profile.edit")) { editing = profile }
                        if !profile.isDefault {
                            Button(role: .destructive) { deleting = profile } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                Button(L10n("New profile")) { editing = store.create(name: L10n("Profile %1$@", "\(store.profiles.count + 1)")) }
            } footer: {
                Text(L10n("Profiles keep tabs, accounts, history, bookmarks and site settings separate. Switch below the tab list. Inactive profiles release tab memory."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(item: $editing) { profile in
            ProfileEditor(profile: profile) { store.update($0) }
        }
        .alert(L10n("Delete profile “%1$@”?", "\(deleting?.name ?? "")"), isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L10n("Delete"), role: .destructive) {
                if let id = deleting?.id { Task { await store.delete(id) } }
                deleting = nil
            }
            Button(L10n("Cancel"), role: .cancel) { deleting = nil }
        } message: {
            Text(L10n("This permanently deletes the profile’s tabs, history, bookmarks, cookies and sign-ins."))
        }
    }
}

private struct ProfileEditor: View {
    @State var profile: Profile
    let save: (Profile) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n("Profile")).font(.headline)
            TextField(L10n("Name"), text: $profile.name).textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                ForEach(Profile.palette.indices, id: \.self) { index in
                    Circle().fill(Profile.palette[index])
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(Color.primary, lineWidth: profile.colorIndex == index ? 2 : 0))
                        .onTapGesture { profile.colorIndex = index }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32)), count: 5), spacing: 8) {
                ForEach(Profile.symbols, id: \.self) { symbol in
                    Image(systemName: symbol)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 7).fill(profile.symbol == symbol ? profile.color.opacity(0.3) : Color.primary.opacity(0.05)))
                        .onTapGesture { profile.symbol = symbol }
                }
            }
            HStack {
                Spacer()
                Button(L10n("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n("Save")) {
                    if profile.name.trimmingCharacters(in: .whitespaces).isEmpty { profile.name = L10n("Profile") }
                    save(profile)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

// MARK: - Конфиденциальность

struct PrivacySettingsPane: View {
    let manager: TabManager?
    @AppStorage("searchSuggestions") private var searchSuggestions = true
    @AppStorage("agentsSeeIncognito") private var agentsSeeIncognito = false
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle(L10n("Show search suggestions in Spotlight"), isOn: $searchSuggestions)
            } footer: {
                Text(L10n("Your search engine receives the query. History, bookmarks and open tabs are searched on this Mac."))
                    .foregroundStyle(.secondary)
            }
            if let manager, !manager.isIncognito {
                Section(L10n("History for %1$@", "\(manager.profile.name)")) {
                    HStack {
                        Button(L10n("Open history")) { LibraryWindow.show(.history, for: manager) }
                        Spacer()
                        Button(L10n("Clear all history…"), role: .destructive) { confirmClear = true }
                    }
                }
                Section(L10n("Sites")) {
                    SiteSettingsPane(store: manager.siteSettings)
                }
            }
            Section {
                Toggle(L10n("Allow agents to see incognito windows"), isOn: $agentsSeeIncognito)
            } header: {
                Text(L10n("Incognito"))
            } footer: {
                Text(L10n("Incognito windows (⌘⇧N) discard history, cookies, tabs and site settings. MCP agents cannot see them by default."))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .alert(L10n("Clear all history?"), isPresented: $confirmClear) {
            Button(L10n("action.clear"), role: .destructive) { manager?.history?.clearAll() }
            Button(L10n("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n("History for %1$@ will be deleted.", "\(manager?.profile.name ?? "")"))
        }
    }
}

// MARK: - Импорт

struct ImportSettingsSection: View {
    let manager: TabManager?
    @State private var source: BrowserImport.Source = .chrome
    @State private var includeBookmarks = true
    @State private var includeHistory = true
    @State private var includePinned = true
    @State private var status: String?
    @State private var needsDiskAccess = false

    var body: some View {
        Section {
            Picker(L10n("Import from"), selection: $source) {
                ForEach(BrowserImport.Source.allCases.filter(\.isInstalled)) { item in
                    Text(item.title).tag(item)
                }
                if BrowserImport.customProfileURL != nil {
                    Text(BrowserImport.Source.customChromium.title).tag(BrowserImport.Source.customChromium)
                }
            }
            Toggle(source.pinnedDescription, isOn: $includePinned)
            Toggle(L10n("Bookmarks in a separate folder"), isOn: $includeBookmarks)
            Toggle(L10n("History"), isOn: $includeHistory)
            HStack {
                Button(L10n("Import data")) { runImport() }
                    .disabled(manager == nil || manager?.isIncognito == true || (!includeBookmarks && !includeHistory && !includePinned))
                Button(L10n("From HTML file…")) { importHTML() }
                    .disabled(manager == nil)
                Button(L10n("Other Chromium browser…")) { chooseChromiumProfile() }
                    .help(L10n("Select a Chromium profile folder containing Bookmarks and History."))
                Spacer()
            }
            if let status {
                Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if needsDiskAccess {
                Button(L10n("Open Full Disk Access settings")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
            }
        } header: {
            Text(L10n("Import"))
        } footer: {
            Text(L10n("import.destinations"))
                .foregroundStyle(.secondary)
        }
    }

    private func runImport() {
        guard let manager else { return }
        let result = BrowserImport.run(source, bookmarks: includeBookmarks ? manager.bookmarks : nil,
                                       history: includeHistory ? manager.history : nil)
        needsDiskAccess = result.needsFullDiskAccess
        var parts: [String] = []
        var errors = result.errors
        if includePinned {
            do {
                let pinned = try BrowserImport.readPinned(source)
                let added = manager.importPinned(pinned)
                parts.append(L10n("Pinned: %1$@", "\(added)") + (added < pinned.count ? L10n(" (%1$@ already present)", "\(pinned.count - added)") : ""))
            } catch let error as BrowserImport.ImportError {
                errors.append(error.message)
                if error.needsFullDiskAccess { needsDiskAccess = true }
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if includeBookmarks { parts.append(L10n("Bookmarks: %1$@", "\(result.bookmarks)")) }
        if includeHistory { parts.append(L10n("History entries: %1$@", "\(result.pages)")) }
        status = L10n("Imported: ") + parts.joined(separator: ", ") + (errors.isEmpty ? "" : ". " + errors.joined(separator: " "))
    }

    private func chooseChromiumProfile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = L10n("Select a Chromium profile folder (usually Default in ~/Library/Application Support).")
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        BrowserImport.customProfileURL = url
        source = .customChromium
        status = BrowserImport.Source.customChromium.isInstalled ? nil : L10n("This folder has no Bookmarks or History file.")
    }

    private func importHTML() {
        guard let manager else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try BrowserImport.importHTML(url, into: manager.bookmarks)
            status = L10n("Bookmarks imported: %1$@", "\(count)")
        } catch {
            status = L10n("Could not read file: %1$@", "\(error.localizedDescription)")
        }
    }
}
