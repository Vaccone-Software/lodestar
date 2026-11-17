import Foundation

extension Draft {
    /// Everything a settled result goes through before it lands, in one
    /// place, so the app and the evaluation run the same steps:
    ///
    /// 1. your names put back by sound (`NameMatcher`), word by word, with
    ///    the recognizer's confidence;
    /// 2. ellipses taken out, each one a seam decided by its words
    ///    (`Seams`);
    /// 3. the join to the text before: a pause's period dropped after a
    ///    word that cannot end a sentence, a trailed-off end given one;
    /// 4. fillers and taken-back words removed (`SelfCorrection`), across
    ///    the join with the result before when the cue reaches back;
    /// 5. the first letter cased for where it lands (`cased`).
    public struct Settler {
        public var matcher: NameMatcher?
        /// The names the repository being talked about already has, when
        /// the words are going somewhere code is written.
        public var codeNames: CodeNames.Index?
        public var isOrdinary: (String) -> Bool
        /// Fillers are English words; another language keeps them.
        public var removesFillers: Bool

        /// When the last result's audio ended, for the pause before the next.
        private var lastEnd: Double?
        /// The last result ended in an ellipsis that was taken out.
        private var trailedOff = false
        /// The last result as it landed, for a correction that reaches
        /// back into it.
        public private(set) var lastLanded: String?

        /// A gap this long between two results is a pause.
        public static let pause = 0.3

        public init(matcher: NameMatcher? = nil, isOrdinary: @escaping (String) -> Bool = { _ in true },
                    removesFillers: Bool = true) {
            self.matcher = matcher
            self.isOrdinary = isOrdinary
            self.removesFillers = removesFillers
        }

        public struct Landing: Equatable {
            /// What lands at the landing point.
            public var text: String
            /// What happens to the text just before it.
            public var before: Before
            /// The last result is replaced too: `text` covers it and the
            /// new one, because a correction reached back into it.
            public var replacesLast = false
            // Counts for the record; never the words.
            public var names = 0
            /// The user's own words the matcher put back, in the order they
            /// were said. Not stored with the record: they say which of
            /// the list was lately in use.
            public var terms: [String] = []
            public var codeNames = 0
            public var ellipses = 0
            public var joins = 0
            public var fillers = 0
            public var corrections = 0

            /// The text before keeps its end, loses a period, or is given a
            /// mark: a period where an ellipsis stood, or punctuation the
            /// live recognizer wrote late, at the head of this result.
            public enum Before: Equatable { case unchanged, dropPeriod, add(Character) }
        }

        /// A phrase heard again by a settling ear, ready to stand where
        /// the live recognizer's words for it already landed (`landed`).
        /// The same steps, without deciding the join again: the join was
        /// made when the phrase first landed, so the new words end the way
        /// the landed ones do and take their case from the text before.
        /// Nil when the ear's words should not replace the landed ones: it
        /// heard nothing, or it read back the list it was given (three of
        /// the speaker's terms the live recognizer did not hear).
        public func resettled(_ heard: Heard, landed: String, after before: String, context: [String]) -> String? {
            var text = heard.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            let echoed = context.filter { term in
                text.range(of: term, options: .caseInsensitive) != nil
                    && landed.range(of: term, options: .caseInsensitive) == nil
                    && heard.text.range(of: term, options: .caseInsensitive) != nil
            }
            if echoed.count >= 3 { return nil }
            if let matcher, !matcher.isEmpty { text = matcher.apply(text).text }
            if let codeNames { text = codeNames.apply(text, isCommon: isOrdinary).text }
            text = CodeNames.joinedExtensions(SpokenNumbers.written(text))
            text = Seams.smoothed(text, isOrdinary: isOrdinary).text
            if removesFillers { text = SelfCorrection.withoutFillers(text).0 }
            let corrected = SelfCorrection.apply(text)
            if corrected.corrections > 0 { text = corrected.text }
            return reshaped(text, like: landed, after: before)
        }

        /// Words that stand where `landed` stood, cased for the text before.
        /// A sentence's end the ear heard stands: it heard the whole run,
        /// and the live recognizer's ending is the weaker guess (Nemotron
        /// ended none of the maker's 60 recordings with a period, and found
        /// a fifth of the sentence breaks in long takes; the ears found
        /// three quarters). Where the ear wrote no end and the landed words
        /// had one, the landed end is kept, so a draft never loses a
        /// period to a hearing again.
        public func reshaped(_ text: String, like landed: String, after before: String) -> String {
            var text = text
            let landedEnd = landed.trimmingCharacters(in: .whitespaces).last
            let ends: Set<Character> = [".", "!", "?"]
            if let landedEnd, ends.contains(landedEnd), let last = text.last, !ends.contains(last) {
                text.append(landedEnd)
            }
            return Draft.cased(text, after: before, isOrdinary: isOrdinary)
        }

        /// The mark a run of leading punctuation stands for: a sentence's
        /// end over anything else, so ", ." ends the sentence.
        static func strongest<S: Sequence>(_ marks: S) -> Character? where S.Element == Character {
            let found = marks.filter { !$0.isWhitespace }
            return found.last { ".!?".contains($0) } ?? found.last
        }

        /// A new session: nothing before.
        public mutating func reset() {
            lastEnd = nil
            trailedOff = false
            lastLanded = nil
        }

        /// The hand typed or moved since the last result: the next one is
        /// not joined to it, and nothing reaches back into it.
        public mutating func handInterrupted() {
            trailedOff = false
            lastLanded = nil
        }

        /// One result, ready to land after `before` (the text before the
        /// landing point; its tail is all that is read).
        /// `canReachBack` says the last result still stands as it landed,
        /// right before this one, so a correction may take back its words.
        public mutating func land(_ heard: Heard, after before: String, typedBetween: Bool = false,
                                  canReachBack: Bool = true) -> Landing {
            var landing = Landing(text: "", before: .unchanged)
            var text = heard.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // 0. Punctuation at the head of a result ends the text before
            // it: Nemotron writes a sentence's period late, as the first
            // piece after the pause (". Hi Maria, …"). Landed as the head of
            // this result, the period was this result's, and a hearing of it
            // again, which starts at "Hi", took the period away and left the
            // words with no space between them ("keyboardhi Maria").
            let head = text.prefix { ".,;:!?".contains($0) || $0.isWhitespace }
            let lateMark = Self.strongest(head)
            if !head.isEmpty { text = String(text.dropFirst(head.count)) }
            // 1. Names.
            if let matcher, !matcher.isEmpty {
                let tokens: [NameMatcher.Token]
                if !heard.words.isEmpty,
                   heard.words.map({ $0.text.trimmingCharacters(in: .whitespaces) }).joined(separator: " ")
                    .split(separator: " ").joined(separator: " ") == text.split(separator: " ").joined(separator: " ") {
                    tokens = heard.words.flatMap { word in
                        word.text.split(separator: " ").map { NameMatcher.Token(String($0), confidence: word.confidence) }
                    }
                } else {
                    tokens = text.split(separator: " ").map { NameMatcher.Token(String($0)) }
                }
                let matched = matcher.apply(tokens: tokens)
                text = matched.text
                landing.names = matched.edits.count
                landing.terms = matched.edits.map(\.term)
            }
            // 1b. Names in code, as the repository writes them.
            if let codeNames {
                let named = codeNames.apply(text, isCommon: isOrdinary)
                text = named.text
                landing.codeNames = named.edits
            }
            // 1c. Numbers as they are written, and a code name's extension.
            text = CodeNames.joinedExtensions(SpokenNumbers.written(text))
            // 2. Ellipses inside and at the ends.
            let ellipsisCount = text.components(separatedBy: "…").count - 1 + text.components(separatedBy: "...").count - 1
            let smoothed = Seams.smoothed(text, isOrdinary: isOrdinary)
            text = smoothed.text
            landing.ellipses = ellipsisCount
            // 3. The join.
            let pause: Bool = {
                guard let start = heard.start, let end = lastEnd else { return true }
                return start - end >= Self.pause
            }()
            let tail = String(before.suffix(200))
            let trimmedTail = tail.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            // The late mark goes on the text before, unless that already
            // ends in punctuation or there is none; the join then decides
            // as if the recognizer had written it there.
            var joinTail = tail
            if let lateMark, let last = trimmedTail.last, !".,;:!?".contains(last) {
                joinTail = trimmedTail + String(lateMark)
            }
            let joined = Seams.join(before: joinTail, incoming: text, pause: pause, trailedOff: trailedOff,
                                    typedBetween: typedBetween, isOrdinary: isOrdinary)
            let endsAs = joined.before.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if endsAs.count == trimmedTail.count - 1, trimmedTail.hasPrefix(endsAs) {
                landing.before = .dropPeriod
                landing.joins += 1
            } else if endsAs.count == trimmedTail.count + 1, endsAs.hasPrefix(trimmedTail), let mark = endsAs.last {
                landing.before = .add(mark)
            } else if endsAs.count < joinTail.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression).count {
                // The late period was joined away: nothing changes.
                landing.joins += 1
            }
            text = joined.incoming
            // 4. Fillers and corrections.
            if removesFillers {
                let unfilled = SelfCorrection.withoutFillers(text)
                text = unfilled.0
                landing.fillers = unfilled.1
            }
            // A cue may take back words at the end of the last result
            // ("send it Monday." / "No wait, I mean Tuesday."): tried on the
            // two together first, and kept only if it reached into the last.
            var reached = false
            if canReachBack, let last = lastLanded, !typedBetween, landing.before == .unchanged {
                let together = SelfCorrection.apply(last + " " + text)
                if together.corrections > 0, !together.text.hasPrefix(last) {
                    landing.replacesLast = true
                    landing.corrections = together.corrections
                    text = together.text
                    reached = true
                }
            }
            if !reached {
                let corrected = SelfCorrection.apply(text)
                if corrected.corrections > 0 {
                    text = corrected.text
                    landing.corrections = corrected.corrections
                }
            }
            // 5. The first letter, for where it lands.
            if !landing.replacesLast {
                // The tail as it stands, line breaks and all: a result after
                // a new line keeps its capital.
                var context = tail
                if landing.before == .dropPeriod { context = String(trimmedTail.dropLast()) }
                if case .add(let mark) = landing.before { context = trimmedTail + String(mark) }
                text = Draft.cased(text, after: context, isOrdinary: isOrdinary)
            }
            landing.text = text
            lastEnd = heard.end ?? lastEnd
            trailedOff = smoothed.trailedOff
            lastLanded = text
            return landing
        }
    }
}
