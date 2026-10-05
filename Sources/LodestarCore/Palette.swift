import Foundation

/// The grounds every surface stands on: one night, and clay for the
/// light. Each is three steps of one material — the ground behind
/// everything, the pane a surface is made of, and the raised step a chosen
/// thing stands on — at the same perceptual distances (OKLCH lightness
/// +0.045, then +0.095), so a raised row lifts the same way by day and by
/// night.
///
/// The night is a warm grey, the colour of wet clay, so day and night are
/// the same material. A second night, Lodestone, the cold blue-grey of the
/// compass stone, shipped beside it as a choice in October 2026 and was
/// retired days later: unique, and worse as a colour to live in.
public enum Palette {
    public struct Steps: Equatable, Sendable {
        public let ground: Readability.RGB
        public let pane: Readability.RGB
        public let raised: Readability.RGB
    }

    /// The night: a warm grey, the colour of wet clay.
    public static let night = Steps(ground: rgb(0x18130E), pane: rgb(0x221D19), raised: rgb(0x2E2925))

    /// The light: the clay the pictures are made of, lit by their key light.
    public static let clay = Steps(ground: rgb(0xEFE7DE), pane: rgb(0xF8EFE7), raised: rgb(0xFFFBF6))

    /// A resting key in clay is one of the pictures' dark keycaps, with a
    /// pale letter, as the Keys picture draws them.
    public static let clayKey = rgb(0x2E2926)
    public static let clayKeyLetter = rgb(0xE6DFD6)

    static func rgb(_ hex: Int) -> Readability.RGB {
        Readability.RGB(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                        blue: Double(hex & 0xFF) / 255)
    }
}
