import AppKit

/// Положение кнопок окна («светофора»). Стандартно они прижаты к верху заголовка высотой
/// ~28 pt; когда сверху панель повыше (верхние вкладки, шапка боковой панели), ставим их
/// по центру этой панели. Для этого растягиваем контейнер заголовка до высоты панели
/// и центрируем кнопки в нём. AppKit при перекладке может вернуть кадры — поэтому
/// `apply` вызывается регулярно и меняет кадры, только если они отличаются.
@MainActor
enum WindowButtonLayout {
    struct Placement: Equatable {
        /// Высота полосы от верха окна, в которой кнопки встают по центру.
        var barHeight: CGFloat
        /// Отступ первой кнопки от левого края окна.
        var leading: CGFloat
    }

    private struct Original {
        var containerHeight: CGFloat
        var buttonX: [CGFloat]
        var buttonY: [CGFloat]
    }

    private static var originals: [ObjectIdentifier: Original] = [:]
    private static let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    /// `placement == nil` — стандартное положение.
    static func apply(_ placement: Placement?, to window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        let buttons = types.compactMap { window.standardWindowButton($0) }
        guard buttons.count == 3, let titlebar = buttons[0].superview, let container = titlebar.superview else { return }
        let key = ObjectIdentifier(window)
        if originals[key] == nil {
            originals[key] = Original(containerHeight: container.frame.height,
                                      buttonX: buttons.map(\.frame.origin.x),
                                      buttonY: buttons.map(\.frame.origin.y))
        }
        guard let original = originals[key] else { return }

        let height = max(placement?.barHeight ?? original.containerHeight, original.containerHeight)
        let windowHeight = window.frame.height
        var containerFrame = container.frame
        if abs(containerFrame.height - height) > 0.5 || abs(containerFrame.maxY - windowHeight) > 0.5 {
            containerFrame.size.height = height
            containerFrame.origin.y = windowHeight - height
            container.frame = containerFrame
        }
        if abs(titlebar.frame.height - height) > 0.5 {
            titlebar.frame = NSRect(x: titlebar.frame.minX, y: 0, width: titlebar.frame.width, height: height)
        }
        for (index, button) in buttons.enumerated() {
            let x: CGFloat
            let y: CGFloat
            if let placement {
                // Сохраняем стандартные промежутки между кнопками.
                x = placement.leading + (original.buttonX[index] - original.buttonX[0])
                y = ((placement.barHeight - button.frame.height) / 2).rounded()
                    + (titlebar.isFlipped ? 0 : height - placement.barHeight)
            } else {
                x = original.buttonX[index]
                y = original.buttonY[index] + (titlebar.isFlipped ? 0 : height - original.containerHeight)
            }
            let origin = NSPoint(x: x, y: titlebar.isFlipped ? y : y)
            if abs(button.frame.origin.x - origin.x) > 0.5 || abs(button.frame.origin.y - origin.y) > 0.5 {
                button.setFrameOrigin(origin)
            }
        }
    }

    /// Нижний край кнопок от верха окна — чтобы поставить что-то под ними.
    static func buttonsBottom(in window: NSWindow?) -> CGFloat {
        guard let window, let button = window.standardWindowButton(.closeButton) else { return 30 }
        let frame = button.convert(button.bounds, to: nil)
        return window.frame.height - frame.minY
    }

    static func forget(_ window: NSWindow) {
        originals[ObjectIdentifier(window)] = nil
    }
}
