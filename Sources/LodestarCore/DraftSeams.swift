import Foundation

/// What the recognizer heard in one settled result: the words, and when
/// each was said. Times are seconds into the session's audio; a result
/// without them (a test, a recognizer that gives none) has nil times and
/// is joined by its words alone.
public struct Heard: Equatable, Sendable {
    public struct Word: Equatable, Sendable {
        public let text: String
        public let start: Double?
        public let end: Double?
        /// The recognizer's confidence in this word, 0 to 1.
        public let confidence: Double?

        public init(_ text: String, start: Double? = nil, end: Double? = nil, confidence: Double? = nil) {
            self.text = text
            self.start = start
            self.end = end
            self.confidence = confidence
        }
    }

    public let text: String
    public let words: [Word]

    public init(_ text: String, words: [Word] = []) {
        self.text = text
        self.words = words
    }

    public var start: Double? { words.first(where: { $0.start != nil })?.start }
    public var end: Double? { words.last(where: { $0.end != nil })?.end }
}

extension Draft {
    /// Where one settled result meets the text before it.
    ///
    /// Apple's recognizer ends a result wherever the speaker pauses, and
    /// writes the pause as punctuation: a period and a capital, or an
    /// ellipsis when the voice trailed off. Measured on 175 recordings it
    /// broke a sentence at 33 of 40 mid-sentence pauses and wrote an
    /// ellipsis at 4. A pause is thinking, not punctuation, so a seam is
    /// decided by the words: an ellipsis never lands, and a period before
    /// a word that cannot end a sentence ("the", "and", "to", "my") goes,
    /// with the capital after it. Measured, that removed every ellipsis
    /// at a pause and 11 false breaks, and destroyed none of 58 real
    /// sentence ends. The breaks left need the words' meaning, which is a
    /// model's job, not a rule's.
    public enum Seams {
        /// Words a sentence does not end on. Auxiliaries ("is", "was") are
        /// left out on purpose: "what the app is." ends a sentence.
        static let dangling: Set<String> = Set("""
            a an the and but or nor because if than whether although though
            to of in on at for with by from into onto about over under between through via without within across against
            toward towards per
            i we they he she my your our their his her its
            very just really also
            """.split(whereSeparator: \.isWhitespace).map(String.init))

        /// The text with every ellipsis taken out: inside it, each one is a
        /// seam of its own, decided as a join between results is; at its
        /// start it goes; at its end it goes and `trailedOff` says so, for
        /// the next seam to decide.
        public static func smoothed(_ text: String, isOrdinary: (String) -> Bool) -> (text: String, trailedOff: Bool) {
            var parts = pieces(text)
            guard parts.count > 1 || hasEllipsis(text) else { return (text, false) }
            // A leading ellipsis: nothing to decide, it goes.
            if let first = parts.first {
                parts[0] = stripLeading(first)
            }
            var out = ""
            var trailedOff = false
            for (index, part) in parts.enumerated() {
                var piece = part.trimmingCharacters(in: .whitespaces)
                let isLast = index == parts.count - 1
                let trails = hasTrailingEllipsis(piece)
                if trails { piece = stripTrailing(piece) }
                if out.isEmpty {
                    out = piece
                } else {
                    let decision = join(before: out, incoming: piece, pause: true, trailedOff: true,
                                        isOrdinary: isOrdinary)
                    out = decision.before + " " + decision.incoming
                }
                if isLast { trailedOff = trails }
            }
            return (out.trimmingCharacters(in: .whitespaces), trailedOff)
        }

        /// The join of `incoming` to the text before it. `pause` says the
        /// audio between them was a pause (or is unknown); `trailedOff`
        /// says the text before ended in an ellipsis that was taken out;
        /// `typedBetween` says the hand typed between the two, and then
        /// the hand's own text decides, so nothing changes.
        ///
        /// Returns the text before (perhaps without its period, or with one
        /// added where an ellipsis stood at a real end) and the incoming
        /// text (perhaps with its capital lowered or raised).
        public static func join(before: String, incoming: String, pause: Bool, trailedOff: Bool,
                                typedBetween: Bool = false,
                                isOrdinary: (String) -> Bool) -> (before: String, incoming: String) {
            guard !typedBetween, !incoming.isEmpty else { return (before, incoming) }
            let trimmed = before.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            guard !trimmed.isEmpty else { return (before, incoming) }
            let endsWithPeriod = trimmed.hasSuffix(".") && !trimmed.hasSuffix("..")
            let candidate = (endsWithPeriod && pause) || trailedOff
            guard candidate else { return (before, incoming) }
            let last = lastWord(trimmed).lowercased()
            if dangling.contains(last) {
                // Mid-sentence: the period goes and the next word is lowered.
                let kept = endsWithPeriod ? String(trimmed.dropLast()) : trimmed
                return (kept, lowered(incoming, isOrdinary: isOrdinary))
            }
            if trailedOff, !endsWithPeriod, let tail = trimmed.last, !".!?,;:".contains(tail) {
                // The voice trailed off at what reads as an end: a period
                // where the ellipsis stood, and the next word capitalized.
                return (trimmed + ".", raised(incoming))
            }
            return (before, incoming)
        }

        /// A sentence's first word lowered when it is an ordinary word —
        /// never "I", a contraction of it, a name, or a word with capitals
        /// past its first letter.
        public static func lowered(_ text: String, isOrdinary: (String) -> Bool) -> String {
            guard let first = text.first, first.isUppercase else { return text }
            let word = String(text.prefix { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" })
            guard canLower(word, isOrdinary: isOrdinary) else { return text }
            return first.lowercased() + text.dropFirst()
        }

        static func canLower(_ word: String, isOrdinary: (String) -> Bool) -> Bool {
            guard word.count > 1 else { return false }
            let lower = word.lowercased()
            if lower.hasPrefix("i'") || lower.hasPrefix("i’") { return false }
            if word.dropFirst().contains(where: \.isUppercase) { return false }
            return isOrdinary(lower)
        }

        static func raised(_ text: String) -> String {
            guard let first = text.first, first.isLowercase else { return text }
            return first.uppercased() + text.dropFirst()
        }

        static func lastWord(_ text: String) -> String {
            var word = ""
            for character in text.reversed() {
                if character.isLetter || character.isNumber || character == "'" || character == "’" {
                    word.insert(character, at: word.startIndex)
                } else if !word.isEmpty {
                    break
                }
            }
            return word
        }

        static func hasEllipsis(_ text: String) -> Bool { text.contains("…") || text.contains("...") }
        static func hasTrailingEllipsis(_ text: String) -> Bool {
            let t = text.trimmingCharacters(in: .whitespaces)
            return t.hasSuffix("…") || t.hasSuffix("...")
        }

        static func stripTrailing(_ text: String) -> String {
            var t = text.trimmingCharacters(in: .whitespaces)
            while t.hasSuffix("…") || t.hasSuffix(".") { t.removeLast() }
            return t.trimmingCharacters(in: .whitespaces)
        }

        static func stripLeading(_ text: String) -> String {
            var t = text.trimmingCharacters(in: .whitespaces)
            while t.hasPrefix("…") || t.hasPrefix(".") { t.removeFirst() }
            return t.trimmingCharacters(in: .whitespaces)
        }

        /// The text split after each ellipsis that has words after it.
        static func pieces(_ text: String) -> [String] {
            var out: [String] = []
            var current = ""
            let chars = Array(text)
            var i = 0
            while i < chars.count {
                current.append(chars[i])
                let isEllipsis = chars[i] == "…" || (chars[i] == "." && i >= 2 && chars[i - 1] == "." && chars[i - 2] == "."
                                                      && (i + 1 >= chars.count || chars[i + 1] != "."))
                if isEllipsis, i + 1 < chars.count,
                   chars[(i + 1)...].contains(where: { $0.isLetter || $0.isNumber }) {
                    out.append(current)
                    current = ""
                }
                i += 1
            }
            if !current.isEmpty { out.append(current) }
            return out
        }
    }
}
