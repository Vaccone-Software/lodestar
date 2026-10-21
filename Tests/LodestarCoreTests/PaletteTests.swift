import StoicJSON
import XCTest
@testable import LodestarCore

/// The grounds every surface stands on: the night and clay hold the same
/// floors, so day and night differ in light and never in legibility.
final class PaletteTests: XCTestCase {
    private func contrast(_ a: Readability.RGB, _ b: Readability.RGB) -> Double {
        Readability.contrast(a.luminance, b.luminance)
    }
    private let nearBlack = Palette.rgb(0x170A04)

    func testTheNightCarriesTextAndALitKey() {
        let steps = Palette.night
        XCTAssertGreaterThanOrEqual(contrast(steps.ink, steps.pane), 13, "text on the pane")
        XCTAssertGreaterThanOrEqual(contrast(steps.ink, steps.raised), 11, "text on a raised row")
        XCTAssertGreaterThanOrEqual(contrast(Readability.orangeOnCharcoal, steps.raised), Readability.markFloor,
                                    "a lit key stands off its raised row")
        XCTAssertGreaterThan(steps.raised.luminance, steps.pane.luminance)
        XCTAssertGreaterThan(steps.pane.luminance, steps.ground.luminance)
    }

    func testClayCarriesTextAndTheAdaptedOrange() {
        XCTAssertGreaterThanOrEqual(contrast(Palette.clay.ink, Palette.clay.pane), 13)
        XCTAssertGreaterThanOrEqual(contrast(Readability.orangeOnPaper, Palette.clay.pane), Readability.markFloor,
                                    "the clay orange clears the floor where the true colour cannot")
        XCTAssertLessThan(contrast(Readability.orangeOnCharcoal, Palette.clay.pane), Readability.markFloor)
        XCTAssertGreaterThanOrEqual(contrast(Readability.orangeOnPaper, Palette.clay.pane), 4.5,
                                    "the one light accent reads as text on clay")
        XCTAssertGreaterThanOrEqual(contrast(Readability.RGB(red: 1, green: 1, blue: 1), Readability.orangeOnPaper), 4.5,
                                    "a lit key's white letter on clay")
        XCTAssertGreaterThanOrEqual(contrast(Palette.clay.ink, Palette.clay.keyFace), 13, "a resting key's letter")
    }

    /// Each look is the other's selection: the slab is the opposite look's
    /// ground, and carries the opposite look's ink and accent, so the
    /// chosen row reads as well as the text beside it.
    func testEachLookIsTheOthersSelection() {
        let pairs = [(Palette.clay, Palette.night, Readability.orangeOnCharcoal),
                     (Palette.night, Palette.clay, Readability.orangeOnPaper)]
        for (look, other, otherOrange) in pairs {
            XCTAssertGreaterThanOrEqual(contrast(other.ink, look.slab), 11, "the other look's ink on this look's slab")
            XCTAssertGreaterThanOrEqual(contrast(other.secondary, look.slab), 4.5, "and its quiet text")
            XCTAssertGreaterThanOrEqual(contrast(otherOrange, look.slab), Readability.markFloor,
                                        "and its orange, which is the one that lights a key on the slab")
            XCTAssertGreaterThan(abs(look.slab.lightness - look.pane.lightness), 0.5, "the slab stands off the pane at a glance")
            XCTAssertGreaterThan(abs(look.slabSide.lightness - look.slab.lightness), 0.05, "and has a side you can see")
        }
        for steps in [Palette.clay, Palette.night] {
            XCTAssertGreaterThanOrEqual(contrast(steps.secondary, steps.pane), 4.5, "quiet text reads on the pane")
            XCTAssertGreaterThanOrEqual(contrast(steps.secondary, steps.raised), 4.5, "and on a key's face")
        }
    }

    /// The brightness ceiling (DESIGN, "Ceramic"): nothing Lodestar draws
    /// is pure white or pure black; day panes sit near 95 per cent and
    /// night panes near 20, in OKLab lightness (`Readability.RGB.lightness`,
    /// the measure of how light a surface looks); ink is tinted.
    func testNothingIsPureWhiteOrPureBlackAndPanesHoldTheirBand() {
        let white = Readability.RGB(red: 1, green: 1, blue: 1), black = Readability.RGB(red: 0, green: 0, blue: 0)
        for (look, steps) in [("clay", Palette.clay), ("night", Palette.night)] {
            for colour in steps.all {
                XCTAssertNotEqual(colour, white, "\(look): no pure white")
                XCTAssertNotEqual(colour, black, "\(look): no pure black")
            }
            let ink = steps.ink
            XCTAssertGreaterThan(max(ink.red, ink.green, ink.blue) - min(ink.red, ink.green, ink.blue), 0.02,
                                 "\(look): ink is tinted")
        }
        XCTAssertTrue((0.93...0.97).contains(Palette.clay.pane.lightness), "a day pane: \(Palette.clay.pane.lightness)")
        XCTAssertTrue((0.17...0.24).contains(Palette.night.pane.lightness), "a night pane: \(Palette.night.pane.lightness)")
        for orange in [Readability.orangeOnCharcoal, Readability.orangeOnPaper] {
            XCTAssertNotEqual(orange, white)
            XCTAssertNotEqual(orange, black)
        }
    }

    func testTheStepsClimbInEveryLook() {
        for steps in [Palette.clay, Palette.night] {
            XCTAssertGreaterThan(abs(steps.raised.lightness - steps.pane.lightness), 0.02)
            XCTAssertGreaterThan(abs(steps.pane.lightness - steps.ground.lightness), 0.03)
        }
        XCTAssertGreaterThan(Palette.clay.keySide.lightness, 0.8, "a key's side in clay is a deeper clay, not black")
        XCTAssertLessThan(Palette.clay.keySide.lightness, Palette.clay.keyFace.lightness - 0.05, "and visibly darker than its face")
    }

    func testTheClayOrangeIsInternationalOrangeAStepDeeper() {
        // The same hue: red full or nearly, blue absent, green in the same
        // proportion to red as International Orange's.
        let io = Readability.orangeOnCharcoal, clay = Readability.orangeOnPaper
        XCTAssertEqual(clay.blue, 0)
        XCTAssertEqual(clay.green / clay.red, io.green / io.red, accuracy: 0.01)
        XCTAssertGreaterThan(clay.red, 0.7, "deepened, not darkened to brown")
    }

    /// The Background choice retired, and the Accent after it: a config that
    /// made either still loads, clean, and keeps nothing of it.
    func testAConfigThatChoseANightStillLoadsClean() throws {
        for night in ["lodestone", "default"] {
            var problems: [String] = []
            let tree = try Json.parse(#"{ "appearance": { "background": "\#(night)", "accent": "orange" }, "scroll": { "speed": 2500 } }"#)
            let config = Config.build(from: tree, problems: &problems)
            XCTAssertEqual(problems, [], "\(night): no warning for a retired choice")
            XCTAssertEqual(config.scrollSpeed, 2500, "the rest of the file still reads")
        }
    }

    /// The retired choices are not written back: the next canonical write
    /// leaves them out, so the key is gone from the file, not only ignored,
    /// while the section's one live setting stays where it is.
    func testTheRetiredKeysAreNotWrittenBack() throws {
        let tree = try JSONDocument(
            parsing: #"{"appearance": {"accent": "orange", "background": "lodestone", "eye-comfort": false}, "scroll": {"speed": 2500}}"#,
            options: .strict).value
        let normalized = ConfigFile.schema.normalized(tree)
        XCTAssertNil(normalized.value(at: JSONPath([.key("appearance"), .key("accent")])), "the accent is dropped")
        XCTAssertNil(normalized.value(at: JSONPath([.key("appearance"), .key("background")])), "and so is the background")
        XCTAssertEqual(normalized.value(at: JSONPath([.key("appearance"), .key("eye-comfort")])), .bool(false))
        XCTAssertNotNil(normalized.value(at: JSONPath([.key("scroll"), .key("speed")])))
    }
}
