import XCTest
@testable import aircraft

final class URLRouterTests: XCTestCase {
    func testNormalizesDomainAndTrailingSlash() {
        XCTAssertEqual(URLRouter.normalizedPrefix("  example.com/docs/ "), "example.com/docs")
    }

    func testKeepsExplicitScheme() {
        XCTAssertEqual(URLRouter.normalizedPrefix("https://example.com/base/"), "https://example.com/base")
    }

    func testRejectsInvalidPrefix() {
        XCTAssertNil(URLRouter.normalizedPrefix("not a domain"))
        XCTAssertNil(URLRouter.normalizedPrefix(""))
    }

    func testBuildsPrefixedTarget() {
        XCTAssertEqual(
            URLRouter.prefixedTarget(query: "/article", prefix: "example.com/docs/"),
            "https://example.com/docs/article"
        )
    }

    func testEmptyQueryOpensPrefixRoot() {
        XCTAssertEqual(
            URLRouter.prefixedTarget(query: "  ", prefix: "https://example.com/"),
            "https://example.com"
        )
    }

    func testURLSystemReplacesEnteredHostAndKeepsPath() {
        XCTAssertEqual(
            URLRouter.prefixedTarget(query: "username.github.io/repo", prefix: "killedbycss.github.io"),
            "https://killedbycss.github.io/repo"
        )
    }

    func testURLSystemReplacesFullURLAndKeepsPath() {
        XCTAssertEqual(
            URLRouter.prefixedTarget(query: "https://username.github.io/repo/page", prefix: "killedbycss.github.io"),
            "https://killedbycss.github.io/repo/page"
        )
    }

    func testSearchTargetReplacesSupportedPlaceholder() {
        XCTAssertEqual(
            URLRouter.searchTarget(query: "swift ui", template: "https://example.com/find?q={query}"),
            "https://example.com/find?q=swift%20ui"
        )
    }

    func testSearchTargetAddsDefaultQueryParameter() {
        XCTAssertEqual(
            URLRouter.searchTarget(query: "aircraft", template: "https://example.com/search"),
            "https://example.com/search?q=aircraft"
        )
    }

    func testNavigationTargetUsesSearchTemplateForWords() {
        XCTAssertEqual(
            URLRouter.navigationTarget(input: "hello world", searchTemplate: "https://search.example/?q=%s"),
            "https://search.example/?q=hello%20world"
        )
    }
}
