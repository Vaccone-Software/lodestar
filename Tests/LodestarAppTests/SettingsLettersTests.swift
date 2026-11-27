import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// Switch lists every letter and the app it opens (0.57), so a letter an
/// app no longer needs can be freed: Remove takes the chain out the way ⌘K
/// does, and the add line binds letters to an app picked from the list.
final class SettingsLettersTests: XCTestCase {
    private let switchPlace = 2

    func testRemoveFreesTheChainAsItIsPressed() {
        let settings = SettingsController()
        var removed: [[String]] = []
        settings.editLetters = { remove, _ in
            if let remove { removed.append(remove) }
            return nil
        }
        settings.renderForTesting(place: switchPlace)
        settings.removeEntryForTesting(kind: .letters, key: "b x")
        XCTAssertEqual(removed, [["b", "x"]])
        settings.close()
    }

    func testAddBindsTheTypedLettersToThePickedApp() throws {
        let settings = SettingsController()
        settings.appChoices = { [("Ghostty", "com.mitchellh.ghostty"), ("Mail", "com.apple.mail")] }
        var added: [(letters: [String], app: String)] = []
        settings.editLetters = { _, add in
            if let add { added.append(add) }
            return nil
        }
        settings.renderForTesting(place: switchPlace)
        let letters = try XCTUnwrap(settings.addInputForTesting("letters") as? NSTextField)
        let app = try XCTUnwrap(settings.addInputForTesting("letters.app") as? NSPopUpButton)
        letters.stringValue = "M 2a"
        app.selectItem(withTitle: "Mail")
        settings.addForTesting("letters")
        XCTAssertEqual(added.map(\.letters), [["m", "a"]], "letters only, lowercased, one step each")
        XCTAssertEqual(added.map(\.app), ["Mail"])
        settings.close()
    }
}
