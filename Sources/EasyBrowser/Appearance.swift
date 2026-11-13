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

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
            if let tint {
                tint.opacity(effectiveOpacity)
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

    func body(content: Content) -> some View {
        if inset {
            content
                .clipShape(RoundedRectangle(cornerRadius: AircraftTheme.pageCornerRadius, style: .continuous))
                .shadow(color: .black.opacity(0.14), radius: 2.5, y: 0.5)
                .padding(edges, 7)
        } else {
            content
        }
    }
}

extension AircraftTheme {
    static let pageCornerRadius: CGFloat = 9
    static var insetPage: Bool { UserDefaults.standard.object(forKey: insetPageKey) as? Bool ?? true }
}

extension View {
    func pageCard(_ edges: Edge.Set) -> some View {
        modifier(PageCardModifier(edges: edges))
    }
}
