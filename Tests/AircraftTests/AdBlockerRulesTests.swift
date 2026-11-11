import WebKit
import XCTest
@testable import aircraft

/// WebKit отклоняет весь список, если хоть одно правило некорректно, — проверяем компиляцию.
@MainActor
final class AdBlockerRulesTests: XCTestCase {
    private func assertCompiles(_ json: String, _ name: String) async throws {
        let store = try XCTUnwrap(WKContentRuleListStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("aircraft-rule-test-\(UUID().uuidString)")))
        let list: WKContentRuleList? = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: name, encodedContentRuleList: json) { list, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: list) }
            }
        }
        XCTAssertNotNil(list)
    }

    func testSiteRulesCompile() async throws {
        try await assertCompiles(AdBlocker.siteRulesJSON(yandex: true, google: true, allowlist: ["example.com"]), "sites")
        try await assertCompiles(AdBlocker.siteRulesJSON(yandex: true, google: false, allowlist: []), "yandex")
        try await assertCompiles(AdBlocker.siteRulesJSON(yandex: false, google: true, allowlist: []), "google")
    }

    func testBaseRulesCompile() async throws {
        try await assertCompiles(AdBlocker.rulesJSON(ads: true, trackers: true, allowlist: ["example.com"]), "base")
    }

    func testPageScriptRespectsToggles() {
        let both = SiteAdRules.pageScript(yandex: true, google: true, allowlist: ["ya.ru"])
        XCTAssertTrue(both.hasPrefix(SiteAdRules.scriptMarker))
        XCTAssertTrue(both.contains("[\"ya.ru\"]"))
        XCTAssertFalse(both.contains("__"+"YANDEX__"))
        XCTAssertTrue(SiteAdRules.pageScript(yandex: false, google: true, allowlist: []).contains("var isYandex = false &&"))
    }
}
