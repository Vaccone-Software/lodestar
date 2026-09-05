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
