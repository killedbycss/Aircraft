import WebKit
import XCTest
@testable import aircraft

final class FilterConverterTests: XCTestCase {
    private func trigger(_ rule: [String: Any]) -> [String: Any] { rule["trigger"] as! [String: Any] }
    private func matches(_ filter: String, _ url: String) -> Bool {
        url.range(of: filter, options: [.regularExpression, .caseInsensitive]) != nil
    }

    func testDomainAnchorAndSeparator() throws {
        let filter = try XCTUnwrap(FilterConverter.urlFilter(for: "||ads.example.com^"))
        XCTAssertTrue(matches(filter, "https://ads.example.com/banner.js"))
        XCTAssertTrue(matches(filter, "https://cdn.ads.example.com:8080/x"))
        XCTAssertFalse(matches(filter, "https://ads.example.community/x"))
        XCTAssertFalse(matches(filter, "https://notads.example.com.evil/x") && !matches(filter, "https://ads.example.com/"))
    }

    func testPathAndWildcard() throws {
        let filter = try XCTUnwrap(FilterConverter.urlFilter(for: "/banner/*/ad.js^"))
        XCTAssertTrue(matches(filter, "https://site.ru/banner/123/ad.js?x=1"))
        XCTAssertTrue(matches(filter, "https://site.ru/banner/123/ad.js"))
        XCTAssertFalse(matches(filter, "https://site.ru/banner/123/ad.json"))
    }

    func testOptionsAndExceptions() {
        let result = FilterConverter.convert("""
        ! comment
        [Adblock Plus 2.0]
        ||tracker.net^$third-party,script,domain=a.com|~b.a.com
        @@||tracker.net/ok.js
        ||cdn.example^$redirect=noop.js
        @@||good.site^$document
        example.com,~sub.example.com##.ad-banner
        ##.generic-ad
        example.org#@#.generic-ad
        site.com##div:has-text(Реклама)
        yandex.*##.direct
        0.0.0.0 hosts-blocked.com
        """)
        XCTAssertEqual(result.blocks.count, 2)
        let first = trigger(result.blocks[0])
        XCTAssertEqual(first["load-type"] as? [String], ["third-party"])
        XCTAssertEqual(first["resource-type"] as? [String], ["script"])
        XCTAssertEqual(first["if-domain"] as? [String], ["*a.com"])
        XCTAssertEqual(result.exceptions.count, 2)
        // .generic-ad получает unless-domain из #@#, :has-text и $redirect пропускаются.
        let generic = result.hiding.first { ($0["action"] as! [String: Any])["selector"] as? String == ".generic-ad" }
        XCTAssertEqual(generic.map(trigger)?["unless-domain"] as? [String], ["*example.org"])
        let yandex = result.hiding.first { ($0["action"] as! [String: Any])["selector"] as? String == ".direct" }
        XCTAssertTrue((yandex.map(trigger)?["if-domain"] as? [String])?.contains("*yandex.ru") == true)
        XCTAssertEqual(result.skipped, 2)
    }

    func testRejectsUnsupportedRegex() {
        XCTAssertNil(FilterConverter.urlFilter(for: "/ads(1|2)\\.js/"))
        XCTAssertNil(FilterConverter.urlFilter(for: "/\\d{3}\\.js/"))
        XCTAssertNotNil(FilterConverter.urlFilter(for: "/banner[0-9]+\\.gif/"))
    }

    @MainActor
    func testConvertedRulesCompile() async throws {
        let result = FilterConverter.convert("""
        ||ads.example.com^
        ||x.com^$image,~third-party
        /banner/*/ad.js^
        @@||ok.example.com^
        ##.ad
        site.ru##div.promo:has(> a[href*="yabs"])
        ||popup.example^$popup
        ||malware.example^$document
        """)
        let rules = result.blocks + [FilterConverter.topFrameAllowance] + result.hiding + result.documentBlocks + result.exceptions
        let json = String(data: try JSONSerialization.data(withJSONObject: rules), encoding: .utf8)!
        let store = try XCTUnwrap(WKContentRuleListStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("conv-\(UUID())")))
        let list: WKContentRuleList? = try await withCheckedThrowingContinuation { c in
            store.compileContentRuleList(forIdentifier: "c", encodedContentRuleList: json) { l, e in
                if let e { c.resume(throwing: e) } else { c.resume(returning: l) }
            }
        }
        XCTAssertNotNil(list)
    }
}
