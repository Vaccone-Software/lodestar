import XCTest
@testable import LodestarCore

/// design/01-colour.md, held: the ceiling, every floor in the measured
/// contrast table, the one family, and the letter on the orange.
final class PaletteTests: XCTestCase {
    private func contrast(_ a: Readability.RGB, _ b: Readability.RGB) -> Double {
        Readability.contrast(a.luminance, b.luminance)
    }

    private let looks: [(name: String, steps: Palette.Steps, other: Palette.Steps)] = [
        ("clay", Palette.clay, Palette.night), ("espresso", Palette.night, Palette.clay),
    ]

    func testTheStepsAreTheContractsHex() {
        let clay = Palette.clay, night = Palette.night
        XCTAssertEqual([clay.ground, clay.pane, clay.key, clay.side, clay.ink, clay.quietInk, clay.slab, clay.slabSide],
                       [0xEDE4DA, 0xF6EFE8, 0xFCF8F4, 0xDCCEC1, 0x1E1814, 0x66584E, 0x2A221D, 0x120D0A].map(Palette.rgb))
        XCTAssertEqual([night.ground, night.pane, night.key, night.side, night.ink, night.quietInk, night.slab, night.slabSide],
                       [0x120F0C, 0x1D1916, 0x2B2622, 0x110E0C, 0xF1EBE2, 0xA99F92, 0xF1E8DF, 0xADA093].map(Palette.rgb))
        XCTAssertEqual(clay.hairlineAlpha, 0.10)
        XCTAssertEqual(night.hairlineAlpha, 0.08)
    }

    /// The ceiling: nothing is pure white or pure black, and no step is
    /// lighter than 0.99 or darker than 0.15 in OKLab lightness.
    func testNoStepBreaksTheCeiling() {
        let white = Readability.RGB(red: 1, green: 1, blue: 1), black = Readability.RGB(red: 0, green: 0, blue: 0)
        for (name, steps, _) in looks {
            for step in steps.all {
                XCTAssertNotEqual(step, white, "\(name): no pure white")
                XCTAssertNotEqual(step, black, "\(name): no pure black")
                XCTAssertLessThanOrEqual(step.lightness, 0.99, "\(name): \(step) is too light")
                XCTAssertGreaterThanOrEqual(step.lightness, 0.15, "\(name): \(step) is too dark")
            }
        }
        XCTAssertEqual(Palette.clay.pane.lightness, 0.956, accuracy: 0.01, "a day pane sits near 0.95")
        XCTAssertEqual(Palette.night.pane.lightness, 0.217, accuracy: 0.01, "a night pane sits near 0.22")
    }

    /// One warm family: every step but the orange sits between hue 53 and
    /// 78 with chroma under 0.025, and a step and its counterpart in the
    /// other look share a hue within about 20 degrees (the ink pair is 22.6, so the test
    /// allows 25).
    func testTheTwoLooksAreOneWarmFamily() {
        for (name, steps, other) in looks {
            let neutrals: [KeyPath<Palette.Steps, Readability.RGB>] =
                [\.ground, \.pane, \.key, \.side, \.ink, \.quietInk, \.slab, \.slabSide]
            for path in neutrals {
                let step = steps[keyPath: path]
                XCTAssertTrue((53...78).contains(step.hue.rounded()), "\(name): hue \(step.hue)")
                XCTAssertLessThan(step.chroma, 0.025, "\(name): chroma \(step.chroma)")
                XCTAssertLessThanOrEqual(abs(step.hue - other[keyPath: path].hue), 25, "\(name): about 20 degrees, ink is 22.6")
            }
        }
    }

    /// Every pair in the contract's measured table, within 0.05 of the
    /// number written there, and over the floor its role needs.
    func testEveryPairHoldsItsMeasuredContrastAndFloor() {
        let table: [String: (clay: Double, espresso: Double)] = [
            "ink on ground": (13.97, 16.12), "ink on pane": (15.41, 14.73), "ink on key": (16.62, 12.63),
            "quiet ink on ground": (5.44, 7.33), "quiet ink on pane": (6.00, 6.70), "quiet ink on key": (6.47, 5.75),
            "orange on pane": (4.65, 5.33), "orange on key": (5.01, 4.57),
            "other look's ink on slab": (13.18, 14.51), "other look's quiet on slab": (5.99, 5.65),
            "orange on slab": (4.76, 4.38),
        ]
        for (name, steps, other) in looks {
            let measured: [String: Double] = [
                "ink on ground": contrast(steps.ink, steps.ground), "ink on pane": contrast(steps.ink, steps.pane),
                "ink on key": contrast(steps.ink, steps.key),
                "quiet ink on ground": contrast(steps.quietInk, steps.ground),
                "quiet ink on pane": contrast(steps.quietInk, steps.pane),
                "quiet ink on key": contrast(steps.quietInk, steps.key),
                "orange on pane": contrast(steps.orange, steps.pane), "orange on key": contrast(steps.orange, steps.key),
                // On the slab the things inside take the slab's look.
                "other look's ink on slab": contrast(other.ink, steps.slab),
                "other look's quiet on slab": contrast(other.quietInk, steps.slab),
                "orange on slab": contrast(other.orange, steps.slab),
            ]
            for (pair, expected) in table {
                let want = name == "clay" ? expected.clay : expected.espresso
                XCTAssertEqual(measured[pair]!, want, accuracy: 0.05, "\(name): \(pair)")
            }
            // The floors: text read at length 7, other text 4.5, a fill 3.
            XCTAssertGreaterThanOrEqual(measured["ink on ground"]!, 7, "\(name)")
            XCTAssertGreaterThanOrEqual(measured["ink on pane"]!, 7, "\(name)")
            XCTAssertGreaterThanOrEqual(measured["ink on key"]!, 7, "\(name)")
            for pair in ["quiet ink on ground", "quiet ink on pane", "quiet ink on key", "orange on pane",
                         "orange on key", "other look's ink on slab", "other look's quiet on slab"] {
                XCTAssertGreaterThanOrEqual(measured[pair]!, 4.5, "\(name): \(pair)")
            }
            XCTAssertGreaterThanOrEqual(measured["orange on slab"]!, 3, "\(name): a fill that carries meaning")
        }
    }

    func testTheOrangeIsOnePerLook() {
        XCTAssertEqual(Palette.night.orange, Palette.rgb(0xFA5617))
        XCTAssertEqual(Palette.clay.orange, Palette.rgb(0xC83500))
        XCTAssertEqual(Palette.night.orange.lightness, 0.670, accuracy: 0.005)
        XCTAssertEqual(Palette.clay.orange.lightness, 0.550, accuracy: 0.005)
        XCTAssertEqual(Palette.night.orange.hue, 38, accuracy: 1)
        XCTAssertEqual(Palette.clay.orange.hue, 36, accuracy: 1)
    }

    /// A letter on the orange is whichever of clay's key face and clay's
    /// ink measures higher on the fill, and clears 4.5 to 1.
    func testTheLetterOnTheOrangeIsTheOneThatMeasuresHigher() {
        let face = Palette.clay.key, ink = Palette.clay.ink
        XCTAssertEqual(Palette.clay.letterOnOrange, face, "the key face on clay's orange")
        XCTAssertEqual(Palette.night.letterOnOrange, ink, "the ink on night's orange")
        for (name, steps, _) in looks {
            let chosen = steps.letterOnOrange, other = chosen == face ? ink : face
            XCTAssertGreaterThan(contrast(chosen, steps.orange), contrast(other, steps.orange), name)
            XCTAssertGreaterThanOrEqual(contrast(chosen, steps.orange), 4.5, name)
        }
        XCTAssertEqual(contrast(Palette.clay.letterOnOrange, Palette.clay.orange), 5.01, accuracy: 0.05)
        XCTAssertEqual(contrast(Palette.night.letterOnOrange, Palette.night.orange), 5.36, accuracy: 0.05)
        XCTAssertLessThan(contrast(Readability.RGB(red: 1, green: 1, blue: 1), Palette.night.orange), 3.5,
                          "white on night's orange is why the rule measures")
        // Any fill, by measure: a pale one takes the ink, a deep one the face.
        XCTAssertEqual(Palette.letter(on: Palette.clay.slab), face)
        XCTAssertEqual(Palette.letter(on: Palette.night.slab), ink)
    }
}
