import AircraftLanguage
import XCTest

final class InterfaceLanguageTests: XCTestCase {
    func testCatalogsHaveMatchingKeysAndPlaceholders() throws {
        func catalog(_ code: String) throws -> [String: String] {
            let url = try XCTUnwrap(InterfaceLanguage.resources.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: code))
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
            return try XCTUnwrap(plist as? [String: String])
        }
        let english = try catalog("en")
        let russian = try catalog("ru")
        XCTAssertEqual(Set(english.keys), Set(russian.keys))
        XCTAssertEqual(english["Settings"], "Settings")
        XCTAssertEqual(russian["Settings"], "Настройки")
        for (key, value) in english {
            let tokens = { (text: String) in text.matches(of: /%[0-9]+\$@/).map { String($0.output) }.sorted() }
            XCTAssertEqual(tokens(value), tokens(russian[key] ?? ""), key)
        }
    }
}
