import Foundation

/// The words the draft's models are told: the second ear leans toward
/// them and the intent pass keeps them as written. A short list beats a
/// long one (measured: 23 names did better than 200 terms, at half the
/// time), so only so many go, and the list `draft.words` keeps is
/// alphabetical, so past the cap the ones dropped were the ones that
/// start with the later letters, whatever the speaker had been saying.
public enum DraftVocabulary {
    /// The most words the models are told.
    public static let cap = 30

    /// At most `cap` of `words`: those used or learned lately first, most
    /// recent first, then the rest in the order they were given. While
    /// every word fits, the list is exactly what it was, so nothing
    /// changes for a speaker with a short list (and a prompt that has not
    /// changed is not read again).
    public static func told(_ words: [String], recent: [String], cap: Int = DraftVocabulary.cap) -> [String] {
        guard words.count > cap else { return words }
        let known = Set(words)
        var chosen: [String] = []
        var seen = Set<String>()
        for word in recent where known.contains(word) && seen.insert(word).inserted {
            chosen.append(word)
            if chosen.count == cap { return chosen }
        }
        for word in words where seen.insert(word).inserted {
            chosen.append(word)
            if chosen.count == cap { break }
        }
        return chosen
    }
}

/// Which of the speaker's words were used or learned lately, most recent
/// first. Kept in memory for the life of the process; nothing is written.
public struct RecentWords: Equatable, Sendable {
    public private(set) var order: [String] = []
    /// More than the models are ever told, so a word still in the list
    /// when it falls out of the first thirty has somewhere to come back from.
    public static let kept = 100

    public init() {}

    /// `words` were just used, in the order they were said: the last of
    /// them is the most recent.
    public mutating func touch(_ words: [String]) {
        guard !words.isEmpty else { return }
        var seen = Set<String>()
        let fresh = words.reversed().filter { seen.insert($0).inserted }
        order = fresh + order.filter { !seen.contains($0) }
        if order.count > Self.kept { order.removeLast(order.count - Self.kept) }
    }
}
