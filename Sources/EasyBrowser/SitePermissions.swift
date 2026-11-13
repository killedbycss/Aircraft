import Foundation
import WebKit
import SwiftUI

/// Сайт просит камеру, микрофон или геопозицию и ждёт ответа.
public struct PermissionRequest: Identifiable {
    public let id = UUID()
    public let tabID: UUID
    public let host: String
    public let permissions: [SitePermission]
    let respond: @MainActor (Bool) -> Void
}

extension TabManager {
    // MARK: Камера и микрофон

    nonisolated public func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        let host = origin.host
        MainActor.assumeIsolated {
            let permissions: [SitePermission]
            switch type {
            case .camera: permissions = [.camera]
            case .microphone: permissions = [.microphone]
            default: permissions = [.camera, .microphone]
            }
            requestPermissions(permissions, host: host, webView: webView) { granted in
                decisionHandler(granted ? .grant : .deny)
            }
        }
    }

    // MARK: Геопозиция (приватный делегат WebKit)

    @objc(_webView:requestGeolocationPermissionForFrame:decisionHandler:)
    nonisolated public func _webView(_ webView: WKWebView, requestGeolocationPermissionFor frame: WKFrameInfo,
                                     decisionHandler: @escaping (Bool) -> Void) {
        let host = frame.securityOrigin.host
        nonisolated(unsafe) let handler = decisionHandler
        MainActor.assumeIsolated {
            requestPermissions([.location], host: host, webView: webView) { handler($0) }
        }
    }

    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    nonisolated public func _webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                                     initiatedBy frame: WKFrameInfo, decisionHandler: @escaping (Bool) -> Void) {
        let host = origin.host
        nonisolated(unsafe) let handler = decisionHandler
        MainActor.assumeIsolated {
            requestPermissions([.location], host: host, webView: webView) { handler($0) }
        }
    }

    // MARK: Решение

    /// Сохранённое решение применяется сразу; иначе над страницей появляется плашка.
    func requestPermissions(_ permissions: [SitePermission], host: String, webView: WKWebView,
                            respond: @escaping @MainActor (Bool) -> Void) {
        let decisions = permissions.map { siteSettings.decision($0, for: host) }
        if decisions.contains(.deny) {
            respond(false)
            return
        }
        if decisions.allSatisfy({ $0 == .allow }) {
            respond(true)
            return
        }
        guard let tab = tabs.first(where: { $0.webView === webView }) else {
            respond(false)
            return
        }
        permissionRequests.append(PermissionRequest(tabID: tab.id, host: host, permissions: permissions, respond: respond))
    }

    /// Ответ на плашку. `remember == false` — «Только сейчас».
    public func answerPermission(_ id: UUID, allow: Bool, remember: Bool) {
        guard let index = permissionRequests.firstIndex(where: { $0.id == id }) else { return }
        let request = permissionRequests.remove(at: index)
        if remember {
            for permission in request.permissions {
                siteSettings.setDecision(allow ? .allow : .deny, permission, for: request.host)
            }
        }
        request.respond(allow)
    }

    /// Страница сменилась — незаданные вопросы прежней страницы отклоняются.
    func cancelPermissionRequests(tabID: UUID) {
        let stale = permissionRequests.filter { $0.tabID == tabID }
        permissionRequests.removeAll { $0.tabID == tabID }
        stale.forEach { $0.respond(false) }
    }
}

// MARK: - Плашка над страницей

struct PermissionBanner: View {
    let request: PermissionRequest
    @Environment(TabManager.self) private var tabManager: TabManager

    private var subject: String {
        let names = request.permissions.map { $0.title.lowercased() }
        return names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " и " + names.last!
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                ForEach(request.permissions, id: \.self) { permission in
                    Image(systemName: permission.symbol)
                }
            }
            .foregroundStyle(.white)
            .padding(7)
            .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 1) {
                Text(request.host.isEmpty ? "Страница" : request.host).fontWeight(.semibold)
                Text("Просит доступ: \(subject)").foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            Button("Запретить") { tabManager.answerPermission(request.id, allow: false, remember: true) }
            Button("Только сейчас") { tabManager.answerPermission(request.id, allow: true, remember: false) }
            Button("Разрешить") { tabManager.answerPermission(request.id, allow: true, remember: true) }
                .keyboardShortcut(.defaultAction)
        }
        .font(.system(size: 11, weight: .medium))
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassOr(RoundedRectangle(cornerRadius: 12), interactive: true) { Rectangle().fill(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 12)) }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .frame(maxWidth: 620)
        .padding(.top, 10)
        .padding(.horizontal, 16)
    }
}

// MARK: - Настройки сайтов

struct SiteSettingsPane: View {
    let store: SiteSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Разрешения и масштаб, которые вы задали для сайтов в этом профиле.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if store.sites.isEmpty {
                Text("Пока ничего не задано.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.sites.keys.sorted(), id: \.self) { host in
                        row(host: host, settings: store.sites[host] ?? SiteSettings())
                        Divider()
                    }
                }
                Button("Сбросить всё", role: .destructive) { store.resetAll() }
            }
        }
    }

    private func row(host: String, settings: SiteSettings) -> some View {
        HStack(spacing: 10) {
            Text(host).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer()
            if let zoom = settings.zoom {
                Label("\(Int((zoom * 100).rounded())) %", systemImage: "plus.magnifyingglass")
            }
            ForEach(SitePermission.allCases, id: \.self) { permission in
                if let decision = settings.permissions[permission] {
                    Menu {
                        Button("Разрешить") { store.setDecision(.allow, permission, for: host) }
                        Button("Запретить") { store.setDecision(.deny, permission, for: host) }
                        Button("Спрашивать") { store.setDecision(nil, permission, for: host) }
                    } label: {
                        Label(permission.title, systemImage: decision == .allow ? permission.symbol : "nosign")
                            .foregroundStyle(decision == .allow ? Color.green : Color.red)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
            Button { store.reset(host) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Сбросить настройки сайта")
        }
        .font(.system(size: 11))
        .padding(.vertical, 7)
    }
}
