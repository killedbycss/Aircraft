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
/// заголовок окна со «светофором». Меню оставляем, а заголовок ложится поверх панели вкладок.
/// Поэтому, пока панель вкладок видна, кнопки окна стоят прямо на ней (`WindowControlsSlot`),
/// а системный заголовок невидим и пропускает клики. Когда панель скрыта — заголовок обычный,
/// чтобы кнопки окна были доступны.
@MainActor
enum FullScreenChrome {
    /// Вызывается регулярно (AppKit сам возвращает заголовку видимость при каждом показе меню).
    static func setSystemTitlebarHidden(_ hidden: Bool, in window: NSWindow) {
        let hidden = hidden && window.styleMask.contains(.fullScreen)
        // Кнопки заголовка и их контейнер — в самом окне; спрятанный вид не ловит клики.
        if let container = window.standardWindowButton(.closeButton)?.superview?.superview, container.isHidden != hidden {
            container.isHidden = hidden
        }
        // Фон выезжающего заголовка — отдельное дочернее окно.
        for child in window.childWindows ?? [] where String(describing: type(of: child)).contains("FullScreen") {
            let alpha: CGFloat = hidden ? 0 : 1
            if child.alphaValue != alpha { child.alphaValue = alpha }
            if child.ignoresMouseEvents != hidden { child.ignoresMouseEvents = hidden }
        }
    }
}

/// Место под кнопки окна на панели вкладок. В обычном окне пустое — там стоят кнопки
/// из заголовка окна (`WindowButtonLayout`); в полноэкранном заголовок уезжает вверх вместе
/// с меню, поэтому здесь стоят такие же системные кнопки, созданные отдельно.
struct WindowControlsSlot: View {
    var width: CGFloat
    var height: CGFloat? = nil
    @State private var window: NSWindow?
    @State private var isFullScreen = false

    var body: some View {
        ZStack {
            if isFullScreen {
                NativeWindowButtons(width: width)
            }
        }
        .frame(width: width, height: height)
        .background(SlotWindowReader { found in
            if window !== found { window = found }
            updateFullScreen()
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in updateFullScreen() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in updateFullScreen() }
    }

    private func updateFullScreen() {
        let value = window?.styleMask.contains(.fullScreen) ?? false
        if value != isFullScreen { isFullScreen = value }
    }
}

private struct SlotWindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}

/// Системные «закрыть / свернуть / развернуть» (`NSWindow.standardWindowButton(_:for:)`) —
/// те же кнопки, что в заголовке: вид, подсветка неактивного окна, действия. Зелёная выводит
/// из полноэкранного режима, «свернуть» в нём неактивна, как у системы.
private struct NativeWindowButtons: NSViewRepresentable {
    let width: CGFloat

    func makeNSView(context: Context) -> ButtonGroupView { ButtonGroupView() }

    func updateNSView(_ nsView: ButtonGroupView, context: Context) {
        nsView.needsLayout = true
    }

    /// Контейнер кнопок. `_mouseInGroup:` спрашивают сами кнопки, чтобы показать значки
    /// (×, −, стрелки) при наведении на всю группу — как в заголовке окна.
    final class ButtonGroupView: NSView {
        private let buttons: [NSButton]
        private var mouseInside = false
        private static let step: CGFloat = 20

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
            NSSize(width: Self.step * 2 + (buttons.last?.frame.width ?? 14), height: buttons.first?.frame.height ?? 16)
        }

        override func layout() {
            super.layout()
            let size = intrinsicContentSize
            let originX = ((bounds.width - size.width) / 2).rounded()
            for (index, button) in buttons.enumerated() {
                button.setFrameOrigin(NSPoint(x: originX + CGFloat(index) * Self.step,
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
