import Foundation

/// The draft: text in flight toward an app. Not a file, not a buffer you
/// return to — a thing you speak or type into, that lands where your
/// cursor already is, and that leaves a clip behind whichever way it ends.
///
/// Everything decided here is decided without a microphone, a panel, or
/// a pasteboard: the buffer and its cursor, what a backspace takes, how
/// spoken text joins typed text, which words the vocabulary repairs, and
/// how the draft ends. The shell feeds it keys and recognizer results and
/// draws what it holds.
public enum Draft {
    /// Which door opened it. Speak opens listening in insert mode; edit
    /// opens silent in normal mode with the field's text pulled in.
    public enum Door: String, Equatable, Codable, Sendable {
        case speak, edit
    }

    public enum Mode: Equatable, Sendable {
        case insert, normal
    }

    /// What the last input was, because a backspace takes that grain: a
    /// character after typing, a word after speech. A transcript's unit
    /// of error is the word; a keyboard's is the character.
    public enum Grain: Equatable, Sendable {
        case typed, spoken
    }

    /// The text with a cursor in it, plus the ghost: the recognizer's
    /// volatile words, drawn after the cursor and not yet part of the
    /// text. Typed characters land at the cursor, so anything typed while
    /// a ghost stands lands *before* what is still being said.
    public struct Buffer: Equatable, Sendable {
        public private(set) var characters: [Character] = []
        public private(set) var cursor: Int = 0
        public private(set) var ghost: String = ""
        public private(set) var lastGrain: Grain?

        public init() {}

        public init(text: String, cursor: Int? = nil) {
            characters = Array(text)
            self.cursor = min(max(cursor ?? characters.count, 0), characters.count)
        }

        public var text: String { String(characters) }
        public var isEmpty: Bool { characters.isEmpty }
        public var count: Int { characters.count }

        // MARK: Input

        /// Typed characters land at the cursor.
        public mutating func type(_ typed: String) {
            guard !typed.isEmpty else { return }
            let incoming = Array(typed)
            characters.insert(contentsOf: incoming, at: cursor)
            cursor += incoming.count
            lastGrain = .typed
        }

        /// A settled recognizer result lands at the cursor, joined to what
        /// is before it by the spacing rule, and the ghost it replaces
        /// goes away.
        public mutating func settle(_ spoken: String) {
            ghost = ""
            let trimmed = Draft.cased(spoken.trimmingCharacters(in: .whitespacesAndNewlines),
                                      after: characters[..<cursor])
            guard !trimmed.isEmpty else { return }
            let joined = Draft.separator(after: characters[..<cursor], before: trimmed) + trimmed
            let incoming = Array(joined)
            characters.insert(contentsOf: incoming, at: cursor)
            cursor += incoming.count
            lastGrain = .spoken
        }

        public mutating func showGhost(_ volatile: String) {
            ghost = volatile.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public mutating func clearGhost() { ghost = "" }

        public mutating func newline() {
            characters.insert("\n", at: cursor)
            cursor += 1
            lastGrain = .typed
        }

        // MARK: Deleting

        /// The grain rule: one character if the last input was typed, one
        /// word if it was spoken. Consecutive backspaces keep the grain, so
        /// three after a sentence take three words; typing anything
        /// resets it. The ghost is never touched — it is what is still
        /// being said, and it settles on its own.
        public mutating func backspace() {
            if lastGrain == .spoken { deleteSpokenWord() } else { deleteBackward() }
        }

        /// A spoken word and the space that joined it, so the text ends
        /// clean and the next settled words join by the rule again.
        public mutating func deleteSpokenWord() {
            deleteWordBackward()
            while cursor > 0, characters[cursor - 1] == " " {
                characters.remove(at: cursor - 1)
                cursor -= 1
            }
        }

        public mutating func deleteBackward() {
            guard cursor > 0 else { return }
            characters.remove(at: cursor - 1)
            cursor -= 1
        }

        /// Trailing whitespace before the cursor, then the run of
        /// non-whitespace before that — what ⌥⌫ takes in any field.
        public mutating func deleteWordBackward() {
            guard cursor > 0 else { return }
            var start = cursor
            while start > 0, characters[start - 1].isWhitespace { start -= 1 }
            while start > 0, !characters[start - 1].isWhitespace { start -= 1 }
            characters.removeSubrange(start..<cursor)
            cursor = start
        }

        public mutating func deleteToLineEnd() {
            let end = lineEnd(from: cursor)
            guard end > cursor else { return }
            characters.removeSubrange(cursor..<end)
            lastGrain = .typed
        }

        public mutating func deleteToLineStart() {
            let start = lineStart(from: cursor)
            guard start < cursor else { return }
            characters.removeSubrange(start..<cursor)
            cursor = start
        }

        // MARK: Moving

        public mutating func moveLeft() { cursor = max(0, cursor - 1); lastGrain = nil }
        public mutating func moveRight() { cursor = min(characters.count, cursor + 1); lastGrain = nil }
        public mutating func moveLineStart() { cursor = lineStart(from: cursor); lastGrain = nil }
        public mutating func moveLineEnd() { cursor = lineEnd(from: cursor); lastGrain = nil }
        public mutating func moveStart() { cursor = 0; lastGrain = nil }
        public mutating func moveEnd() { cursor = characters.count; lastGrain = nil }

        public mutating func moveWordLeft() {
            var i = cursor
            while i > 0, characters[i - 1].isWhitespace { i -= 1 }
            while i > 0, !characters[i - 1].isWhitespace { i -= 1 }
            cursor = i
            lastGrain = nil
        }

        public mutating func moveWordRight() {
            var i = cursor
            while i < characters.count, characters[i].isWhitespace { i += 1 }
            while i < characters.count, !characters[i].isWhitespace { i += 1 }
            cursor = i
            lastGrain = nil
        }

        /// Up and down keep the column where the line allows it.
        public mutating func moveUp() {
            let start = lineStart(from: cursor)
            guard start > 0 else { cursor = 0; return }
            let column = cursor - start
            let previousStart = lineStart(from: start - 1)
            let previousEnd = start - 1
            cursor = min(previousStart + column, previousEnd)
            lastGrain = nil
        }

        public mutating func moveDown() {
            let end = lineEnd(from: cursor)
            guard end < characters.count else { cursor = characters.count; return }
            let column = cursor - lineStart(from: cursor)
            let nextStart = end + 1
            let nextEnd = lineEnd(from: nextStart)
            cursor = min(nextStart + column, nextEnd)
            lastGrain = nil
        }

        public func lineStart(from index: Int) -> Int {
            var i = min(index, characters.count)
            while i > 0, characters[i - 1] != "\n" { i -= 1 }
            return i
        }

        public func lineEnd(from index: Int) -> Int {
            var i = min(index, characters.count)
            while i < characters.count, characters[i] != "\n" { i += 1 }
            return i
        }

        /// The buffer as a whole, with the ghost where it would land.
        public var display: String { text + ghost }

        // MARK: The editor's hands

        /// Replace a range with text; the cursor lands after the text.
        public mutating func replace(_ range: Range<Int>, with text: String) {
            let lower = max(0, min(range.lowerBound, characters.count))
            let upper = max(lower, min(range.upperBound, characters.count))
            let incoming = Array(text)
            characters.replaceSubrange(lower..<upper, with: incoming)
            cursor = lower + incoming.count
            lastGrain = .typed
        }

        public mutating func setCursor(_ index: Int) {
            cursor = max(0, min(index, characters.count))
            lastGrain = nil
        }

        /// Restore a snapshot (undo, redo).
        public mutating func restore(characters: [Character], cursor: Int) {
            self.characters = characters
            self.cursor = max(0, min(cursor, characters.count))
            ghost = ""
        }

        public func slice(_ range: Range<Int>) -> String {
            let lower = max(0, min(range.lowerBound, characters.count))
            let upper = max(lower, min(range.upperBound, characters.count))
            return String(characters[lower..<upper])
        }
    }

    // MARK: - Joining speech to text

    /// What goes between what stands before the cursor and a settled
    /// result: nothing at the start of the text, after whitespace, or
    /// before punctuation that attaches to the word before it; a space
    /// otherwise. Recognizers deliver a sentence's second half with a
    /// leading space and its first without, and typed identifiers end
    /// without one — the rule makes all three read as prose.
    public static func separator<C: BidirectionalCollection>(after existing: C, before incoming: String) -> String
    where C.Element == Character {
        guard let last = existing.last, let first = incoming.first else { return "" }
        if last.isWhitespace || last.isNewline { return "" }
        if attaching.contains(first) { return "" }
        if last == "(" || last == "[" || last == "{" || last == "\"" || last == "'" { return "" }
        return " "
    }

    private static let attaching: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}"]

    /// The recognizer capitalizes the first word of every result, as if
    /// every result began a sentence. Landing mid-sentence — after a word,
    /// a comma, an open quote — that first letter is lowered, unless the
    /// word is plainly a name (more capitals than its first) or one
    /// letter ("I"). At the start of the text, after a newline, or after
    /// a sentence's end, it stays as heard.
    public static func cased<C: BidirectionalCollection>(_ incoming: String, after existing: C) -> String
    where C.Element == Character {
        guard let first = incoming.first, first.isUppercase else { return incoming }
        var i = existing.endIndex
        var last: Character?
        while i > existing.startIndex {
            i = existing.index(before: i)
            if !existing[i].isWhitespace { last = existing[i]; break }
            if existing[i].isNewline { return incoming }
        }
        guard let last else { return incoming }
        if ".!?".contains(last) { return incoming }
        let word = incoming.prefix { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }
        if word.count == 1 { return incoming }
        if word.dropFirst().contains(where: { $0.isUppercase }) { return incoming }
        return first.lowercased() + incoming.dropFirst()
    }

    // MARK: - Ending

    /// How a draft lands. Every ending puts the text on the pasteboard;
    /// these say what happens after that.
    public enum Ending: Equatable, Sendable {
        /// ⌘V into the destination's cursor.
        case paste
        /// The destination is the field the text was pulled from: the
        /// selection, or the whole field, is replaced.
        case replace
        /// No field to paste into; the pasteboard is the destination.
        case clipboard
    }

    /// The destination is live — whatever is frontmost at ⏎ — so
    /// replacement happens only when that is still the origin field.
    /// Anywhere else it is a plain paste, and nowhere it is a copy.
    public static func ending(hasDestination: Bool, destinationIsOrigin: Bool,
                              pulledFromOrigin: Bool) -> Ending {
        guard hasDestination else { return .clipboard }
        return destinationIsOrigin && pulledFromOrigin ? .replace : .paste
    }

    // MARK: - Vocabulary

    /// The user's own words, repaired into a settled result. Recognition
    /// hands back "Ghostie" for Ghostty and "loadstar" for Lodestar; a word
    /// list of what this person actually says fixes the token in place,
    /// case and all. A whole token has to be within a short edit distance
    /// of the word and share its first letter, so "dune" is not made
    /// "done" and a real word is never silently swapped for a near one.
    public enum Vocabulary {
        public static func apply(_ text: String, words: [String]) -> String {
            let entries = words.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !entries.isEmpty, !text.isEmpty else { return text }
            // Longest phrases first, so "done column" is tried before "done".
            let phrases = entries
                .map { (phrase: $0, width: $0.split(separator: " ").count) }
                .sorted { $0.width > $1.width }
            var tokens = tokenize(text)
            var i = 0
            while i < tokens.count {
                defer { i += 1 }
                guard tokens[i].isWord else { continue }
                // A one-word name heard as two ("load star") is the two
                // joined, measured against the word.
                if i + 2 < tokens.count, tokens[i + 2].isWord, !tokens[i + 1].isWord,
                   tokens[i + 1].text == " " {
                    let joined = tokens[i].text + tokens[i + 2].text
                    if let (phrase, _) = phrases.first(where: { $0.width == 1 && matches(joined, $0.phrase) }) {
                        tokens.replaceSubrange(i...(i + 2), with: [Token(text: phrase, isWord: true)])
                        continue
                    }
                }
                for (phrase, width) in phrases {
                    // The next `width` words, joined by single whitespace runs only.
                    var indices = [i]
                    var j = i + 1
                    while indices.count < width, j + 1 < tokens.count,
                          !tokens[j].isWord, tokens[j].text.allSatisfy(\.isWhitespace),
                          tokens[j + 1].isWord {
                        indices.append(j + 1)
                        j += 2
                    }
                    guard indices.count == width else { continue }
                    let candidate = indices.map { tokens[$0].text }.joined(separator: " ")
                    guard matches(candidate, phrase) else { continue }
                    tokens.replaceSubrange(i...indices[indices.count - 1],
                                           with: [Token(text: phrase, isWord: true)])
                    break
                }
            }
            return tokens.map(\.text).joined()
        }

        struct Token: Equatable {
            var text: String
            var isWord: Bool
        }

        static func tokenize(_ text: String) -> [Token] {
            var tokens: [Token] = []
            var current = ""
            var currentIsWord: Bool?
            for character in text {
                let isWord = character.isLetter || character.isNumber || character == "'" || character == "’"
                if currentIsWord == nil || currentIsWord == isWord {
                    current.append(character)
                    currentIsWord = isWord
                } else {
                    tokens.append(Token(text: current, isWord: currentIsWord ?? false))
                    current = String(character)
                    currentIsWord = isWord
                }
            }
            if !current.isEmpty { tokens.append(Token(text: current, isWord: currentIsWord ?? false)) }
            return tokens
        }

        /// Case-insensitive equality repairs case alone; otherwise a
        /// bounded edit distance with the first letter held fixed.
        static func matches(_ token: String, _ word: String) -> Bool {
            let a = token.lowercased(), b = word.lowercased()
            if a == b { return token != word }
            guard a.first == b.first, abs(a.count - b.count) <= 1 else { return false }
            // Short words get case repair only: at four or five letters a
            // one-edit neighbor is usually a different real word.
            // Two edits are allowed only at equal length — substitutions
            // and swaps, the shapes a mishearing takes — so "ghosts" is
            // never made "Ghostty" by an insertion and a substitution.
            let allowance: Int
            switch b.count {
            case ..<6: allowance = 0
            case 6...8: allowance = a.count == b.count ? 2 : 1
            default: allowance = a.count == b.count ? 3 : 2
            }
            guard allowance > 0 else { return false }
            return distance(a, b) <= allowance
        }

        /// Optimal string alignment distance: insertions, deletions,
        /// substitutions, and one adjacent transposition.
        static func distance(_ a: String, _ b: String) -> Int {
            let x = Array(a), y = Array(b)
            if x.isEmpty { return y.count }
            if y.isEmpty { return x.count }
            var previous2 = [Int](repeating: 0, count: y.count + 1)
            var previous = Array(0...y.count)
            var current = [Int](repeating: 0, count: y.count + 1)
            for i in 1...x.count {
                current[0] = i
                for j in 1...y.count {
                    let cost = x[i - 1] == y[j - 1] ? 0 : 1
                    current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                    if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                        current[j] = min(current[j], previous2[j - 2] + 1)
                    }
                }
                previous2 = previous
                previous = current
            }
            return previous[y.count]
        }
    }
}
