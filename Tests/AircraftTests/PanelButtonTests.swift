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

final class PanelVisibilityTests: XCTestCase {
    func testPinAndUnpinSwitchTheHideSetting() {
        XCTAssertEqual(PanelVisibility.toggled(mode: "never", fullScreen: false), "always")
        XCTAssertEqual(PanelVisibility.toggled(mode: "always", fullScreen: false), "never")
        XCTAssertEqual(PanelVisibility.toggled(mode: "always", fullScreen: true), "never")
    }

    func testWindowedModeTogglesFromWhatIsOnScreen() {
        XCTAssertFalse(PanelVisibility.isShown(mode: "windowed", fullScreen: false))
        XCTAssertTrue(PanelVisibility.isShown(mode: "windowed", fullScreen: true))
        XCTAssertEqual(PanelVisibility.toggled(mode: "windowed", fullScreen: false), "never")
        XCTAssertEqual(PanelVisibility.toggled(mode: "windowed", fullScreen: true), "always")
    }
}
