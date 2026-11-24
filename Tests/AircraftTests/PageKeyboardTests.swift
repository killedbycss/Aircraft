import AppKit
import WebKit
import XCTest
@testable import aircraft

@MainActor
final class PageKeyboardTests: XCTestCase {
    func testHeldKeyReachesPageWithoutEscapingIntoWindow() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 180),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let root = PageKeyFallbackView(frame: window.contentLayoutRect)
        let web = WKWebView(frame: root.bounds)
        let tail = KeyRecorder()
        window.contentView = root
        root.addSubview(web)
        root.nextResponder = tail
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        web.loadHTMLString("""
            <canvas tabindex="0"></canvas><input>
            <script>
            window.events = [];
            for (const name of ['keydown','keyup']) addEventListener(name, e => {
                events.push(e.type + ':' + e.key + ':' + e.repeat);
            });
            document.querySelector('canvas').focus();
            </script>
            """, baseURL: nil)
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("Array.isArray(window.events)")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        window.makeFirstResponder(web)
        func send(_ type: NSEvent.EventType, repeated: Bool = false) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: repeated, keyCode: 13))
            window.sendEvent(event)
        }
        try send(.keyDown)
        try send(.keyDown, repeated: true)
        try send(.keyUp)
        var events: [String] = []
        for _ in 0..<100 {
            events = try await web.evaluateJavaScript("window.events") as? [String] ?? []
            if events.count >= 3 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(events, ["keydown:w:false", "keydown:w:true", "keyup:w:false"])
        XCTAssertTrue(tail.events.isEmpty)
        _ = try await web.evaluateJavaScript("document.querySelector('input').focus()")
        try send(.keyDown)
        try send(.keyUp)
        var typed = ""
        for _ in 0..<100 {
            typed = try await web.evaluateJavaScript("document.querySelector('input').value") as? String ?? ""
            if typed == "w" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(typed, "w")
    }

    func testUnclaimedShortcutsContinueUpResponderChain() throws {
        let root = PageKeyFallbackView()
        let tail = KeyRecorder()
        root.nextResponder = tail
        for (flags, code, text) in [(NSEvent.ModifierFlags.command, UInt16(13), "w"), ([], 53, "\u{1b}"),
                                    ([.numericPad, .function], 126, "\u{f700}")] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: true, keyCode: code))
            root.keyDown(with: event)
        }
        XCTAssertEqual(tail.events, [13, 53])
    }
}

private final class KeyRecorder: NSResponder {
    var events: [UInt16] = []
    override func keyDown(with event: NSEvent) { events.append(event.keyCode) }
}
