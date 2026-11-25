import XCTest
import WebKit
@testable import aircraft

@MainActor
final class SecurityBoundaryTests: XCTestCase {
    private final class Handler: NSObject, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
    }

    func testWeakHandlerDoesNotRetainTarget() {
        weak var released: Handler?
        var proxy: WeakScriptMessageHandler?
        do {
            let target = Handler()
            released = target
            proxy = WeakScriptMessageHandler(target)
            XCTAssertNotNil(proxy?.target)
        }
        XCTAssertNil(released)
        XCTAssertNil(proxy?.target)
    }

    func testModMatchRejectsBroadOrMalformedHosts() {
        XCTAssertNil(ModCatalog.validatedMatchPatterns(in: "console.log(1)"))
        XCTAssertNil(ModCatalog.validatedMatchPatterns(in: "// @match https://*/*"))
        XCTAssertNil(ModCatalog.validatedMatchPatterns(in: "// @match file://example.com/*"))
        XCTAssertNil(ModCatalog.validatedMatchPatterns(in: "// @match https://example.com.evil/*\n// @match https://*/*"))
    }

    func testModMatchAnchorsHostAndPath() throws {
        let pattern = try XCTUnwrap(ModCatalog.validatedMatchPatterns(in: "// @match https://*.example.com/app/*")?.first)
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        func matches(_ url: String) -> Bool { regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }
        XCTAssertTrue(matches("https://example.com/app/page"))
        XCTAssertTrue(matches("https://a.example.com/app/page"))
        XCTAssertFalse(matches("https://example.com.evil/app/page"))
        XCTAssertFalse(matches("http://example.com/app/page"))
        XCTAssertFalse(matches("https://example.com/other/page"))
    }

    func testAgentAuthorityAndOrigin() {
        XCTAssertTrue(AgentServer.isValidHost("127.0.0.1:7777", port: 7777))
        XCTAssertFalse(AgentServer.isValidHost("evil.test:7777", port: 7777))
        XCTAssertFalse(AgentServer.isValidHost("127.0.0.1:7777, evil.test", port: 7777))
        XCTAssertTrue(AgentServer.isLocalOrigin("http://localhost:7777", port: 7777))
        XCTAssertFalse(AgentServer.isLocalOrigin("https://localhost:7777", port: 7777))
        XCTAssertFalse(AgentServer.isLocalOrigin("http://localhost:7778", port: 7777))
    }
}
