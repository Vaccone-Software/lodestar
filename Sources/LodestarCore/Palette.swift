import Foundation

/// Two grounds, one colour, and the steps every surface is made of
/// (design/01-colour.md). Clay is the day, espresso the night: one matte
/// ceramic in two glazes, the same set of steps in each. Every value was
/// chosen by eye and then measured; none is derived from a formula, and the
/// tests hold the numbers (the ceiling, the floors, the family).
///
/// Nothing is pure white or pure black. Clay was warmed a few degrees toward
/// espresso until the two read as one family, and every step of both sits
/// between hue 53 and 78 with chroma under 0.025.
///
/// Each look is the other's selection: the slab, the chosen thing's step, is
/// the other look's ground, so a chosen row reads at a glance and the orange
/// keeps its one job. The slab steps are defined here and not yet drawn; the
/// slab is its own contract.
public enum Palette {
    public struct Steps: Equatable, Sendable {
        /// Behind panes; the slab by night.
        public let ground: Readability.RGB
        /// What a surface is made of.
        public let pane: Readability.RGB
        /// A key's face: the lightest thing a look draws.
        public let key: Readability.RGB
        /// The side a key stands on.
        public let side: Readability.RGB
        /// Text that is read.
        public let ink: Readability.RGB
        /// Captions, legends, what is said about a thing.
        public let quietInk: Readability.RGB
        /// The chosen thing in this look.
        public let slab: Readability.RGB
        /// The side the slab stands on.
        public let slabSide: Readability.RGB
        /// A hairline is the ink at this share, so it is the same edge on
        /// every step it crosses.
        public let hairlineAlpha: Double
        /// International Orange as this look's ground wants it: the best
        /// version of one colour for one ground, never one hex for both.
        public let orange: Readability.RGB
        /// How far a well is darkened from the pane it sits in, in OKLab
        /// lightness (design/04-material.md): a place you put something is
        /// one step below its pane.
        public let wellDrop: Double
        /// Whether a well may sink no lower than the ground: by night it
        /// stops there; by day the ground is nearer the pane than a well
        /// that reads clearly is, so the day well goes below it.
        public let wellStopsAtGround: Bool
        /// A well's edge is the ink at this share, firmer than a hairline so
        /// the well reads as one.
        public let wellEdgeAlpha: Double
        /// The edge of the well the caret is in: twice the resting share
        /// (design/12-well.md), so which well is typed in reads at a glance,
        /// with no ring, no accent and no change of fill.
        public var wellFocusedEdgeAlpha: Double { wellEdgeAlpha * 2 }
        /// Whether this is the dark look. Said by the palette, not found by
        /// comparing it with `Palette.night`, because Eye comfort resolves
        /// the same look at other levels (design/06-eye-comfort.md).
        public let isDark: Bool
        /// A well: the pane darkened by `wellDrop`, one colour, and by night
        /// never below the ground. Chroma and hue stay the pane's, so it is
        /// the same ceramic a step down.
        public let well: Readability.RGB
        /// The letter a look at an Eye comfort level has chosen for itself.
        private let chosenLetter: Readability.RGB?
        /// A letter on the orange: whichever of clay's key face and clay's
        /// ink measures higher on this look's orange, never white or black.
        /// (Worked out when asked: the palette's own steps are built from
        /// the same table the letter is chosen from.)
        public var letterOnOrange: Readability.RGB { chosenLetter ?? Palette.letter(on: orange) }

        /// A look from its steps. The well and the letter are worked out
        /// from them unless the caller has them already (a look at an Eye
        /// comfort level, whose well is the full well dimmed with the rest).
        public init(ground: Readability.RGB, pane: Readability.RGB, key: Readability.RGB, side: Readability.RGB,
                    ink: Readability.RGB, quietInk: Readability.RGB, slab: Readability.RGB,
                    slabSide: Readability.RGB, hairlineAlpha: Double, orange: Readability.RGB,
                    wellDrop: Double, wellStopsAtGround: Bool, wellEdgeAlpha: Double, isDark: Bool,
                    well: Readability.RGB? = nil, letterOnOrange: Readability.RGB? = nil) {
            self.ground = ground; self.pane = pane; self.key = key; self.side = side
            self.ink = ink; self.quietInk = quietInk; self.slab = slab; self.slabSide = slabSide
            self.hairlineAlpha = hairlineAlpha; self.orange = orange
            self.wellDrop = wellDrop; self.wellStopsAtGround = wellStopsAtGround
            self.wellEdgeAlpha = wellEdgeAlpha; self.isDark = isDark
            self.well = well ?? {
                let lowered = pane.lightness - wellDrop
                return pane.with(lightness: wellStopsAtGround ? max(ground.lightness, lowered) : lowered)
            }()
            self.chosenLetter = letterOnOrange
        }

        /// Every step of the look, for a test that holds them all to one rule.
        public var all: [Readability.RGB] {
            [ground, pane, key, side, ink, quietInk, slab, slabSide, orange]
        }
    }

    /// Espresso: the night.
    public static let night = Steps(
        ground: rgb(0x120F0C), pane: rgb(0x1D1916), key: rgb(0x2B2622), side: rgb(0x110E0C),
        ink: rgb(0xF1EBE2), quietInk: rgb(0xA99F92), slab: rgb(0xF1E8DF), slabSide: rgb(0xADA093),
        hairlineAlpha: 0.08, orange: rgb(0xFA5617), wellDrop: 0.04, wellStopsAtGround: true, wellEdgeAlpha: 0.12, isDark: true)

    /// Clay: the day.
    public static let clay = Steps(
        ground: rgb(0xEDE4DA), pane: rgb(0xF6EFE8), key: rgb(0xFCF8F4), side: rgb(0xDCCEC1),
        ink: rgb(0x1E1814), quietInk: rgb(0x66584E), slab: rgb(0x2A221D), slabSide: rgb(0x120D0A),
        hairlineAlpha: 0.10, orange: rgb(0xC83500), wellDrop: 0.05, wellStopsAtGround: false, wellEdgeAlpha: 0.14, isDark: false)

    /// Of the two letters Lodestar owns on a light ground (clay's key face
    /// and clay's ink), the one that measures higher on `fill`. Measured,
    /// never assumed: white on the night's orange is 3.3 to 1.
    public static func letter(on fill: Readability.RGB) -> Readability.RGB {
        letter(on: fill, face: clay.key, ink: clay.ink)
    }

    /// The same choice between a given face and ink, which are clay's own
    /// steps as Eye comfort has them at the level in force.
    public static func letter(on fill: Readability.RGB, face: Readability.RGB, ink: Readability.RGB) -> Readability.RGB {
        let onFace = Readability.contrast(face.luminance, fill.luminance)
        let onInk = Readability.contrast(ink.luminance, fill.luminance)
        return onFace >= onInk ? face : ink
    }

    static func rgb(_ hex: Int) -> Readability.RGB {
        Readability.RGB(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                        blue: Double(hex & 0xFF) / 255)
    }
}
