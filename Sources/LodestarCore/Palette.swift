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

        /// A letter on the orange: whichever of clay's key face and clay's
        /// ink measures higher on this look's orange, never white or black.
        public var letterOnOrange: Readability.RGB { Palette.letter(on: orange) }

        /// Every step of the look, for a test that holds them all to one rule.
        public var all: [Readability.RGB] {
            [ground, pane, key, side, ink, quietInk, slab, slabSide, orange]
        }
    }

    /// Espresso: the night.
    public static let night = Steps(
        ground: rgb(0x120F0C), pane: rgb(0x1D1916), key: rgb(0x2B2622), side: rgb(0x110E0C),
        ink: rgb(0xF1EBE2), quietInk: rgb(0xA99F92), slab: rgb(0xF1E8DF), slabSide: rgb(0xADA093),
        hairlineAlpha: 0.08, orange: rgb(0xFA5617))

    /// Clay: the day.
    public static let clay = Steps(
        ground: rgb(0xEDE4DA), pane: rgb(0xF6EFE8), key: rgb(0xFCF8F4), side: rgb(0xDCCEC1),
        ink: rgb(0x1E1814), quietInk: rgb(0x66584E), slab: rgb(0x2A221D), slabSide: rgb(0x120D0A),
        hairlineAlpha: 0.10, orange: rgb(0xC83500))

    /// Of the two letters Lodestar owns on a light ground (clay's key face
    /// and clay's ink), the one that measures higher on `fill`. Measured,
    /// never assumed: white on the night's orange is 3.3 to 1.
    public static func letter(on fill: Readability.RGB) -> Readability.RGB {
        let face = clay.key, ink = clay.ink
        let onFace = Readability.contrast(face.luminance, fill.luminance)
        let onInk = Readability.contrast(ink.luminance, fill.luminance)
        return onFace >= onInk ? face : ink
    }

    /// What the glass is tinted toward in a look: the look's pane (the warm
    /// family, never a neutral grey) at the lightness the tint has always
    /// had, which is the measured number: a neutral 0.25 at night, 0.92 by
    /// day, tuned so the panel lands on its ground (Ceramic.swift). Only the
    /// hue and the little chroma change; the lightness is what was measured,
    /// and the material goes when the material contract replaces it.
    public static func glassTint(of look: Steps, night: Bool) -> Readability.RGB {
        let grey = night ? 0.25 : 0.92
        return look.pane.with(lightness: Readability.RGB(red: grey, green: grey, blue: grey).lightness)
    }

    static func rgb(_ hex: Int) -> Readability.RGB {
        Readability.RGB(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                        blue: Double(hex & 0xFF) / 255)
    }
}
