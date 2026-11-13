import XCTest
import AppKit
@testable import aircraft

final class WindowButtonLayoutTests: XCTestCase {
    @MainActor
    func testCentersTrafficLightsInBarAndRestores() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        func frameInWindow(_ button: NSButton) -> NSRect { button.convert(button.bounds, to: nil) }
        let original = frameInWindow(close)
        let gap = frameInWindow(zoom).minX - original.minX

        WindowButtonLayout.apply(.init(barHeight: 52, leading: 20), to: window)
        let moved = frameInWindow(close)
        XCTAssertEqual(window.frame.height - moved.midY, 26, accuracy: 1, "Кнопки по центру полосы 52 pt")
        XCTAssertEqual(moved.minX, 20, accuracy: 0.5)
        XCTAssertEqual(frameInWindow(zoom).minX - moved.minX, gap, accuracy: 0.5, "Промежутки не меняются")

        WindowButtonLayout.apply(nil, to: window)
        XCTAssertEqual(frameInWindow(close).minX, original.minX, accuracy: 0.5)
        XCTAssertEqual(frameInWindow(close).midY, original.midY, accuracy: 0.5)
    }
}
