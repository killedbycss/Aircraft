import XCTest
@testable import aircraft

final class URLRouterTests: XCTestCase {
    func testLocalServersOpenOverHTTP() {
        let template = "https://duckduckgo.com/?q={query}"
        XCTAssertEqual(URLRouter.navigationTarget(input: ":3000", searchTemplate: template), "http://localhost:3000")
        XCTAssertEqual(URLRouter.navigationTarget(input: "localhost:5173/app", searchTemplate: template), "http://localhost:5173/app")
        XCTAssertEqual(URLRouter.navigationTarget(input: "localhost", searchTemplate: template), "http://localhost")
        XCTAssertEqual(URLRouter.navigationTarget(input: "127.0.0.1:8080", searchTemplate: template), "http://127.0.0.1:8080")
        XCTAssertEqual(URLRouter.navigationTarget(input: "myapp.localhost", searchTemplate: template), "http://myapp.localhost")
        XCTAssertEqual(URLRouter.navigationTarget(input: "192.168.1.10:8000", searchTemplate: template), "http://192.168.1.10:8000")
        XCTAssertEqual(URLRouter.navigationTarget(input: "https://localhost:3000", searchTemplate: template), "https://localhost:3000")
        XCTAssertEqual(URLRouter.navigationTarget(input: "example.com", searchTemplate: template), "https://example.com")
        XCTAssertEqual(URLRouter.navigationTarget(input: "8.8.8.8", searchTemplate: template), "https://8.8.8.8")
    }

    func testGoogleHosts() {
        XCTAssertTrue(SiteIdentity.isGoogle("www.google.com"))
        XCTAssertTrue(SiteIdentity.isGoogle("accounts.google.com"))
        XCTAssertTrue(SiteIdentity.isGoogle("google.ru"))
        XCTAssertTrue(SiteIdentity.isGoogle("www.google.co.uk"))
        XCTAssertFalse(SiteIdentity.isGoogle("google.example.org"))
        XCTAssertFalse(SiteIdentity.isGoogle("example.com"))
    }

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
