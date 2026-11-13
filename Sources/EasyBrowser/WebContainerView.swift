import SwiftUI
import WebKit

/// NSViewRepresentable контейнер для отображения активного WKWebView.
/// КРИТИЧНО: Запрещено создавать инстансы WKWebView внутри метода makeNSView.
///
/// WKWebView раскладывается фреймами (autoresizing), а не Auto Layout: встроенный
/// Web Inspector сам уменьшает фрейм страницы и кладёт свою view рядом в этот же
/// контейнер. Констрейнты растягивали бы страницу обратно поверх инспектора.
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
        // Скругление страницы-карточки: WKWebView сам по себе маску SwiftUI не всегда соблюдает.
        nsView.layer?.cornerRadius = AircraftTheme.insetPage ? AircraftTheme.pageCornerRadius : 0
        nsView.layer?.cornerCurve = .continuous
        nsView.layer?.masksToBounds = true
        guard let activeWebView = activeWebView else {
            Self.detachAll(from: nsView)
            return
        }

        // Активный WKWebView уже здесь (возможно, вместе с открытым инспектором).
        if activeWebView.superview === nsView { return }

        Self.detachAll(from: nsView)
        activeWebView.removeFromSuperview()
        activeWebView.translatesAutoresizingMaskIntoConstraints = true
        activeWebView.autoresizingMask = [.width, .height]
        activeWebView.frame = nsView.bounds
        nsView.addSubview(activeWebView)
    }

    /// Убирает всё из контейнера. Инспектор прежней вкладки закрываем, иначе
    /// её страница осталась бы ужатой, а view инспектора — оторванной.
    private static func detachAll(from container: NSView) {
        for view in container.subviews {
            if let webView = view as? WKWebView, !String(describing: type(of: webView)).contains("Inspector") {
                TabManager.closeWebInspector(of: webView)
            }
        }
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}
