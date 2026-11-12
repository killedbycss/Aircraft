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
            Toggle("Собирать открытые ссылки в группы", isOn: $groupOpenedLinks)
        } header: {
            Text("Группы и папки")
        } footer: {
            Text("Ссылка, открытая в новой вкладке, попадает в группу вместе со страницей, с которой её открыли. Папки создаются через контекстное меню панели; вложенность — до \(SidebarTree.maxFolderDepth) уровней.")
                .foregroundStyle(.secondary)
        }
        Section {
            Picker("Архивировать неактивные вкладки", selection: $autoArchiveHours) {
                Text("Никогда").tag(0.0)
                Text("Через 12 часов").tag(12.0)
                Text("Через сутки").tag(24.0)
                Text("Через неделю").tag(168.0)
                Text("Через 30 дней").tag(720.0)
            }
            .onChange(of: autoArchiveHours) { _, _ in TabArchiver.shared.run() }
        } header: {
            Text("Автоархив")
        } footer: {
            Text("Закреплённые вкладки, вкладки в папках, вкладки со звуком и видео не архивируются. Архив — в Библиотеке (⌘Y).")
                .foregroundStyle(.secondary)
        }
        Section("Видео") {
            Toggle("Картинка в картинке при уходе с вкладки с видео", isOn: $autoPictureInPicture)
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
                            Text(profile.isDefault ? "Основной · ⌃\(index + 1)" : "⌃\(index + 1)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Изменить") { editing = profile }
                        if !profile.isDefault {
                            Button(role: .destructive) { deleting = profile } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                Button("Новый профиль") { editing = store.create(name: "Профиль \(store.profiles.count + 1)") }
            } footer: {
                Text("У каждого профиля свои cookie и входы на сайты, история, закладки, настройки сайтов и вкладки. Переключатель — внизу панели вкладок. Вкладки неактивного профиля выгружаются из памяти.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .sheet(item: $editing) { profile in
            ProfileEditor(profile: profile) { store.update($0) }
        }
        .alert("Удалить профиль «\(deleting?.name ?? "")»?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Удалить", role: .destructive) {
                if let id = deleting?.id { Task { await store.delete(id) } }
                deleting = nil
            }
            Button("Отмена", role: .cancel) { deleting = nil }
        } message: {
            Text("Удалятся вкладки, история, закладки, cookie и входы на сайты этого профиля. Это нельзя отменить.")
        }
    }
}

private struct ProfileEditor: View {
    @State var profile: Profile
    let save: (Profile) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Профиль").font(.headline)
            TextField("Название", text: $profile.name).textFieldStyle(.roundedBorder)
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
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    if profile.name.trimmingCharacters(in: .whitespaces).isEmpty { profile.name = "Профиль" }
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
                Toggle("Подсказки поисковика в Spotlight", isOn: $searchSuggestions)
            } footer: {
                Text("Введённый текст отправляется выбранному поисковику, чтобы показать подсказки. История, закладки и открытые вкладки ищутся только на этом Mac.")
                    .foregroundStyle(.secondary)
            }
            if let manager, !manager.isIncognito {
                Section("История профиля «\(manager.profile.name)»") {
                    HStack {
                        Button("Открыть историю") { LibraryWindow.show(.history, for: manager) }
                        Spacer()
                        Button("Очистить всю историю…", role: .destructive) { confirmClear = true }
                    }
                }
                Section("Сайты") {
                    SiteSettingsPane(store: manager.siteSettings)
                }
            }
            Section {
                Toggle("Агенты видят окна инкогнито", isOn: $agentsSeeIncognito)
            } header: {
                Text("Инкогнито")
            } footer: {
                Text("Окно инкогнито (⌘⇧P) не сохраняет историю, cookie, вкладки и настройки сайтов. По умолчанию MCP-агенты его не видят.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .alert("Очистить всю историю?", isPresented: $confirmClear) {
            Button("Очистить", role: .destructive) { manager?.history?.clearAll() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("История профиля «\(manager?.profile.name ?? "")» будет удалена.")
        }
    }
}

// MARK: - Импорт

struct ImportSettingsSection: View {
    let manager: TabManager?
    @State private var source: BrowserImport.Source = .chrome
    @State private var includeBookmarks = true
    @State private var includeHistory = true
    @State private var status: String?
    @State private var needsDiskAccess = false

    var body: some View {
        Section {
            Picker("Откуда", selection: $source) {
                ForEach(BrowserImport.Source.allCases.filter(\.isInstalled)) { item in
                    Text(item.title).tag(item)
                }
            }
            Toggle("Закладки", isOn: $includeBookmarks)
            Toggle("История", isOn: $includeHistory)
            HStack {
                Button("Импортировать") { runImport() }
                    .disabled(manager == nil || manager?.isIncognito == true || (!includeBookmarks && !includeHistory))
                Button("Из HTML-файла…") { importHTML() }
                    .disabled(manager == nil)
                Spacer()
            }
            if let status {
                Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if needsDiskAccess {
                Button("Открыть настройки полного доступа к диску") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
            }
        } header: {
            Text("Импорт")
        } footer: {
            Text("Закладки попадут в отдельную папку, история — в профиль «\(manager?.profile.name ?? "")». Для Safari macOS требует полный доступ к диску.")
                .foregroundStyle(.secondary)
        }
    }

    private func runImport() {
        guard let manager else { return }
        let result = BrowserImport.run(source, bookmarks: includeBookmarks ? manager.bookmarks : nil,
                                       history: includeHistory ? manager.history : nil)
        needsDiskAccess = result.needsFullDiskAccess
        var parts: [String] = []
        if includeBookmarks { parts.append("закладок: \(result.bookmarks)") }
        if includeHistory { parts.append("страниц истории: \(result.pages)") }
        status = "Импортировано — " + parts.joined(separator: ", ") + (result.errors.isEmpty ? "" : ". " + result.errors.joined(separator: " "))
    }

    private func importHTML() {
        guard let manager else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try BrowserImport.importHTML(url, into: manager.bookmarks)
            status = "Импортировано закладок: \(count)"
        } catch {
            status = "Не удалось прочитать файл: \(error.localizedDescription)"
        }
    }
}
