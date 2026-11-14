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
    @ObservationIgnored private var traitsByKey: [String: FaviconTraits] = [:]

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
        traitsByKey[key] = nil
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

    /// Форма и яркость значка: считаются один раз на сайт (или на картинку без адреса).
    func traits(of image: NSImage, url: URL?) -> FaviconTraits {
        let key = Self.key(for: url) ?? "image:\(ObjectIdentifier(image).hashValue)"
        if let cached = traitsByKey[key] { return cached }
        let traits = FaviconTraits.analyze(image)
        traitsByKey[key] = traits
        return traits
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

/// Что видно по пикселям значка.
struct FaviconTraits: Equatable {
    /// Углы непрозрачные — квадратный значок «под обрез», его скругляем.
    /// У значков с прозрачным фоном своя форма (круг, логотип), их не обрезаем.
    var fullBleed = false
    /// Тёмный значок на прозрачном фоне — пропадает на тёмной панели.
    var darkOnClear = false
    /// Белый значок на прозрачном фоне — пропадает на светлой панели.
    var lightOnClear = false

    func needsPlate(in scheme: ColorScheme) -> Bool {
        scheme == .dark ? darkOnClear : lightOnClear
    }

    static func analyze(_ image: NSImage) -> FaviconTraits {
        let side = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return .init() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        func alpha(_ x: Int, _ y: Int) -> CGFloat { rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
        let corners = [(1, 1), (side - 2, 1), (1, side - 2), (side - 2, side - 2)]
        let cornerAlpha = corners.map { alpha($0.0, $0.1) }.reduce(0, +) / CGFloat(corners.count)

        var opaque = 0
        var clear = 0
        var luminance: CGFloat = 0
        for x in 0..<side {
            for y in 0..<side {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                if color.alphaComponent < 0.2 { clear += 1; continue }
                guard color.alphaComponent > 0.5 else { continue }
                opaque += 1
                luminance += 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
            }
        }
        var traits = FaviconTraits()
        traits.fullBleed = cornerAlpha > 0.6
        guard opaque > 0 else { return traits }
        let mean = luminance / CGFloat(opaque)
        let transparentBackground = !traits.fullBleed && CGFloat(clear) / CGFloat(side * side) > 0.15
        traits.darkOnClear = transparentBackground && mean < 0.22
        traits.lightOnClear = transparentBackground && mean > 0.9
        return traits
    }
}

/// Значок сайта: из вкладки, из кэша или буква сайта на цветной подложке.
struct FaviconImage: View {
    var url: URL?
    var image: NSImage?
    let size: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    private var cache: FaviconCache { .shared }
    static let cornerRatio: CGFloat = 0.24

    init(url: URL?, image: NSImage? = nil, size: CGFloat) {
        self.url = url
        self.image = image
        self.size = size
    }

    init(host: String, size: CGFloat) {
        self.url = URL(string: "https://" + host)
        self.size = size
    }

    private var corner: CGFloat { size * Self.cornerRatio }

    var body: some View {
        let _ = cache.revision
        Group {
            if let resolved = image ?? cache.image(for: url) {
                let traits = cache.traits(of: resolved, url: url)
                let plate = traits.needsPlate(in: colorScheme)
                Image(nsImage: resolved).resizable().interpolation(.high).scaledToFit()
                    .padding(plate ? size * 0.12 : 0)
                    .frame(width: size, height: size)
                    .background {
                        if plate {
                            RoundedRectangle(cornerRadius: corner, style: .continuous)
                                .fill(colorScheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.78))
                        }
                    }
                    // Скругляем только квадратные значки «под обрез» и значки на подложке.
                    .clipShape(RoundedRectangle(cornerRadius: traits.fullBleed || plate ? corner : 0, style: .continuous))
            } else if let key = FaviconCache.key(for: url), let letter = key.first {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color(hue: Double(key.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }) / 360,
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
