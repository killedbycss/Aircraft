import SwiftUI
import AppKit

/// Фавиконы по сайтам: в памяти и на диске (`Favicons/<host>.png`).
/// Раньше значок жил только у загруженной вкладки, поэтому после перезапуска
/// закреплённые и усыплённые вкладки показывали серые квадраты.
@MainActor
@Observable
final class FaviconCache {
    static let shared = FaviconCache()

    /// Меняется при каждом новом значке — чтобы SwiftUI перерисовал зависящие views.
    private(set) var revision = 0
    @ObservationIgnored private var images: [String: NSImage] = [:]
    @ObservationIgnored private var colors: [String: NSColor] = [:]
    @ObservationIgnored private var missing: Set<String> = []
    @ObservationIgnored private var inFlight: Set<String> = []

    private static var folder: URL { AircraftPaths.ensure(AircraftPaths.root.appendingPathComponent("Favicons", isDirectory: true)) }

    static func key(for url: URL?) -> String? {
        guard let url, let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func file(for key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return folder.appendingPathComponent(safe + ".png")
    }

    func image(for key: String) -> NSImage? {
        if let image = images[key] { return image }
        guard !missing.contains(key) else { return nil }
        if let image = NSImage(contentsOf: Self.file(for: key)) {
            images[key] = image
            return image
        }
        missing.insert(key)
        return nil
    }

    func image(for url: URL?) -> NSImage? {
        Self.key(for: url).flatMap(image(for:))
    }

    func store(_ image: NSImage, for url: URL?) {
        guard let key = Self.key(for: url) else { return }
        images[key] = image
        colors[key] = nil
        missing.remove(key)
        revision += 1
        let target = Self.file(for: key)
        if let png = Self.pngData(image) {
            Task.detached(priority: .utility) { try? png.write(to: target, options: .atomic) }
        }
    }

    /// Нет значка ни в памяти, ни на диске — пробуем скачать с сайта (один раз за запуск).
    func fetchIfNeeded(for url: URL?) {
        guard let url, url.scheme?.hasPrefix("http") == true, let key = Self.key(for: url),
              image(for: key) == nil, inFlight.insert(key).inserted else { return }
        let base = URL(string: "\(url.scheme ?? "https")://\(url.host ?? key)")!
        Task { @MainActor in
            for path in ["/apple-touch-icon.png", "/favicon.ico"] {
                guard let candidate = URL(string: path, relativeTo: base)?.absoluteURL,
                      let (data, response) = try? await URLSession.shared.data(from: candidate),
                      (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) == true,
                      let image = NSImage(data: data), image.size.width > 0 else { continue }
                store(image, for: url)
                return
            }
        }
    }

    /// Средний насыщенный цвет значка — для обводки плиток, как в Arc.
    func dominantColor(for url: URL?, image explicit: NSImage? = nil) -> Color? {
        guard let key = Self.key(for: url) else { return nil }
        if let color = colors[key] { return Color(nsColor: color) }
        guard let image = explicit ?? image(for: key), let color = Self.averageColor(of: image) else { return nil }
        colors[key] = color
        return Color(nsColor: color)
    }

    private static func averageColor(of image: NSImage) -> NSColor? {
        let side = 16
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
        for x in 0..<side {
            for y in 0..<side {
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.5 else { continue }
                // Серые и почти белые пиксели почти не влияют на цвет.
                let maxC = max(color.redComponent, color.greenComponent, color.blueComponent)
                let minC = min(color.redComponent, color.greenComponent, color.blueComponent)
                let w = 0.05 + (maxC - minC)
                red += color.redComponent * w
                green += color.greenComponent * w
                blue += color.blueComponent * w
                weight += w
            }
        }
        guard weight > 0 else { return nil }
        return NSColor(srgbRed: red / weight, green: green / weight, blue: blue / weight, alpha: 1)
    }

    private static func pngData(_ image: NSImage) -> Data? {
        let side = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// Значок сайта: из вкладки, из кэша или буква сайта на цветной подложке.
struct FaviconImage: View {
    var url: URL?
    var image: NSImage?
    let size: CGFloat
    private var cache: FaviconCache { .shared }

    init(url: URL?, image: NSImage? = nil, size: CGFloat) {
        self.url = url
        self.image = image
        self.size = size
    }

    init(host: String, size: CGFloat) {
        self.url = URL(string: "https://" + host)
        self.size = size
    }

    var body: some View {
        let _ = cache.revision
        Group {
            if let resolved = image ?? cache.image(for: url) {
                Image(nsImage: resolved).resizable().interpolation(.high).scaledToFit()
            } else if let letter = FaviconCache.key(for: url)?.first {
                RoundedRectangle(cornerRadius: size * 0.25)
                    .fill(Color(hue: Double(FaviconCache.key(for: url)!.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }) / 360,
                                saturation: 0.45, brightness: 0.8))
                    .overlay(Text(String(letter).uppercased())
                        .font(.system(size: size * 0.6, weight: .bold, design: .rounded))
                        .foregroundStyle(.white))
            } else {
                Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) { if image == nil { cache.fetchIfNeeded(for: url) } }
    }
}
