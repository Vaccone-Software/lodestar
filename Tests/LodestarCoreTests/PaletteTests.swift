import XCTest
@testable import LodestarCore

/// The grounds every surface stands on: each night and clay hold the same
/// floors, so the choice between them is character and never legibility.
final class PaletteTests: XCTestCase {
    private func contrast(_ a: Readability.RGB, _ b: Readability.RGB) -> Double {
        Readability.contrast(a.luminance, b.luminance)
    }
    private let nightInk = Palette.rgb(0xF2EEE8)
    private let clayInk = Palette.rgb(0x2A2522)
    private let nearBlack = Palette.rgb(0x170A04)

    func testEveryNightCarriesTextAndALitKey() {
        for night in Palette.Night.allCases {
            let steps = Palette.night(night)
            XCTAssertGreaterThanOrEqual(contrast(nightInk, steps.pane), 13, "\(night): text on the pane")
            XCTAssertGreaterThanOrEqual(contrast(nightInk, steps.raised), 11, "\(night): text on a raised row")
            XCTAssertGreaterThanOrEqual(contrast(Readability.orangeOnCharcoal, steps.raised), Readability.markFloor,
                                        "\(night): a lit key stands off its raised row")
            XCTAssertGreaterThan(steps.raised.luminance, steps.pane.luminance)
            XCTAssertGreaterThan(steps.pane.luminance, steps.ground.luminance)
        }
    }

    func testClayCarriesTextAndTheAdaptedOrange() {
        XCTAssertGreaterThanOrEqual(contrast(clayInk, Palette.clay.pane), 13)
        XCTAssertGreaterThanOrEqual(contrast(Readability.orangeOnPaper, Palette.clay.pane), Readability.markFloor,
                                    "the clay orange clears the floor where the true colour cannot")
        XCTAssertLessThan(contrast(Readability.orangeOnCharcoal, Palette.clay.pane), Readability.markFloor)
        XCTAssertGreaterThanOrEqual(contrast(nearBlack, Readability.orangeOnPaper), 4.5, "a lit key's letter on clay")
        XCTAssertGreaterThanOrEqual(contrast(Palette.clayKeyLetter, Palette.clayKey), 7, "a resting clay key")
    }

    func testTheClayOrangeIsInternationalOrangeAStepDeeper() {
        // The same hue: red full or nearly, blue absent, green in the same
        // proportion to red as International Orange's.
        let io = Readability.orangeOnCharcoal, clay = Readability.orangeOnPaper
        XCTAssertEqual(clay.blue, 0)
        XCTAssertEqual(clay.green / clay.red, io.green / io.red, accuracy: 0.01)
        XCTAssertGreaterThan(clay.red, 0.9)
    }

    func testTheNightIsAPersonsChoiceAndDefaultsToDefault() {
        XCTAssertEqual(Config().background, .default)
        XCTAssertEqual(Palette.Night(rawValue: "lodestone"), .lodestone)
    }
}
