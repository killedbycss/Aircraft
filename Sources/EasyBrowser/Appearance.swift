import SwiftUI
import AppKit

/// Оформление окна в духе Arc: цвет (или градиент из двух цветов) тонирует панель вкладок,
/// верхнюю полосу и рамку вокруг страницы. Раньше это был мод, который красил только фон
/// сайтов и появлялся в настройках лишь после загрузки страницы — теперь это часть браузера.
enum AircraftTheme {
    static let colorKey = "themeColorHex"
    static let secondColorKey = "themeSecondColorHex"
    static let intensityKey = "themeIntensity"
    static let insetPageKey = "themeInsetPage"

    struct Preset: Identifiable {
        let id: String
        let name: String
        let first: String
        let second: String
    }

    /// Готовые сочетания. Пустая строка — без оформления (системный фон).
    static let presets: [Preset] = [
        .init(id: "none", name: "Системный", first: "", second: ""),
        .init(id: "sky", name: "Небо", first: "#6FA8FF", second: "#B7D3FF"),
        .init(id: "lavender", name: "Лаванда", first: "#9B8CFF", second: "#E3B5FF"),
        .init(id: "rose", name: "Роза", first: "#FF7A9C", second: "#FFC2A8"),
        .init(id: "peach", name: "Персик", first: "#FF9F6B", second: "#FFD68A"),
        .init(id: "lime", name: "Лайм", first: "#8EDB6A", second: "#D9F08A"),
        .init(id: "mint", name: "Мята", first: "#3CCFB4", second: "#9BE7FF"),
        .init(id: "ocean", name: "Океан", first: "#2F6BFF", second: "#22C7D6"),
        .init(id: "sunset", name: "Закат", first: "#FF5F6D", second: "#FFC371"),
        .init(id: "graphite", name: "Графит", first: "#5B6270", second: "#8A93A6"),
        .init(id: "night", name: "Ночь", first: "#1E2A78", second: "#6A3093")
    ]

    static func color(hex: String) -> Color? {
        NSColor(themeHex: hex).map(Color.init(nsColor:))
    }
}

/// Фон «хрома» окна: системный фон, поверх — тонировка темы.
struct ChromeBackground: View {
    @AppStorage(AircraftTheme.colorKey) private var first = ""
    @AppStorage(AircraftTheme.secondColorKey) private var second = ""
    @AppStorage(AircraftTheme.intensityKey) private var intensity = 0.55
    @Environment(\.colorScheme) private var scheme
    @Environment(TabManager.self) private var tabManager: TabManager

    @AppStorage(AircraftTheme.liquidGlassKey) private var glass = false

    var body: some View {
        if glass && !tabManager.isIncognito {
            GlassWindowBackground()
        } else {
            ZStack {
                Color(NSColor.windowBackgroundColor)
                if let tint {
                    tint.opacity(effectiveOpacity)
                }
            }
        }
    }

    private var tint: LinearGradient? {
        guard !tabManager.isIncognito, let a = AircraftTheme.color(hex: first) else { return nil }
        let b = AircraftTheme.color(hex: second) ?? a
        return LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// В тёмной теме тон приглушаем, чтобы текст оставался читаемым.
    private var effectiveOpacity: Double {
        let value = min(max(intensity, 0.05), 1)
        return scheme == .dark ? value * 0.45 : value * 0.6
    }
}

extension View {
    /// Фон панели вкладок и полос окна с учётом темы.
    func chromeBackground() -> some View {
        background(ChromeBackground())
    }
}

/// Настройка оформления в разделе «Внешний вид».
struct ThemePicker: View {
    @AppStorage(AircraftTheme.colorKey) private var first = ""
    @AppStorage(AircraftTheme.secondColorKey) private var second = ""
    @AppStorage(AircraftTheme.intensityKey) private var intensity = 0.55
    @AppStorage(AircraftTheme.insetPageKey) private var insetPage = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 46), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(AircraftTheme.presets) { preset in
                    Button {
                        first = preset.first
                        second = preset.second
                    } label: {
                        swatch(preset)
                    }
                    .buttonStyle(.plain)
                    .help(preset.name)
                }
            }
            HStack(spacing: 16) {
                ColorPicker("Цвет", selection: colorBinding($first), supportsOpacity: false)
                ColorPicker("Второй цвет", selection: colorBinding($second), supportsOpacity: false)
                    .disabled(first.isEmpty)
                if !second.isEmpty, second != first {
                    Button("Один цвет") { second = first }
                        .buttonStyle(.link)
                }
            }
            HStack {
                Text("Насыщенность")
                Slider(value: $intensity, in: 0.1...1)
                    .frame(maxWidth: 220)
                    .disabled(first.isEmpty)
            }
            Toggle("Страница карточкой со скруглёнными углами", isOn: $insetPage)
        }
    }

    private func swatch(_ preset: AircraftTheme.Preset) -> some View {
        let selected = preset.first == first && (preset.second == second || preset.first.isEmpty)
        return ZStack {
            if let a = AircraftTheme.color(hex: preset.first) {
                LinearGradient(colors: [a, AircraftTheme.color(hex: preset.second) ?? a],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                Color(NSColor.windowBackgroundColor)
                Image(systemName: "circle.slash").foregroundStyle(.secondary)
            }
        }
        .frame(width: 46, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1)
        )
    }

    private func colorBinding(_ value: Binding<String>) -> Binding<Color> {
        Binding(
            get: { AircraftTheme.color(hex: value.wrappedValue) ?? .gray },
            set: { value.wrappedValue = NSColor($0).themeHex }
        )
    }
}

extension NSColor {
    convenience init?(themeHex value: String) {
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard hex.count == 6 || hex.count == 8, let number = UInt64(hex, radix: 16) else { return nil }
        let rgba = hex.count == 6 ? (number << 8) | 0xFF : number
        self.init(srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255,
                  green: CGFloat((rgba >> 16) & 0xFF) / 255,
                  blue: CGFloat((rgba >> 8) & 0xFF) / 255,
                  alpha: CGFloat(rgba & 0xFF) / 255)
    }

    var themeHex: String {
        let color = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255),
                      Int(color.blueComponent * 255))
    }
}

/// Страница «карточкой» внутри тонированного окна, как в Arc.
private struct PageCardModifier: ViewModifier {
    let edges: Edge.Set
    @AppStorage(AircraftTheme.insetPageKey) private var inset = true

    @AppStorage(AircraftTheme.liquidGlassKey) private var glass = false

    func body(content: Content) -> some View {
        if inset || glass {
            content
                .clipShape(RoundedRectangle(cornerRadius: AircraftTheme.pageCornerRadius, style: .continuous))
                .shadow(color: .black.opacity(glass ? 0.22 : 0.14), radius: glass ? 10 : 2.5, y: glass ? 3 : 0.5)
                .padding(edges, glass ? 9 : 7)
        } else {
            content
        }
    }
}

extension AircraftTheme {
    static var pageCornerRadius: CGFloat { liquidGlass ? 14 : 9 }
    static var insetPage: Bool { (UserDefaults.standard.object(forKey: insetPageKey) as? Bool ?? true) || liquidGlass }
}

extension View {
    func pageCard(_ edges: Edge.Set) -> some View {
        modifier(PageCardModifier(edges: edges))
    }
}

// MARK: - Liquid Glass

/// Режим «Liquid Glass»: окно просвечивает рабочий стол, панели и элементы управления
/// становятся стеклом macOS 26. Страницы остаются непрозрачными карточками, чтобы текст читался.
/// На macOS до 26 вместо стекла — полупрозрачные материалы.
extension AircraftTheme {
    static let liquidGlassKey = "liquidGlassMode"
    static var liquidGlass: Bool { UserDefaults.standard.bool(forKey: liquidGlassKey) }
    static var systemHasLiquidGlass: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// Тон стекла — цвет оформления, если он выбран.
    static var glassTint: Color? {
        let hex = UserDefaults.standard.string(forKey: colorKey) ?? ""
        return color(hex: hex)
    }
}

private struct GlassOrBackground<S: Shape, B: View>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    let otherwise: B
    @AppStorage(AircraftTheme.liquidGlassKey) private var glass = false

    func body(content: Content) -> some View {
        if glass {
            if #available(macOS 26, *) {
                content.glassEffect(glassStyle, in: shape)
            } else {
                content.background(.ultraThinMaterial, in: shape)
            }
        } else {
            content.background(otherwise)
        }
    }

    @available(macOS 26, *)
    private var glassStyle: Glass {
        var style = Glass.regular
        if let tint { style = style.tint(tint.opacity(0.35)) }
        if interactive { style = style.interactive() }
        return style
    }
}

extension View {
    /// В режиме Liquid Glass — стекло нужной формы, иначе — обычный фон `otherwise`.
    func glassOr<S: Shape, B: View>(_ shape: S, tint: Color? = nil, interactive: Bool = false,
                                    @ViewBuilder otherwise: () -> B) -> some View {
        modifier(GlassOrBackground(shape: shape, tint: tint, interactive: interactive, otherwise: otherwise()))
    }

    /// Стекло только в режиме Liquid Glass, иначе вид не меняется.
    func glassIfEnabled<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        glassOr(shape, tint: tint, interactive: interactive) { Color.clear }
    }
}

/// Фон окна в режиме Liquid Glass: размытый рабочий стол под окном и лёгкий тон темы.
struct GlassWindowBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
            if let tint = AircraftTheme.glassTint {
                tint.opacity(scheme == .dark ? 0.16 : 0.22)
            }
        }
    }
}

/// Переключатель в «Внешнем виде».
struct LiquidGlassToggle: View {
    @AppStorage(AircraftTheme.liquidGlassKey) private var glass = false

    var body: some View {
        Toggle(isOn: $glass) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Liquid Glass — весь интерфейс из стекла")
                Text(AircraftTheme.systemHasLiquidGlass
                     ? "Окно просвечивает рабочий стол, панели, вкладки, Spotlight и кнопки — стекло macOS. Страницы остаются непрозрачными."
                     : "Нужна macOS 26 или новее; здесь вместо стекла будут полупрозрачные материалы.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Плавающая стеклянная панель (боковая, верхняя) в режиме Liquid Glass;
/// без него — обычный фон окна с тоном темы.
private struct GlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
    let inset: CGFloat
    @AppStorage(AircraftTheme.liquidGlassKey) private var glass = false
    @Environment(TabManager.self) private var tabManager: TabManager

    func body(content: Content) -> some View {
        if glass && !tabManager.isIncognito {
            content
                .glassIfEnabled(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: AircraftTheme.glassTint)
                .padding(inset)
        } else {
            content.chromeBackground()
        }
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 18, inset: CGFloat = 8) -> some View {
        modifier(GlassPanelModifier(cornerRadius: cornerRadius, inset: inset))
    }
}

/// Делает окно прозрачным в режиме Liquid Glass (рабочий стол просвечивает сквозь стекло).
struct GlassWindowConfigurator: NSViewRepresentable {
    let enabled: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { Self.apply(enabled, to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(enabled, to: nsView.window) }
    }

    static func apply(_ enabled: Bool, to window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = !enabled
        window.backgroundColor = enabled ? .clear : .windowBackgroundColor
    }
}
