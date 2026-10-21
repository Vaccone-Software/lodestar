import Foundation

/// The grounds every surface stands on: espresso for the night, clay for
/// the light, one matte ceramic in two glazes (DESIGN, "Ceramic"). Each is
/// the same set of steps: the ground behind everything, the pane a surface
/// is made of, the raised step that is also a key's face, the side a key
/// stands on, the ink and its quieter twin, a hairline, and the slab a
/// chosen thing becomes together with its side.
///
/// The steps are chosen by eye on the canvas and then measured, not
/// derived: in OKLab lightness the day climbs from the ground to the pane
/// by +0.033 and on to the raised step by +0.025, the night by +0.046 and
/// +0.056, so a raised thing lifts by a step you can see in either look,
/// the night's wider because dark steps are read less finely. Clay is
/// warmed a few degrees toward the night, because the clay that came
/// before leaned pink beside the night's brown and the two read as two
/// families.
///
/// Nothing is pure white or pure black, and a test holds that, with the
/// panes' lightness inside a band (see `Readability.RGB.lightness`): a
/// light panel never opens into a dark evening and ink is always tinted.
///
/// Each look is the other's selection: the slab is the opposite look's ink
/// ground, an espresso slab by day and a clay one by night, so the chosen
/// row reads at a glance to every eye and stays neutral, which leaves the
/// accent its one job.
public enum Palette {
    public struct Steps: Equatable, Sendable {
        public let ground: Readability.RGB
        public let pane: Readability.RGB
        /// A raised step, and the face of a key, which is the same
        /// ceramic standing a step proud.
        public let raised: Readability.RGB
        /// The side a resting key stands on.
        public let keySide: Readability.RGB
        public let ink: Readability.RGB
        public let secondary: Readability.RGB
        /// A hairline is the ink at a fixed share, so it is the same
        /// line on every step it crosses.
        public let hairlineAlpha: Double
        /// What the chosen row becomes, and the side it stands on.
        public let slab: Readability.RGB
        public let slabSide: Readability.RGB

        /// The key's face is the raised step.
        public var keyFace: Readability.RGB { raised }

        /// Every colour of the look, for a test that holds them all to
        /// one rule.
        public var all: [Readability.RGB] {
            [ground, pane, raised, keySide, ink, secondary, slab, slabSide]
        }
    }

    /// Espresso: the night, a warm brown a little deeper than the clay it
    /// replaced, so the slab and the ink have room to stand off it.
    public static let night = Steps(
        ground: rgb(0x120F0C), pane: rgb(0x1D1916), raised: rgb(0x2B2622), keySide: rgb(0x110E0C),
        ink: rgb(0xF1EBE2), secondary: rgb(0xA99F92), hairlineAlpha: 0.08,
        slab: rgb(0xF1E8DF), slabSide: rgb(0xADA093))

    /// Clay, warmed: the light.
    public static let clay = Steps(
        ground: rgb(0xEDE4DA), pane: rgb(0xF6EFE8), raised: rgb(0xFCF8F4), keySide: rgb(0xDCCEC1),
        ink: rgb(0x1E1814), secondary: rgb(0x66584E), hairlineAlpha: 0.10,
        slab: rgb(0x2A221D), slabSide: rgb(0x120D0A))

    static func rgb(_ hex: Int) -> Readability.RGB {
        Readability.RGB(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                        blue: Double(hex & 0xFF) / 255)
    }
}
