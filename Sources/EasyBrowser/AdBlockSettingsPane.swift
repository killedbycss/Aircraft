import AppKit
import SwiftUI

/// Настройки блокировщика: защита, подписки на списки, свои правила, пипетка и исключения.
struct AdBlockSettingsPane: View {
    /// Сайт открытой вкладки (без «www.») — для быстрого исключения.
    let currentSiteHost: String?

    @AppStorage(AdBlocker.enabledKey) private var adBlockEnabled = false
    @AppStorage(AdBlocker.trackerEnabledKey) private var trackerBlockEnabled = false
    @AppStorage(AdBlocker.yandexEnabledKey) private var yandexAdBlockEnabled = false
    @AppStorage(AdBlocker.googleEnabledKey) private var googleAdBlockEnabled = false

    private var store = FilterListStore.shared
    @State private var allowlist: [String] = []
    @State private var newAllowedSite = ""
    @State private var rulesDraft = ""
    @State private var rulesDraftLoaded = false
    @State private var newListURL = ""
    @State private var addListError: String?
    @State private var isAddingList = false

    init(currentSiteHost: String?) {
        self.currentSiteHost = currentSiteHost
    }

    var body: some View {
        Form {
            statusSection
            protectionSection
            ForEach([FilterListInfo.Group.ads, .privacy, .annoyances], id: \.self) { group in
                listsSection(group)
            }
            customListsSection
            customRulesSection
            allowlistSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            allowlist = AdBlocker.shared.allowlist
            if !rulesDraftLoaded {
                rulesDraft = store.customRules
                rulesDraftLoaded = true
            }
        }
        .onChange(of: store.customRules) { _, newValue in
            // Правило могла добавить пипетка, пока окно открыто.
            if rulesDraft != newValue && !rulesDraftIsDirty { rulesDraft = newValue }
        }
    }

    private var rulesDraftIsDirty: Bool { rulesDraft != store.customRules }

    // MARK: Состояние

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: anyProtection ? "checkmark.shield.fill" : "shield.slash")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(anyProtection ? Color.green : Color.secondary)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(anyProtection ? "Защита включена" : "Защита выключена")
                        .font(.system(size: 14, weight: .semibold))
                    if let status = store.buildStatus {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(status).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11))
                    } else if anyProtection {
                        Text("Активно \(store.activeRuleCount.formatted()) правил · списков: \(enabledListCount)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    ElementPicker.startInFrontmostWindow()
                } label: {
                    Label("Скрыть элемент…", systemImage: "eyedropper")
                }
                .help("Выберите на открытой странице элемент, который нужно скрыть навсегда (⌥⌘B)")
            }
            .padding(.vertical, 4)
        }
    }

    private var anyProtection: Bool { adBlockEnabled || trackerBlockEnabled || yandexAdBlockEnabled || googleAdBlockEnabled }
    private var enabledListCount: Int { adBlockEnabled ? store.activeListFiles.count : 0 }

    // MARK: Защита

    private var protectionSection: some View {
        Section {
            toggleRow(symbol: "hand.raised.fill", color: .red, title: "Блокировщик рекламы",
                      subtitle: "Встроенный список рекламных сетей, подписки на списки фильтров и свои правила",
                      isOn: $adBlockEnabled)
            toggleRow(symbol: "eye.slash.fill", color: .indigo, title: "Блокировщик трекеров",
                      subtitle: "Счётчики и пиксели слежки, метки utm_*, fbclid, gclid в ссылках",
                      isOn: $trackerBlockEnabled)
            toggleRow(symbol: "magnifyingglass", color: .orange, title: "Блокировать рекламу Яндекса",
                      subtitle: "Директ в Поиске, Карты, Маркет, Музыка, РСЯ и Adfox на сайтах, обход анти-адблока",
                      isOn: $yandexAdBlockEnabled)
            toggleRow(symbol: "play.rectangle.fill", color: .blue, title: "Блокировать рекламу Google",
                      subtitle: "Реклама в поиске Google, AdSense на сайтах, ролики, баннеры и окна анти-адблока на YouTube",
                      isOn: $googleAdBlockEnabled)
        } header: {
            Text("Защита")
        }
    }

    private func toggleRow(symbol: String, color: Color, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 2)
        .onChange(of: isOn.wrappedValue) { _, _ in
            AdBlocker.shared.rebuild(reloadPages: true)
            FilterListStore.shared.refreshIfNeeded()
        }
    }

    // MARK: Подписки

    private func listsSection(_ group: FilterListInfo.Group) -> some View {
        Section {
            ForEach(FilterListStore.catalog.filter { $0.group == group }) { list in
                listRow(list)
            }
        } header: {
            HStack {
                Text("Списки: \(group.title.lowercased())")
                Spacer()
                if group == .ads {
                    Picker("Обновлять", selection: Binding(get: { store.autoUpdateDays }, set: { store.autoUpdateDays = $0 })) {
                        Text("Каждый день").tag(1)
                        Text("Раз в 4 дня").tag(4)
                        Text("Раз в неделю").tag(7)
                        Text("Вручную").tag(0)
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    Button("Обновить все") { Task { await store.updateAll() } }
                        .disabled(!store.updating.isEmpty)
                }
            }
        } footer: {
            if group == .ads && !adBlockEnabled {
                Text("Списки работают, когда включён «Блокировщик рекламы».")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func listRow(_ list: FilterListInfo, removable: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(list.title)
                    if let homepage = list.homepage, let url = URL(string: homepage) {
                        Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                            .foregroundStyle(.tertiary)
                            .help(homepage)
                    }
                }
                Text(list.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(listDetails(list))
                    .font(.system(size: 10.5))
                    .foregroundStyle(store.states[list.id]?.lastError != nil ? Color.red : Color.secondary.opacity(0.8))
            }
            Spacer()
            if store.updating.contains(list.id) {
                ProgressView().controlSize(.small)
            } else if store.isEnabled(list.id) {
                Button {
                    Task { await store.update(ids: [list.id]) }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Обновить список")
            }
            if removable {
                Button {
                    store.removeCustomList(id: list.id)
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Удалить подписку")
            }
            Toggle("", isOn: Binding(get: { store.isEnabled(list.id) }, set: { store.setEnabled($0, id: list.id) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.vertical, 1)
    }

    private func listDetails(_ list: FilterListInfo) -> String {
        let state = store.states[list.id]
        if let error = state?.lastError { return "Ошибка: \(error)" }
        guard store.isDownloaded(list.id) else {
            return store.isEnabled(list.id) ? "Загружается…" : "Не загружен"
        }
        var parts: [String] = []
        if let converted = state?.convertedRules {
            parts.append("\(converted.formatted()) правил")
            if let skipped = state?.skippedRules, skipped > 0 { parts.append("\(skipped.formatted()) не поддерживается") }
        }
        if let updated = state?.lastUpdated {
            parts.append("обновлён " + updated.formatted(.relative(presentation: .named)))
        }
        return parts.isEmpty ? "Загружен" : parts.joined(separator: " · ")
    }

    private var customListsSection: some View {
        Section {
            ForEach(store.customLists) { list in
                listRow(list, removable: true)
            }
            HStack {
                TextField("Адрес списка", text: $newListURL, prompt: Text("https://example.com/filters.txt"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addList)
                if isAddingList {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Добавить", action: addList)
                        .disabled(newListURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let addListError {
                Text(addListError).font(.system(size: 11)).foregroundStyle(.red)
            }
        } header: {
            Text("Свои подписки")
        } footer: {
            Text("Подойдёт любой список в формате Adblock Plus, uBlock Origin или AdGuard, а также hosts-файл. Подборки: filterlists.com.")
                .foregroundStyle(.secondary)
        }
    }

    private func addList() {
        let url = newListURL
        isAddingList = true
        addListError = nil
        Task {
            let error = await store.addCustomList(urlString: url)
            isAddingList = false
            addListError = error
            if error == nil { newListURL = "" }
        }
    }

    // MARK: Свои правила

    private var customRulesSection: some View {
        Section {
            TextEditor(text: $rulesDraft)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 150, maxHeight: 280)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
            HStack {
                let stats = store.customRulesStats
                if !store.customRules.isEmpty {
                    Text("Принято: \(stats.converted)" + (stats.skipped > 0 ? " · не поддерживается: \(stats.skipped)" : ""))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Отменить") { rulesDraft = store.customRules }
                    .disabled(!rulesDraftIsDirty)
                Button("Применить") { store.setCustomRules(rulesDraft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!rulesDraftIsDirty)
                    .keyboardShortcut("s", modifiers: .command)
            }
        } header: {
            Text("Свои правила")
        } footer: {
            VStack(alignment: .leading, spacing: 3) {
                Text("Синтаксис Adblock Plus / uBlock Origin, одно правило на строку. Работают, даже если основной блокировщик выключен.")
                Text("||ads.example.com^ — блокировать домен · example.com##.banner — скрыть элемент · @@||example.com^ — не блокировать · ! комментарий")
                    .font(.system(size: 10.5, design: .monospaced))
            }
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Исключения

    private var allowlistSection: some View {
        Section {
            if let host = currentSiteHost {
                Toggle("Отключить защиту на \(host)", isOn: Binding(
                    get: { allowlist.contains(host) },
                    set: { setAllowed($0, host: host) }
                ))
            }
            ForEach(allowlist.filter { $0 != currentSiteHost }, id: \.self) { host in
                HStack {
                    Image(systemName: "checkmark.shield").foregroundStyle(.secondary)
                    Text(host).lineLimit(1)
                    Spacer()
                    Button { setAllowed(false, host: host) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Снова включить защиту на этом сайте")
                }
            }
            HStack {
                TextField("Сайт", text: $newAllowedSite, prompt: Text("example.com"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addAllowedSite)
                Button("Добавить", action: addAllowedSite)
                    .disabled(cleanedHost(newAllowedSite) == nil)
            }
        } header: {
            Text("Сайты без блокировки")
        } footer: {
            Text("На этих сайтах (и их поддоменах) не работают ни списки, ни встроенные правила. Пригодится, если сайт ломается.")
                .foregroundStyle(.secondary)
        }
    }

    private func setAllowed(_ allowed: Bool, host: String) {
        AdBlocker.shared.setAllowed(allowed, host: host)
        allowlist = AdBlocker.shared.allowlist
    }

    private func cleanedHost(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: value), let host = url.host { value = host }
        value = value.split(separator: "/").first.map(String.init) ?? value
        guard value.contains("."), value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return AdBlocker.normalizedHost(value)
    }

    private func addAllowedSite() {
        guard let host = cleanedHost(newAllowedSite) else { return }
        setAllowed(true, host: host)
        newAllowedSite = ""
    }
}
