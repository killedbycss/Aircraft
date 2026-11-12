import AppKit
import SwiftUI
import WebKit

/// «Добавить в Dock»: сайт становится отдельным приложением в `~/Applications/Aircraft Apps`.
/// Внутри — бинарник `aircraft-webapp` из Aircraft.app, свой bundle ID (значит, свои cookie),
/// иконка сайта и ad-hoc подпись.
@MainActor
enum WebAppMaker {
    static var appsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Aircraft Apps", isDirectory: true)
    }

    static var installedApps: [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: appsFolder, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.pathExtension == "app" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func addActiveTab(of manager: TabManager) {
        guard let tab = manager.activeTab, let url = tab.url, url.scheme?.hasPrefix("http") == true else {
            NSSound.beep()
            return
        }
        guard let helper = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("aircraft-webapp"),
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            alert("Не найден aircraft-webapp", "Соберите Aircraft скриптом Scripts/build-app.sh — он кладёт помощника внутрь приложения.")
            return
        }
        let suggested = cleanName(tab.title, host: url.host ?? "Сайт")
        let prompt = NSAlert()
        prompt.messageText = "Добавить «\(url.host ?? "")» как приложение"
        prompt.informativeText = "Сайт откроется в своём окне с иконкой в Dock. У приложения свои входы на сайты: войти придётся заново."
        let field = NSTextField(string: suggested)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        prompt.accessoryView = field
        prompt.addButton(withTitle: "Создать")
        prompt.addButton(withTitle: "Отмена")
        prompt.window.initialFirstResponder = field
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        let name = cleanName(field.stringValue, host: url.host ?? "Сайт")

        Task { @MainActor in
            let icon = await siteIcon(for: tab, webView: tab.webView)
            do {
                let app = try build(name: name, url: url, icon: icon, helper: helper)
                manager.showToast("Приложение «\(name)» создано", symbol: "dock.rectangle")
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
            } catch {
                alert("Не удалось создать приложение", error.localizedDescription)
            }
        }
    }

    // MARK: Сборка .app

    static func build(name: String, url: URL, icon: NSImage?, helper: URL, in folder: URL = appsFolder) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = folder.appendingPathComponent("\(name).app", isDirectory: true)
        if fileManager.fileExists(atPath: app.path) { try fileManager.removeItem(at: app) }
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        try fileManager.copyItem(at: helper, to: macOS.appendingPathComponent("aircraft-webapp"))

        var info: [String: Any] = [
            "CFBundleExecutable": "aircraft-webapp",
            "CFBundleIdentifier": "com.taras.aircraft.webapp." + slug(url.host ?? name),
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "15.0",
            "NSHighResolutionCapable": true,
            "NSPrincipalClass": "NSApplication",
            "AircraftWebAppURL": url.absoluteString,
            "NSCameraUsageDescription": "Сайт может попросить камеру для звонков.",
            "NSMicrophoneUsageDescription": "Сайт может попросить микрофон для звонков."
        ]
        if let icon, try writeIcon(icon, to: resources.appendingPathComponent("AppIcon.icns")) {
            info["CFBundleIconFile"] = "AppIcon"
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        return app
    }

    /// Иконка: apple-touch-icon или favicon на скруглённой подложке, как у приложений macOS.
    private static func writeIcon(_ image: NSImage, to destination: URL) throws -> Bool {
        let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("aircraft-\(UUID().uuidString).iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: iconset) }
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                guard let data = renderIcon(image, pixels: pixels) else { return false }
                let suffix = scale == 2 ? "@2x" : ""
                try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
            }
        }
        try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", destination.path])
        return FileManager.default.fileExists(atPath: destination.path)
    }

    private static func renderIcon(_ image: NSImage, pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        let size = CGFloat(pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        // Сетка иконок macOS: подложка 80 % холста со скруглением ~22 %.
        let inset = size * 0.1
        let plate = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let path = NSBezierPath(roundedRect: plate, xRadius: plate.width * 0.225, yRadius: plate.width * 0.225)
        NSColor.white.setFill()
        path.fill()
        path.addClip()
        let isLarge = image.size.width >= 120
        let iconRect = isLarge ? plate : plate.insetBy(dx: plate.width * 0.2, dy: plate.width * 0.2)
        image.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func siteIcon(for tab: TabModel, webView: WKWebView?) async -> NSImage? {
        if let webView, let pageURL = webView.url {
            let script = """
            const links = [...document.querySelectorAll('link[rel~="apple-touch-icon"], link[rel~="apple-touch-icon-precomposed"], link[rel~="icon"]')];
            const size = (link) => parseInt((link.getAttribute('sizes') || '0').split('x')[0]) || (link.rel.includes('apple') ? 180 : 16);
            links.sort((a, b) => size(b) - size(a));
            return links.map(link => link.href);
            """
            let candidates = (try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)) as? [String] ?? []
            let fallbacks = ["/apple-touch-icon.png", "/favicon.ico"].compactMap { URL(string: $0, relativeTo: pageURL)?.absoluteString }
            for candidate in candidates + fallbacks {
                guard let url = URL(string: candidate),
                      let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) != false,
                      let image = NSImage(data: data), image.size.width >= 16 else { continue }
                return image
            }
        }
        return tab.favicon
    }

    // MARK: Вспомогательное

    private static func cleanName(_ raw: String, host: String) -> String {
        var name = raw.components(separatedBy: CharacterSet(charactersIn: "|—–·:")).first ?? raw
        name = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            name = host.replacingOccurrences(of: "www.", with: "")
            name = name.prefix(1).uppercased() + name.dropFirst()
        }
        return String(name.prefix(40))
    }

    private static func slug(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let cleaned = value.lowercased().unicodeScalars.map { allowed.contains($0) && $0.isASCII ? String($0) : "-" }.joined()
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

/// Список созданных приложений в Настройки → Браузер.
struct WebAppsSettingsSection: View {
    @State private var apps: [URL] = []

    var body: some View {
        Section {
            if apps.isEmpty {
                Text("Пока нет. Откройте сайт и выберите Закладки → «Добавить сайт в Dock…».")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(apps, id: \.self) { app in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                            .resizable()
                            .frame(width: 24, height: 24)
                        Text(app.deletingPathExtension().lastPathComponent)
                        Spacer()
                        Button("Открыть") { NSWorkspace.shared.openApplication(at: app, configuration: .init(), completionHandler: nil) }
                        Button(role: .destructive) {
                            try? FileManager.default.trashItem(at: app, resultingItemURL: nil)
                            apps = WebAppMaker.installedApps
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Переместить в Корзину")
                    }
                }
                Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([WebAppMaker.appsFolder]) }
            }
        } header: {
            Text("Сайты как приложения")
        } footer: {
            Text("Каждое приложение — отдельное окно с иконкой в Dock и своими входами на сайты. Ссылки на другие сайты открываются в Aircraft.")
                .foregroundStyle(.secondary)
        }
        .onAppear { apps = WebAppMaker.installedApps }
    }
}
