import Foundation

extension Draft {
    /// Words the draft put on the page before their final came, and what
    /// the hand may have done to them since.
    ///
    /// A final is for the whole stretch the recognizer was working on, and
    /// the reservation only holds what had been drawn of it. Spoken words
    /// the ghost never showed arrive with the final, past the reserved
    /// ones. When the hand has edited the reserved words the final cannot
    /// replace them, but what follows them was never on the page and is
    /// the hand's to keep.
    public enum Reserved {
        /// The part of `heard` beyond the reserved words, when it begins
        /// with them. Compared by word, ignoring case and punctuation: the
        /// ghost and the final disagree about both. Nil when it does not
        /// begin with them or nothing follows, and the caller drops the
        /// final.
        ///
        /// The reservation is only text: the ghost carries no word times,
        /// so there is nothing to place the final's words by but the words.
        public static func remainder(of heard: Heard, after reserved: String) -> Heard? {
            let wanted = reserved.split(whereSeparator: \.isWhitespace).map(normalized).filter { !$0.isEmpty }
            guard !wanted.isEmpty else { return nil }
            let characters = Array(heard.text)
            var matched = 0
            var cut: Int?
            var index = 0
            while index < characters.count, cut == nil {
                while index < characters.count, characters[index].isWhitespace { index += 1 }
                let start = index
                while index < characters.count, !characters[index].isWhitespace { index += 1 }
                guard index > start else { break }
                let token = normalized(characters[start..<index])
                if token.isEmpty { continue }
                guard token == wanted[matched] else { return nil }
                matched += 1
                if matched == wanted.count { cut = index }
            }
            guard let cut else { return nil }
            let rest = String(characters[cut...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rest.isEmpty else { return nil }
            // The words keep their times when the pieces add up to the
            // text, as the recognizer's runs do; otherwise they are left off
            // rather than guessed.
            var words: [Heard.Word] = []
            if heard.words.map(\.text).joined() == heard.text {
                var position = 0
                for word in heard.words {
                    if position >= cut, !word.text.allSatisfy(\.isWhitespace) { words.append(word) }
                    position += word.text.count
                }
            }
            return Heard(rest, words: words)
        }

        /// Where the end of a reserved range stands after the hand's
        /// edits: the text as it was when the words were reserved against
        /// the text now. Everything the edit left alone moves with it, and
        /// an edit that reaches the end puts the end where the edit ends.
        public static func end(of range: Range<Int>, was before: [Character], now after: [Character]) -> Int {
            var prefix = 0
            let shorter = min(before.count, after.count)
            while prefix < shorter, before[prefix] == after[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < shorter - prefix, before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
            let end = range.upperBound
            let moved: Int
            if end <= prefix {
                moved = end
            } else if end >= before.count - suffix {
                moved = end + (after.count - before.count)
            } else {
                moved = after.count - suffix
            }
            return max(0, min(after.count, moved))
        }

        private static func normalized<S: Sequence>(_ token: S) -> String where S.Element == Character {
            String(token.filter { $0.isLetter || $0.isNumber }).lowercased()
        }
    }
}
