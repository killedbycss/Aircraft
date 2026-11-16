import XCTest
@testable import aircraft

final class PanelButtonTests: XCTestCase {
    func testDecodeKeepsOrderAndDropsUnknownAndRepeats() {
        XCTAssertEqual(PanelButton.decode("downloads,nope,history,downloads"), [.downloads, .history])
    }

    func testMissingSettingMeansDefaultsButEmptyMeansNone() {
        XCTAssertEqual(PanelButton.decode(nil), PanelButton.defaults)
        XCTAssertEqual(PanelButton.decode(""), [])
    }

    func testRoundTrip() {
        let buttons: [PanelButton] = [.settings, .togglePanel, .navigation]
        XCTAssertEqual(PanelButton.decode(PanelButton.encode(buttons)), buttons)
    }
}
