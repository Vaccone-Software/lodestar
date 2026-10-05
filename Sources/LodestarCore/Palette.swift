import Foundation

/// The grounds every surface stands on: two nights to choose between, and
/// clay for the light. Each is three steps of one material — the ground
/// behind everything, the pane a surface is made of, and the raised step a
/// chosen thing stands on — at the same perceptual distances (OKLCH
/// lightness +0.045, then +0.095), so a night changes in character and
/// never in how a raised row lifts.
///
/// Default is a warm grey, the colour of wet clay, so day and night are
/// the same material. Lodestone is the mineral the first compasses were
/// made of, a cold blue-grey. Both ship until one has been lived with long
/// enough to choose (October 2026); light mode is always clay.
public enum Palette {
    public enum Night: String, CaseIterable, Sendable {
        case `default`, lodestone
    }

    public struct Steps: Equatable, Sendable {
        public let ground: Readability.RGB
        public let pane: Readability.RGB
        public let raised: Readability.RGB
    }

    public static func night(_ night: Night) -> Steps {
        switch night {
        case .default:
            return Steps(ground: rgb(0x18130E), pane: rgb(0x221D19), raised: rgb(0x2E2925))
        case .lodestone:
            return Steps(ground: rgb(0x11171D), pane: rgb(0x1C2229), raised: rgb(0x2A3036))
        }
    }

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
