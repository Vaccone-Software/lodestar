import AppKit
import XCTest
@testable import lodestar

/// The Edit menu an accessory app installs for itself, so the field
/// editor under a key panel hears the chords every text field answers.
final class EditMenuTests: XCTestCase {
    func testTheEditMenuCarriesTheChordsATextFieldAnswers() {
        let menu = EditMenu.make()
        let paste = EditMenu.item(menu, keyEquivalent: "v")
        XCTAssertEqual(paste?.action, #selector(NSText.paste(_:)))
        XCTAssertEqual(paste?.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(EditMenu.item(menu, keyEquivalent: "c")?.action, #selector(NSText.copy(_:)))
        XCTAssertEqual(EditMenu.item(menu, keyEquivalent: "x")?.action, #selector(NSText.cut(_:)))
        XCTAssertEqual(EditMenu.item(menu, keyEquivalent: "a")?.action,
                       #selector(NSText.selectAll(_:)))
        XCTAssertEqual(EditMenu.item(menu, keyEquivalent: "z")?.action, Selector(("undo:")))
        XCTAssertNil(EditMenu.item(menu, keyEquivalent: "q"),
                     "no chord an app of ours could fire by accident")
        XCTAssertNil(EditMenu.item(menu, keyEquivalent: "w"))
    }

    func testInstallPutsItOnTheApplication() {
        EditMenu.install()
        XCTAssertNotNil(EditMenu.item(NSApp.mainMenu ?? NSMenu(), keyEquivalent: "v"))
    }
}
