import SwiftUI

/// Общие визуальные роли навигации Aircraft. Цвета разрешаются в теме текущего окна.
enum BrowserDesign {
    enum Surface {
        static let hover = Color.primary.opacity(0.06)
        static let field = Color.primary.opacity(0.07)
        static let fieldHover = Color.primary.opacity(0.10)
        static let current = Color.primary.opacity(0.12)
        static let selection = Color.accentColor.opacity(0.18)

        static func tab(active: Bool, hovered: Bool, selected: Bool = false) -> Color {
            if selected { return selection }
            if active { return current }
            return hovered ? hover : .clear
        }
    }

    enum Shape {
        static let control = RoundedRectangle(cornerRadius: 6, style: .continuous)
        static let row = RoundedRectangle(cornerRadius: 8, style: .continuous)
        static let field = RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    enum TypeRole {
        static func title(scale: CGFloat, large: Bool = false, emphasized: Bool = false) -> Font {
            .system(size: (large ? 14 : 12) * scale, weight: emphasized ? .semibold : .regular)
        }

        static func detail(scale: CGFloat) -> Font { .system(size: 10 * scale) }
    }

    enum Space {
        static let iconGap: CGFloat = 8
        static let rowInset: CGFloat = 10
        static let treeIndent: CGFloat = 12
    }
}
