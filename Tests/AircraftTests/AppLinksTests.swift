import XCTest
@testable import aircraft

final class AppLinksTests: XCTestCase {
    private func target(_ string: String) -> String? { AppLinks.appTarget(forWeb: URL(string: string)!)?.absoluteString }

    func testZoomMeetingLinks() {
        XCTAssertEqual(target("https://us02web.zoom.us/j/8765432100?pwd=abc"),
                       "zoommtg://us02web.zoom.us/join?action=join&confno=8765432100&pwd=abc")
        XCTAssertEqual(target("https://zoom.us/j/123"), "zoommtg://zoom.us/join?action=join&confno=123")
        XCTAssertNil(target("https://zoom.us/pricing"))
    }

    func testOtherApps() {
        XCTAssertEqual(target("https://t.me/durov"), "tg://resolve?domain=durov")
        XCTAssertEqual(target("https://t.me/durov/42"), "tg://resolve?domain=durov&post=42")
        XCTAssertEqual(target("https://t.me/+AbCd"), "tg://join?invite=AbCd")
        XCTAssertEqual(target("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"), "spotify:track:4uLU6hMCjMI75M1A2tKUQC")
        XCTAssertEqual(target("https://discord.gg/swift"), "discord://-/invite/swift")
        XCTAssertEqual(target("https://www.figma.com/design/KEY123/Name"), "figma://file/KEY123")
        XCTAssertNil(target("https://example.com/j/123"))
    }

    func testExternalSchemes() {
        XCTAssertTrue(AppLinks.isExternal(URL(string: "zoommtg://zoom.us/join?confno=1")!))
        XCTAssertTrue(AppLinks.isExternal(URL(string: "mailto:a@b.c")!))
        XCTAssertFalse(AppLinks.isExternal(URL(string: "https://zoom.us")!))
        XCTAssertFalse(AppLinks.isExternal(URL(string: "about:blank")!))
    }
}
