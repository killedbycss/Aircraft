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

/// В полноэкранном режиме macOS по наведению к верху экрана выдвигает меню вместе с заголовком
/// окна и его кнопками — они ложатся поверх панели вкладок, и до вкладок не дотянуться.
/// Поэтому в полноэкранном окне прячем меню совсем, а кнопки окна рисуем сами,
/// прямо на панели вкладок (`WindowControlsSlot`).
@MainActor
enum FullScreenChrome {
    private static var observers: [NSObjectProtocol] = []

    static func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated { hideMenuBarIfNeeded(window) }
            })
        }
    }

    private static func hideMenuBarIfNeeded(_ window: NSWindow?) {
        guard let window, window.styleMask.contains(.fullScreen) else { return }
        let options = NSApp.presentationOptions
        guard options.contains(.fullScreen), !options.contains(.hideMenuBar) else { return }
        // .hideMenuBar допустим только вместе с .hideDock.
        NSApp.presentationOptions = options.subtracting([.autoHideMenuBar, .autoHideDock]).union([.hideDock, .hideMenuBar])
    }
}

/// Место под кнопки окна на панели вкладок. В обычном окне пустое — там стоят системные
/// кнопки (`WindowButtonLayout`); в полноэкранном — свои кнопки, системные там недоступны.
struct WindowControlsSlot: View {
    var width: CGFloat
    var height: CGFloat? = nil
    @State private var window: NSWindow?
    @State private var isFullScreen = false

    var body: some View {
        ZStack {
            if isFullScreen, let window {
                WindowControlButtons(window: window)
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

/// Закрыть / свернуть / выйти из полноэкранного режима — как системный «светофор».
/// Свернуть полноэкранное окно macOS не даёт, поэтому средняя кнопка неактивна, как у системы.
private struct WindowControlButtons: View {
    let window: NSWindow
    @State private var hovering = false
    @State private var isKey = true

    var body: some View {
        HStack(spacing: 8) {
            light(Color(red: 1.0, green: 0.37, blue: 0.34), symbol: "xmark", help: "Закрыть окно") {
                window.performClose(nil)
            }
            light(nil, symbol: "minus", help: "Свернуть недоступно в полноэкранном режиме") {}
                .disabled(true)
            light(Color(red: 0.16, green: 0.78, blue: 0.25), symbol: "arrow.down.right.and.arrow.up.left",
                  help: "Выйти из полноэкранного режима") {
                window.toggleFullScreen(nil)
            }
        }
        .onHover { hovering = $0 }
        .onAppear { isKey = window.isKeyWindow }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification, object: window)) { _ in isKey = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: window)) { _ in isKey = false }
    }

    private func light(_ color: Color?, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        let active = color != nil && (isKey || hovering)
        return Button(action: action) {
            Circle()
                .fill(active ? color! : Color.primary.opacity(0.18))
                .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                .overlay {
                    if hovering && color != nil {
                        Image(systemName: symbol)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.55))
                    }
                }
                .frame(width: 12, height: 12)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
