import AppKit
import SwiftUI

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

// MARK: - Полноэкранный режим

/// В полноэкранном режиме macOS по наведению к верху экрана выдвигает меню, а вместе с ним —
/// заголовок окна со «светофором», который ложится поверх панели вкладок. Меню оставляем,
/// а системный заголовок в полноэкранном режиме прячем совсем: кнопки окна стоят на самой
/// панели вкладок (`WindowControlsSlot`).
@MainActor
enum FullScreenChrome {
    /// Вызывается регулярно — на случай, если AppKit вернёт заголовок при показе меню.
    static func setSystemTitlebarHidden(_ hidden: Bool, in window: NSWindow) {
        let hidden = hidden && window.styleMask.contains(.fullScreen)
        // В полноэкранном режиме заголовок с кнопками живёт в отдельном дочернем окне: прячем
        // его содержимое и пропускаем клики сквозь него к панели вкладок. Через
        // `standardWindowButton` его не найти — в полноэкранном режиме AppKit возвращает
        // нашу же кнопку с панели вкладок.
        for child in window.childWindows ?? [] where String(describing: type(of: child)).contains("FullScreen") {
            if let content = child.contentView, content.isHidden != hidden { content.isHidden = hidden }
            if child.ignoresMouseEvents != hidden { child.ignoresMouseEvents = hidden }
        }
    }
}

private struct WindowIsFullScreenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Окно с этим видом сейчас в полноэкранном режиме (ставит `WorkspaceView`).
    var windowIsFullScreen: Bool {
        get { self[WindowIsFullScreenKey.self] }
        set { self[WindowIsFullScreenKey.self] = newValue }
    }
}

/// Место под кнопки окна на панели вкладок. В обычном окне пустое — там стоят кнопки
/// из заголовка окна (`WindowButtonLayout`); в полноэкранном системный заголовок спрятан,
/// поэтому здесь стоят такие же системные кнопки, созданные отдельно.
/// `onlyInFullScreen` — в обычном окне места не занимать (панель справа).
struct WindowControlsSlot: View {
    var width: CGFloat
    var height: CGFloat? = nil
    var onlyInFullScreen = false
    @Environment(\.windowIsFullScreen) private var isFullScreen

    var body: some View {
        if isFullScreen || !onlyInFullScreen {
            ZStack {
                if isFullScreen {
                    NativeWindowButtons()
                }
            }
            .frame(width: width, height: height)
        }
    }
}

/// Системные «закрыть / свернуть / развернуть» (`NSWindow.standardWindowButton(_:for:)`) —
/// те же кнопки, что в заголовке: вид, подсветка неактивного окна, действия. Зелёная выводит
/// из полноэкранного режима, «свернуть» в нём неактивна, как у системы.
private struct NativeWindowButtons: NSViewRepresentable {
    func makeNSView(context: Context) -> ButtonGroupView { ButtonGroupView() }

    func updateNSView(_ nsView: ButtonGroupView, context: Context) {
        nsView.needsLayout = true
    }

    /// Контейнер кнопок. `_mouseInGroup:` спрашивают сами кнопки, чтобы показать значки
    /// (×, −, стрелки) при наведении на всю группу — как в заголовке окна.
    final class ButtonGroupView: NSView {
        private let buttons: [NSButton]
        private var mouseInside = false

        /// Отступы кнопок друг от друга — как их раскладывает сама macOS в заголовке окна
        /// (в macOS 26 шаг 23 pt). Берём из невидимого окна, чтобы совпадало с любой версией.
        private static let offsets: [CGFloat] = {
            let probe = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: true)
            probe.contentView?.superview?.layoutSubtreeIfNeeded()
            let xs = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { probe.standardWindowButton($0)?.frame.minX }
            guard xs.count == 3, xs[2] > xs[0] else { return [0, 23, 46] }
            return xs.map { $0 - xs[0] }
        }()

        override init(frame: NSRect) {
            let mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullScreen]
            buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
                .compactMap { NSWindow.standardWindowButton($0, for: mask) }
            super.init(frame: frame)
            buttons.forEach(addSubview)
            buttons.dropFirst().first?.isEnabled = false   // свернуть полноэкранное окно нельзя
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var intrinsicContentSize: NSSize {
            NSSize(width: (Self.offsets.last ?? 46) + (buttons.last?.frame.width ?? 14), height: buttons.first?.frame.height ?? 14)
        }

        override func layout() {
            super.layout()
            let size = intrinsicContentSize
            let originX = ((bounds.width - size.width) / 2).rounded()
            for (index, button) in buttons.enumerated() {
                button.setFrameOrigin(NSPoint(x: originX + Self.offsets[min(index, Self.offsets.count - 1)],
                                              y: ((bounds.height - button.frame.height) / 2).rounded()))
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { setMouseInside(true) }
        override func mouseExited(with event: NSEvent) { setMouseInside(false) }

        private func setMouseInside(_ value: Bool) {
            mouseInside = value
            buttons.forEach { $0.needsDisplay = true }
        }

        @objc func _mouseInGroup(_ button: NSButton) -> Bool { mouseInside }
    }
}
