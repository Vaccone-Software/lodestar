import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The window's grammar: the overview first, a digit opens a place from
/// anywhere, escape steps back one level, letters belong to rows, and a
/// destructive verb asks for its letter twice.
final class SettingsPlacesTests: XCTestCase {
    private func controller() -> SettingsController {
        let controller = SettingsController.preview(-1)
        controller.rerender()
        return controller
    }

    func testItOpensOnTheOverviewAndADigitOpensAPlace() {
        let settings = controller()
        XCTAssertNil(settings.placeForTesting, "the overview is home")
        settings.pressForTesting("a")
        XCTAssertNil(settings.placeForTesting, "letters are rows, and the overview has none")
        settings.pressForTesting("3")
        XCTAssertEqual(settings.placeForTesting, 3, "3 is Keep")
        settings.pressForTesting("9")
        XCTAssertEqual(settings.placeForTesting, 9, "a digit works from inside a place too")
        settings.close()
    }

    func testEscapeStepsBackOneLevel() {
        let settings = controller()
        settings.pressForTesting("1")
        settings.pressForTesting("d") // Words, a page behind Write
        XCTAssertEqual(settings.pageForTesting, SettingsModel.wordsPage)
        settings.pressForTesting("escape")
        XCTAssertNil(settings.pageForTesting)
        XCTAssertEqual(settings.placeForTesting, 1, "back to the place it was opened from")
        settings.pressForTesting("escape")
        XCTAssertNil(settings.placeForTesting, "back to the overview")
        settings.close()
    }

    func testWordsReturnsToWhicheverPlaceOpenedIt() {
        let settings = controller()
        settings.pressForTesting("4")
        settings.pressForTesting("d")
        XCTAssertEqual(settings.pageForTesting, SettingsModel.wordsPage)
        settings.pressForTesting("escape")
        XCTAssertEqual(settings.placeForTesting, 4, "Speak, not Write")
        settings.close()
    }

    func testADeleteAsksForItsLetterTwice() {
        let settings = controller()
        var performed: [String] = []
        settings.perform = { performed.append($0) }
        settings.pressForTesting("9")
        settings.pressForTesting("h")
        XCTAssertEqual(performed, [], "the first press only asks")
        settings.pressForTesting("b")
        XCTAssertEqual(performed, [], "any other key lets the ask go")
        settings.pressForTesting("h")
        settings.pressForTesting("h")
        XCTAssertEqual(performed, ["delete-logbook"])
        settings.close()
    }

    func testTheScopedDoorOpensThePlaceForTheSurface() {
        let settings = controller()
        settings.openForTesting(place: "Speak")
        XCTAssertEqual(settings.placeForTesting, 4)
        settings.openForTesting(place: nil)
        XCTAssertNil(settings.placeForTesting, "nothing in front, the overview")
        settings.close()
    }
}
