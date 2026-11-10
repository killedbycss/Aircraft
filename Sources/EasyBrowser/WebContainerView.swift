import SwiftUI
import WebKit

/// NSViewRepresentable контейнер для отображения активного WKWebView.
/// КРИТИЧНО: Запрещено создавать инстансы WKWebView внутри метода makeNSView.
public struct WebContainerView: NSViewRepresentable {
    public let activeWebView: WKWebView?

    public init(activeWebView: WKWebView?) {
        self.activeWebView = activeWebView
    }

    public func makeNSView(context: Context) -> NSView {
        // Создаем исключительно пустой NSView контейнер
        let containerView = NSView()
        containerView.wantsLayer = true
        return containerView
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let activeWebView = activeWebView else {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            return
        }

        // Если активный subview уже является activeWebView, повторное переподключение не требуется
        if nsView.subviews.first === activeWebView {
            return
        }

        // Удаляем старый subview
        nsView.subviews.forEach { $0.removeFromSuperview() }

        // Привязываем новый WKWebView через Auto Layout constraints по краям контейнера
        activeWebView.translatesAutoresizingMaskIntoConstraints = false
        nsView.addSubview(activeWebView)

        NSLayoutConstraint.activate([
            activeWebView.topAnchor.constraint(equalTo: nsView.topAnchor),
            activeWebView.bottomAnchor.constraint(equalTo: nsView.bottomAnchor),
            activeWebView.leadingAnchor.constraint(equalTo: nsView.leadingAnchor),
            activeWebView.trailingAnchor.constraint(equalTo: nsView.trailingAnchor)
        ])
    }
}
