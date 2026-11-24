import AircraftLanguage
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
                    Text(anyProtection ? L10n("Protection on") : L10n("Protection off"))
                        .font(.system(size: 14, weight: .semibold))
                    if let status = store.buildStatus {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(status).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11))
                    } else if anyProtection {
                        Text(L10n("Active rules: %1$@ · Lists: %2$@", "\(store.activeRuleCount.formatted())", "\(enabledListCount)"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    ElementPicker.startInFrontmostWindow()
                } label: {
                    Label(L10n("Hide element…"), systemImage: "eyedropper")
                }
                .help(L10n("Select an element to hide on this page (⌥⌘B)"))
            }
            .padding(.vertical, 4)
        }
    }

    private var anyProtection: Bool { adBlockEnabled || trackerBlockEnabled || yandexAdBlockEnabled || googleAdBlockEnabled }
    private var enabledListCount: Int { adBlockEnabled ? store.activeListFiles.count : 0 }

    // MARK: Защита

    private var protectionSection: some View {
        Section {
            toggleRow(symbol: "hand.raised.fill", title: L10n("Block ads"),
                      subtitle: L10n("Built-in ad networks, filter lists and custom rules"),
                      isOn: $adBlockEnabled)
            toggleRow(symbol: "eye.slash.fill", title: L10n("Block trackers"),
                      subtitle: L10n("Blocks tracking pixels and removes utm_*, fbclid and gclid from links."),
                      isOn: $trackerBlockEnabled)
            toggleRow(symbol: "magnifyingglass", title: L10n("Block Yandex ads"),
                      subtitle: L10n("Direct, Maps, Market, Music, Yandex Ad Network and Adfox"),
                      isOn: $yandexAdBlockEnabled)
            toggleRow(symbol: "play.rectangle.fill", title: L10n("Block Google ads"),
                      subtitle: L10n("Search ads, AdSense, YouTube ads and anti-blocking prompts"),
                      isOn: $googleAdBlockEnabled)
        } header: {
            Text(L10n("Protection"))
        }
    }

    private func toggleRow(symbol: String, title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .modifier(SettingsSymbolStyle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: isOn)
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
                Text(L10n("Lists: %1$@", "\(group.title.lowercased())"))
                Spacer()
                if group == .ads {
                    Picker(L10n("Update"), selection: Binding(get: { store.autoUpdateDays }, set: { store.autoUpdateDays = $0 })) {
                        Text(L10n("Daily")).tag(1)
                        Text(L10n("Every four days")).tag(4)
                        Text(L10n("Weekly")).tag(7)
                        Text(L10n("Manually")).tag(0)
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    Button(L10n("Update all")) { Task { await store.updateAll() } }
                        .disabled(!store.updating.isEmpty)
                }
            }
        } footer: {
            if group == .ads && !adBlockEnabled {
                Text(L10n("Enable ad blocking to use these lists."))
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
                    .help(L10n("Update list"))
            }
            if removable {
                Button {
                    store.removeCustomList(id: list.id)
                } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help(L10n("Remove subscription"))
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
        if let error = state?.lastError { return L10n("Error: %1$@", "\(error)") }
        guard store.isDownloaded(list.id) else {
            return store.isEnabled(list.id) ? L10n("Downloading…") : L10n("Not downloaded")
        }
        var parts: [String] = []
        if let converted = state?.convertedRules {
            parts.append(L10n("Rules: %1$@", "\(converted.formatted())"))
            if let skipped = state?.skippedRules, skipped > 0 { parts.append(L10n("Unsupported: %1$@", "\(skipped.formatted())")) }
        }
        if let updated = state?.lastUpdated {
            parts.append(L10n("Updated ") + updated.formatted(.relative(presentation: .named)))
        }
        return parts.isEmpty ? L10n("Downloaded") : parts.joined(separator: " · ")
    }

    private var customListsSection: some View {
        Section {
            ForEach(store.customLists) { list in
                listRow(list, removable: true)
            }
            HStack {
                TextField(L10n("List URL"), text: $newListURL, prompt: Text("https://example.com/filters.txt"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addList)
                if isAddingList {
                    ProgressView().controlSize(.small)
                } else {
                    Button(L10n("Add"), action: addList)
                        .disabled(newListURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let addListError {
                Text(addListError).font(.system(size: 11)).foregroundStyle(.red)
            }
        } header: {
            Text(L10n("Custom subscriptions"))
        } footer: {
            Text(L10n("Supports Adblock Plus, uBlock Origin, AdGuard and hosts files. Find lists at filterlists.com."))
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
                    Text(L10n("Accepted: %1$@", "\(stats.converted)") + (stats.skipped > 0 ? L10n(" · Unsupported: %1$@", "\(stats.skipped)") : ""))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n("Undo")) { rulesDraft = store.customRules }
                    .disabled(!rulesDraftIsDirty)
                Button(L10n("Apply")) { store.setCustomRules(rulesDraft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!rulesDraftIsDirty)
                    .keyboardShortcut("s", modifiers: .command)
            }
        } header: {
            Text(L10n("Custom rules"))
        } footer: {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n("One Adblock Plus or uBlock Origin rule per line. Custom rules also run when ad blocking is off."))
                Text(L10n("||ads.example.com^ blocks a domain · example.com##.banner hides an element · @@||example.com^ adds an exception · ! starts a comment"))
                    .font(.system(size: 10.5, design: .monospaced))
            }
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Исключения

    private var allowlistSection: some View {
        Section {
            if let host = currentSiteHost {
                Toggle(L10n("Disable protection on %1$@", "\(host)"), isOn: Binding(
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
                        .help(L10n("Enable protection on this site"))
                }
            }
            HStack {
                TextField(L10n("Site"), text: $newAllowedSite, prompt: Text("example.com"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addAllowedSite)
                Button(L10n("Add"), action: addAllowedSite)
                    .disabled(cleanedHost(newAllowedSite) == nil)
            }
        } header: {
            Text(L10n("Excluded sites"))
        } footer: {
            Text(L10n("Built-in rules and filter lists skip these sites and their subdomains."))
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
