import Foundation

/// The caption grammar: one line of facts about a thing, in one fixed
/// order — what it is, where it came from, when — joined by a middle
/// dot, no terminal punctuation. A card's foot, the draft's register
/// note, and anything else that states facts in small type is composed
/// here, so every caption in the app reads the same way. Legends (key
/// then label, four spaces apart) and flashes (a glyph then a fragment)
/// are the other two grammars, and are not captions.
public enum Caption {
    public static let separator = " · "

    /// Empty and missing parts fall away, so a caller lists what might
    /// be known and the line says what is.
    public static func line(_ parts: [String?]) -> String {
        parts.compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: separator)
    }
}
