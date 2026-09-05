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
    }

    /// The panels' grounds, as the equalizer keeps them: charcoal in
    /// dark, paper in light.
    public static let charcoal = RGB(red: 0.1, green: 0.1, blue: 0.1)
    public static let paper = RGB(red: 0.92, green: 0.92, blue: 0.92)

    /// Lodestar's own accent: international orange on charcoal, where it
    /// clears the mark floor with room to spare, and a deeper orange on
    /// paper, where the true colour sits under it. A pair, measured,
    /// never a colour derived at runtime.
    public static let orangeOnCharcoal = RGB(red: 1.0, green: 0.31, blue: 0.0)
    public static let orangeOnPaper = RGB(red: 0.82, green: 0.26, blue: 0.0)

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
