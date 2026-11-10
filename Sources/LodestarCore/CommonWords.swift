import Foundation
import NaturalLanguage
import Synchronization

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
    /// The lists load once, on first use, from whichever thread asks first,
    /// so the lists, the embedding and the URL they load from share one lock.
    private struct State {
        var frequentListURL: URL?
        var frequent: [String: Int]?
        var dictionary: Set<String>?
        var vectors: NLEmbedding??
    }
    private static let state = Mutex(State())

    /// The everyday-words list, most frequent first (`packaging/common-words.txt`).
    /// Set before first use; without it every dictionary word counts as frequent.
    public static var frequentListURL: URL? {
        get { state.withLock { $0.frequentListURL } }
        set { state.withLock { $0.frequentListURL = newValue } }
    }

    /// Load both lists now, off the main thread, so the first dictation
    /// does not pay for it.
    public static func warm() { _ = isCommon("the") }

    /// Whether a word is frequent enough that, written as a name, it is
    /// more often meant as the word: "compass", "telegram", "convex" are;
    /// "lodestar", "asana", "raycast" are not. Such a name is capitalized by
    /// its context, never by its sound alone.
    public static func isFrequent(_ word: String) -> Bool {
        let w = word.lowercased()
        let table = state.withLock { state -> [String: Int] in
            if state.frequent == nil {
                var table: [String: Int] = [:]
                if let url = state.frequentListURL, let text = try? String(contentsOf: url, encoding: .utf8) {
                    for (rank, line) in text.split(separator: "\n").enumerated() { table[String(line)] = rank }
                }
                state.frequent = table
            }
            return state.frequent ?? [:]
        }
        if table.isEmpty { return isCommon(w) }
        return table[w] != nil && isCommon(w)
    }

    public static func isCommon(_ word: String) -> Bool {
        let w = word.lowercased()
        guard !w.isEmpty else { return false }
        let (inDictionary, embedding) = state.withLock { state -> (Bool, NLEmbedding?) in
            if state.dictionary == nil {
                let text = (try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8)) ?? ""
                state.dictionary = Set(text.split(separator: "\n").map(String.init))
            }
            if state.vectors == nil { state.vectors = .some(NLEmbedding.wordEmbedding(for: .english)) }
            return (state.dictionary?.contains(w) ?? false, state.vectors ?? nil)
        }
        guard inDictionary else { return false }
        guard let embedding else { return true }
        return embedding.contains(w)
    }
}
