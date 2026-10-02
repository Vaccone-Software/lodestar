import Foundation
import NaturalLanguage

/// Whether a word is an ordinary English word, for the two questions
/// dictation asks of every word it might change: may its capital be
/// lowered (it is not a name), and may it be swapped for a name (only
/// when it is not an everyday word the speaker meant).
///
/// Ordinary means in both the system's word list (`/usr/share/dict/words`)
/// and Apple's own English word vectors (about 33,000 everyday words, on
/// every Mac): the first alone holds every obscure word ever printed, the
/// second alone holds names. Nothing is shipped or downloaded.
public enum CommonWords {
    private static let lock = NSLock()
    /// The everyday-words list, most frequent first (`packaging/common-words.txt`).
    /// Set before first use; without it every dictionary word counts as frequent.
    nonisolated(unsafe) public static var frequentListURL: URL?
    nonisolated(unsafe) private static var frequent: [String: Int]?
    nonisolated(unsafe) private static var dictionary: Set<String>?
    nonisolated(unsafe) private static var vectors: NLEmbedding??

    /// Load both lists now, off the main thread, so the first dictation
    /// does not pay for it.
    public static func warm() { _ = isCommon("the") }

    /// Whether a word is frequent enough that, written as a name, it is
    /// more often meant as the word: "compass", "telegram", "convex" are;
    /// "lodestar", "asana", "raycast" are not. Such a name is capitalized by
    /// its context, never by its sound alone.
    public static func isFrequent(_ word: String) -> Bool {
        let w = word.lowercased()
        lock.lock()
        if frequent == nil {
            var table: [String: Int] = [:]
            if let url = frequentListURL, let text = try? String(contentsOf: url, encoding: .utf8) {
                for (rank, line) in text.split(separator: "\n").enumerated() { table[String(line)] = rank }
            }
            frequent = table
        }
        let table = frequent ?? [:]
        lock.unlock()
        if table.isEmpty { return isCommon(w) }
        return table[w] != nil && isCommon(w)
    }

    public static func isCommon(_ word: String) -> Bool {
        let w = word.lowercased()
        guard !w.isEmpty else { return false }
        lock.lock()
        if dictionary == nil {
            let text = (try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8)) ?? ""
            dictionary = Set(text.split(separator: "\n").map(String.init))
        }
        if vectors == nil { vectors = .some(NLEmbedding.wordEmbedding(for: .english)) }
        let inDictionary = dictionary?.contains(w) ?? false
        let embedding = vectors ?? nil
        lock.unlock()
        guard inDictionary else { return false }
        guard let embedding else { return true }
        return embedding.contains(w)
    }
}
