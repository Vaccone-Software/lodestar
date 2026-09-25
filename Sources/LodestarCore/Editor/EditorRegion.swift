import Foundation

/// Which English the editor holds you to: the spell checker's dictionary,
/// and the model's instruction. Inferred from the Mac's preferred
/// languages unless chosen — a Mac set to British English starts British,
/// and a model told nothing would "correct" colour to color.
public enum EditorRegion {
    /// The English spellings macOS has dictionaries for, by config code.
    public static let choices: [(code: String, name: String)] = [
        ("en_US", "English (US)"), ("en_GB", "English (UK)"), ("en_CA", "English (Canada)"),
        ("en_AU", "English (Australia)"), ("en_NZ", "English (New Zealand)"), ("en_IN", "English (India)"),
        ("en_ZA", "English (South Africa)"), ("en_SG", "English (Singapore)"),
    ]

    /// Regions whose English has no dictionary of its own here but spells
    /// the British way.
    static let british: Set<String> = ["IE", "MT", "HK", "NG", "KE", "PK", "BD", "LK", "JM"]

    /// The first English in the Mac's preferred languages, as a code: its
    /// own region where there is a dictionary for it, the British one where
    /// its region spells that way, US English otherwise. A bare "en" takes
    /// the Mac's region.
    public static func inferred(preferredLanguages: [String] = Locale.preferredLanguages,
                                region: String? = Locale.current.region?.identifier) -> String {
        for language in preferredLanguages {
            let parts = language.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
            guard parts.first == "en" else { continue }
            let place = parts.dropFirst().first { $0.count == 2 && $0 == $0.uppercased() } ?? region
            guard let place else { return "en_US" }
            if choices.contains(where: { $0.code == "en_\(place)" }) { return "en_\(place)" }
            return british.contains(place) ? "en_GB" : "en_US"
        }
        return "en_US"
    }

    /// The config's choice, or the Mac's when it names none.
    public static func resolved(_ configured: String) -> String {
        choices.contains(where: { $0.code == configured }) ? configured : inferred()
    }

    public static func name(of code: String) -> String {
        choices.first { $0.code == code }?.name ?? code
    }

    /// The sentence the model is told about spelling, or nil for US
    /// English, which its instructions already are.
    public static func instruction(for code: String) -> String? {
        switch code {
        case "en_US": return nil
        case "en_CA": return "Use Canadian spelling, as in colour and organize; do not change it to American spelling."
        default: return "Use British spelling, as in colour and organise; do not change it to American spelling."
        }
    }
}
