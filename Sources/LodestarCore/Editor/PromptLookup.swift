import Foundation

/// The guess a proofreading model is checked against: its own input.
///
/// A corrected sentence is the sentence again, nearly every token of it,
/// and a model writing it out one token at a time spends most of its
/// answer copying. So the tokens the input says come next are offered as a
/// guess, and the model reads the guess in one step, which costs about
/// what one token costs: every guessed token it would have written itself
/// is kept, the first it would not have written is replaced by the one it
/// would, and the answer is token for token the one it gives without
/// guessing. Where the answer leaves the input (a word fixed, a capital,
/// a full stop added) the guess is found again from the last tokens
/// written, so the copying after a fix is guessed too.
public enum PromptLookup {
    /// The longest run of written tokens looked for in the input.
    public static let longestMatch = 3

    /// What the input says follows `written`, at most `limit` tokens.
    /// Nothing written yet: the input's beginning. Otherwise the input
    /// after the longest run (up to `longestMatch`) of the last tokens
    /// written that it holds, and where it holds that run more than once,
    /// the place nearest to how far the answer has come, since an answer
    /// keeps close to its input. Empty when the input holds none of them.
    public static func draft(after written: [Int], in source: [Int], limit: Int) -> [Int] {
        guard limit > 0, !source.isEmpty else { return [] }
        guard !written.isEmpty else { return Array(source.prefix(limit)) }
        for n in stride(from: min(longestMatch, written.count), through: 1, by: -1) {
            let tail = Array(written.suffix(n))
            var best: Int?
            var i = 0
            while i + n < source.count {
                if source[i] == tail[0], Array(source[i..<(i + n)]) == tail {
                    let end = i + n
                    if best.map({ abs(end - written.count) < abs($0 - written.count) }) ?? true { best = end }
                }
                i += 1
            }
            if let best { return Array(source[best..<min(source.count, best + limit)]) }
        }
        return []
    }

    /// How many of `guess` the model would have written itself: `predicted`
    /// holds the model's own choice after the token before the guess and
    /// after each guessed token, so the guess stands while the two agree.
    public static func accepted(_ guess: [Int], predicted: [Int]) -> Int {
        var count = 0
        while count < guess.count, count < predicted.count, predicted[count] == guess[count] { count += 1 }
        return count
    }
}
