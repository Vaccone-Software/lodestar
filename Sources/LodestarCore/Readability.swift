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

        public var oklab: OKLab {
            func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let r = linear(red), g = linear(green), b = linear(blue)
            let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
            return OKLab(lightness: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                         a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                         b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
        }

        /// The sRGB colour of an OKLab one. A colour outside the screen's
        /// gamut gives up chroma, never hue, until it fits: a clipped
        /// channel would turn the colour as well as dim it.
        public init(_ lab: OKLab) {
            func channels(_ lab: OKLab) -> (Double, Double, Double) {
                let l = pow(lab.lightness + 0.3963377774 * lab.a + 0.2158037573 * lab.b, 3)
                let m = pow(lab.lightness - 0.1055613458 * lab.a - 0.0638541728 * lab.b, 3)
                let s = pow(lab.lightness - 0.0894841775 * lab.a - 1.2914855480 * lab.b, 3)
                return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
            }
            func inGamut(_ c: (Double, Double, Double)) -> Bool {
                let slack = -1e-9, top = 1 + 1e-9
                return c.0 >= slack && c.0 <= top && c.1 >= slack && c.1 <= top && c.2 >= slack && c.2 <= top
            }
            var lab = lab
            lab.lightness = min(1, max(0, lab.lightness))
            if !inGamut(channels(lab)) {
                var low = 0.0, high = 1.0
                let (a, b) = (lab.a, lab.b)
                for _ in 0..<30 {
                    let mid = (low + high) / 2
                    if inGamut(channels(OKLab(lightness: lab.lightness, a: a * mid, b: b * mid))) { low = mid } else { high = mid }
                }
                lab = OKLab(lightness: lab.lightness, a: a * low, b: b * low)
            }
            func encode(_ v: Double) -> Double {
                let c = min(1, max(0, v))
                return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
            }
            let (r, g, b) = channels(lab)
            self.init(red: encode(r), green: encode(g), blue: encode(b))
        }

        /// Perceptual lightness, OKLab L, 0 for black and 1 for white:
        /// what "a pane at 95 per cent" means. WCAG luminance is the
        /// measure for contrast; this one is how light a surface looks,
        /// which is what the brightness ceiling is about.
        public var lightness: Double {
            func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let r = linear(red), g = linear(green), b = linear(blue)
            let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
            return 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        }
    }

    /// A colour as the eye weighs it: OKLab lightness, and the two opponent
    /// axes whose angle is the hue and whose length is the chroma. Moving a
    /// colour along L alone changes how light it is and nothing of what
    /// colour it is, which is what easing a surface down needs.
    public struct OKLab: Equatable, Sendable {
        public var lightness: Double, a: Double, b: Double
        public init(lightness: Double, a: Double, b: Double) {
            self.lightness = lightness; self.a = a; self.b = b
        }
        public var chroma: Double { (a * a + b * b).squareRoot() }
        /// The hue angle in degrees, 0 to 360; meaningless for a grey.
        public var hue: Double {
            let degrees = atan2(b, a) * 180 / .pi
            return degrees < 0 ? degrees + 360 : degrees
        }
    }

    /// The panels' grounds, as the equalizer keeps them: charcoal in
    /// dark, paper in light.
    public static let charcoal = RGB(red: 0.1, green: 0.1, blue: 0.1)
    public static let paper = RGB(red: 0.92, green: 0.92, blue: 0.92)

    /// Lodestar's own accent: International Orange itself on the night,
    /// where it clears the mark floor with room to spare, and on clay the
    /// same hue a step deeper (#C43B00), deep enough to clear it
    /// there: the colour adapted, never replaced, because its name is part
    /// of what it means. A pair, measured, never derived at runtime.
    public static let orangeOnCharcoal = RGB(red: 1.0, green: 0.31, blue: 0.0)
    /// International Orange deepened until it reads as text on clay's
    /// pane (4.65:1, #C43B00), one accent for every use in the light look
    /// rather than a fill and a separate text colour. White letters on it
    /// read at 5.3:1, so a lit key takes white by measure.
    public static let orangeOnPaper = RGB(red: 0.769, green: 0.231, blue: 0.0)

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
