import Foundation

/// The rules the eye is owed, decided without AppKit so a test can ask.
public enum Readability {
    /// WCAG relative luminance of an sRGB colour, components in 0...1.
    public static func luminance(red: Double, green: Double, blue: Double) -> Double {
        func channel(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// The contrast ratio between two luminances, 1 to 21.
    public static func contrast(_ a: Double, _ b: Double) -> Double {
        let (light, dark) = a > b ? (a, b) : (b, a)
        return (light + 0.05) / (dark + 0.05)
    }

    /// One colour in sRGB, components in 0...1.
    public struct RGB: Equatable, Sendable {
        public let red: Double, green: Double, blue: Double
        public init(red: Double, green: Double, blue: Double) {
            self.red = red; self.green = green; self.blue = blue
        }
        public var luminance: Double { Readability.luminance(red: red, green: green, blue: blue) }

        /// The colour in OKLab: lightness L (0 black, 1 white) and the two
        /// opponent axes. Lightness is how light a surface looks, which is
        /// what the brightness ceiling is about; WCAG luminance is the
        /// measure for contrast.
        public var oklab: (L: Double, a: Double, b: Double) {
            func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let r = linear(red), g = linear(green), b = linear(blue)
            let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
            return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
        }
        /// OKLab lightness, 0...1.
        public var lightness: Double { oklab.L }
        /// OKLab chroma.
        public var chroma: Double { let lab = oklab; return (lab.a * lab.a + lab.b * lab.b).squareRoot() }
        /// OKLab hue in degrees, 0..<360.
        public var hue: Double {
            let lab = oklab
            let degrees = atan2(lab.b, lab.a) * 180 / .pi
            return degrees < 0 ? degrees + 360 : degrees
        }
    }

    /// The panels' grounds, as the equalizer keeps them: charcoal in
    /// dark, paper in light.
    public static let charcoal = RGB(red: 0.1, green: 0.1, blue: 0.1)
    public static let paper = RGB(red: 0.92, green: 0.92, blue: 0.92)

    /// The least contrast a mark the eye must find — a cursor, a lit
    /// letter — may have against its ground before it falls back to the
    /// text's own colour.
    public static let markFloor: Double = 3

    /// How long a flash stays: long enough to read at the pace people
    /// read, which is about a word a third of a second. A floor for the
    /// short ones, a ceiling so nothing lingers, and fifty milliseconds a
    /// character between — "saved to the card" gets the floor, a sentence
    /// about secure input gets three seconds.
    public static func flashSeconds(for text: String) -> TimeInterval {
        let floor: TimeInterval = 1.4
        let ceiling: TimeInterval = 4.0
        let extra = Double(max(0, text.count - 20)) * 0.05
        return min(ceiling, floor + extra)
    }
}
