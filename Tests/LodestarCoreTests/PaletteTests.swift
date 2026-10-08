import XCTest
@testable import LodestarCore

/// The grounds every surface stands on: the night and clay hold the same
/// floors, so day and night differ in light and never in legibility.
final class PaletteTests: XCTestCase {
    private func contrast(_ a: Readability.RGB, _ b: Readability.RGB) -> Double {
        Readability.contrast(a.luminance, b.luminance)
    }
    private let nightInk = Palette.rgb(0xF2EEE8)
    private let clayInk = Palette.rgb(0x2A2522)
    private let nearBlack = Palette.rgb(0x170A04)

    func testTheNightCarriesTextAndALitKey() {
        let steps = Palette.night
        XCTAssertGreaterThanOrEqual(contrast(nightInk, steps.pane), 13, "text on the pane")
        XCTAssertGreaterThanOrEqual(contrast(nightInk, steps.raised), 11, "text on a raised row")
        XCTAssertGreaterThanOrEqual(contrast(Readability.orangeOnCharcoal, steps.raised), Readability.markFloor,
                                    "a lit key stands off its raised row")
        XCTAssertGreaterThan(steps.raised.luminance, steps.pane.luminance)
        XCTAssertGreaterThan(steps.pane.luminance, steps.ground.luminance)
    }

    func testClayCarriesTextAndTheAdaptedOrange() {
        XCTAssertGreaterThanOrEqual(contrast(clayInk, Palette.clay.pane), 13)
        XCTAssertGreaterThanOrEqual(contrast(Readability.orangeOnPaper, Palette.clay.pane), Readability.markFloor,
                                    "the clay orange clears the floor where the true colour cannot")
        XCTAssertLessThan(contrast(Readability.orangeOnCharcoal, Palette.clay.pane), Readability.markFloor)
        XCTAssertGreaterThanOrEqual(contrast(Readability.orangeOnPaper, Palette.clay.pane), 4.5,
                                    "the one light accent reads as text on clay")
        XCTAssertGreaterThanOrEqual(contrast(Readability.RGB(red: 1, green: 1, blue: 1), Readability.orangeOnPaper), 4.5,
                                    "a lit key's white letter on clay")
        XCTAssertGreaterThanOrEqual(contrast(Palette.clayKeyLetter, Palette.clayKey), 7, "a resting clay key")
    }

    func testTheClayOrangeIsInternationalOrangeAStepDeeper() {
        // The same hue: red full or nearly, blue absent, green in the same
        // proportion to red as International Orange's.
        let io = Readability.orangeOnCharcoal, clay = Readability.orangeOnPaper
        XCTAssertEqual(clay.blue, 0)
        XCTAssertEqual(clay.green / clay.red, io.green / io.red, accuracy: 0.01)
        XCTAssertGreaterThan(clay.red, 0.7, "deepened, not darkened to brown")
    }

    /// The Background choice retired: a config that made it still loads,
    /// clean, and keeps nothing of it.
    func testAConfigThatChoseANightStillLoadsClean() throws {
        for night in ["lodestone", "default"] {
            var problems: [String] = []
            let tree = try Json.parse(#"{ "appearance": { "background": "\#(night)", "accent": "orange" } }"#)
            let config = Config.build(from: tree, problems: &problems)
            XCTAssertEqual(problems, [], "\(night): no warning for a retired choice")
            XCTAssertEqual(config.accent, .orange, "the rest of the section still reads")
        }
    }
}
