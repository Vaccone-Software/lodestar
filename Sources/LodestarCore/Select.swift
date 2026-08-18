import Foundation

/// What one keystroke did inside select mode — the seam between grammar
/// and controller, like `HintStep` is for hints.
public enum SelectStep: Equatable {
    /// Still collecting — query grew, a label narrowed, an anchor landed.
    case pending
    /// The selection was made (or the mode gave up); the engine goes idle.
    case done
}

/// The select register, pure: text addressed by its own content.
///
/// Every other register assigns addresses — apps get letters, layouts get
/// chains. Text needs none, because it is made of the characters the
/// keyboard already produces: you type a few characters of what you can
/// see, the matches wear capital chips, and a capital picks one. Lowercase
/// always searches, capitals always pick — no timeout, no ambiguity,
/// clockless like the rest of the grammar. Two anchors make a span; the
/// span is whatever lies between them in document order, so there is no
/// forward or backward, and no direction to get wrong.
///
/// Ranges are NSRange over UTF-16, because that is the unit AX text APIs
/// speak; the matcher goes through Foundation so Unicode case folding is
/// someone else's solved problem.
public struct SelectCore {
    /// One text-bearing element, in reading order. The id is the caller's
    /// index into whatever geometry it keeps alongside.
    public struct Element: Equatable {
        public let id: Int
        public let text: String

        public init(id: Int, text: String) {
            self.id = id
            self.text = text
        }
    }

    public struct Match: Equatable {
        public let element: Int
        public let range: NSRange

        public init(element: Int, range: NSRange) {
            self.element = element
            self.range = range
        }
    }

    public enum Effect: Equatable {
        /// Query or labels changed — redraw.
        case updated
        /// The start anchor landed; the query reset for the far end.
        case anchored
        /// Both anchors placed: the normalized span, ready to act on.
        case selected(element: Int, range: NSRange)
        /// The key meant nothing here.
        case none
    }

    /// More chips than this is confetti; the query is the instrument for
    /// narrowing, not the alphabet.
    public static let displayCap = 30
    /// Counting every match in a large document is wasted work past the
    /// point of saying "many".
    static let countCap = 200

    public private(set) var query = ""
    public private(set) var typedLabel = ""
    public private(set) var matches: [Match] = []
    public private(set) var labels: [String] = []
    public private(set) var anchor: Match?
    /// Total matches found (capped) — the band says "of N" honestly.
    public private(set) var totalMatches = 0

    let elements: [Element]
    let alphabet: String

    public init(elements: [Element], alphabet: String) {
        self.elements = elements
        self.alphabet = alphabet
    }

    /// Shifted punctuation and digits are search characters — labels are
    /// letters only, so `⇧4` can never be a pick and `$100` types as seen.
    static let shifted: [String: String] = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&",
        "8": "*", "9": "(", "0": ")", "-": "_", "=": "+", "[": "{", "]": "}",
        "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~",
    ]

    static func character(for key: String, shift: Bool) -> String? {
        if key == "space" { return " " }
        guard key.count == 1, let ch = key.first else { return nil }
        if ch.isLetter { return shift ? nil : key }
        return shift ? Self.shifted[key] : key
    }

    // MARK: - Keys

    public mutating func key(_ key: String, shift: Bool) -> Effect {
        let isLetter = key.count == 1 && (key.first?.isLetter ?? false)
        if shift, isLetter {
            return pick(letter: key)
        }
        // Shift opens the pick; it does not have to be held for the rest.
        // Once a label is underway every further letter can only be
        // finishing it — labels are prefix-free, so nothing else could be
        // meant — and demanding a held shift across a two-letter label was
        // pure tax. A symbol abandons the pick back to searching; ⌫ walks
        // it back a letter at a time.
        if isLetter, !typedLabel.isEmpty {
            return pick(letter: key)
        }
        guard let character = Self.character(for: key, shift: shift) else { return .none }
        query += character
        typedLabel = ""
        recompute()
        return .updated
    }

    /// Adopt a query wholesale — how a richer harvest pass hands the
    /// user's typing to a rebuilt core without replaying keys.
    public mutating func seed(query: String) {
        self.query = query
        typedLabel = ""
        recompute()
    }

    /// ⌫ walks back: the label prefix first, then the query, and from an
    /// empty second stage all the way back to re-placing the start anchor.
    public mutating func backspace() -> Effect {
        if !typedLabel.isEmpty {
            typedLabel.removeLast()
            return .updated
        }
        if !query.isEmpty {
            query.removeLast()
            recompute()
            return .updated
        }
        if anchor != nil {
            anchor = nil
            recompute()
            return .updated
        }
        return .none
    }

    private mutating func pick(letter: String) -> Effect {
        let candidate = typedLabel + letter.lowercased()
        switch HintLabels.match(typed: candidate, labels: labels) {
        case .exact(let index):
            let match = matches[index]
            typedLabel = ""
            if let anchor {
                let start = min(anchor.range.location, match.range.location)
                let end = max(anchor.range.location + anchor.range.length,
                              match.range.location + match.range.length)
                // Word snap: two typed characters name a word, they do not
                // dissect it. The span runs from the start of the word the
                // first anchor touches to the end of the word the second
                // touches — "fo" means through "fox", "uick" means from
                // "quick". Whitespace-delimited, so a URL or an identifier
                // counts as one word and comes out whole.
                guard let text = elements.first(where: { $0.id == match.element })?.text
                else { return .none }
                let snapped = Self.wordSnapped(
                    NSRange(location: start, length: end - start), in: text as NSString)
                return .selected(element: match.element, range: snapped)
            }
            anchor = match
            query = ""
            recompute()
            return .anchored
        case .partial:
            typedLabel = candidate
            return .updated
        case .none:
            return .none
        }
    }

    /// Expand a range outward to whitespace boundaries. Scans UTF-16
    /// units, which is safe: every whitespace character is BMP, so a
    /// surrogate pair is always non-whitespace and never splits.
    static func wordSnapped(_ range: NSRange, in text: NSString) -> NSRange {
        let whitespace = CharacterSet.whitespacesAndNewlines
        func isBreak(_ index: Int) -> Bool {
            guard index >= 0, index < text.length else { return true }
            guard let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
            return whitespace.contains(scalar)
        }
        var start = range.location
        while !isBreak(start - 1) { start -= 1 }
        var end = range.location + range.length
        while !isBreak(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    // MARK: - Matching

    mutating func recompute() {
        matches = []
        totalMatches = 0
        guard !query.isEmpty else {
            labels = []
            return
        }
        // Stage two confines itself to the anchor's element: a span cannot
        // cross elements, so matches elsewhere would be promises the
        // selection cannot keep.
        let searchable = anchor.map { a in elements.filter { $0.id == a.element } }
            ?? elements
        // A single character is below the substring threshold — "i" as a
        // substring is confetti — but "I" and "a" are real words that
        // deserve addresses. So a one-character query matches only exact
        // standalone words: whole and whitespace-bounded, case folded.
        let wordExact = (query as NSString).length < 2
        for element in searchable {
            let text = element.text as NSString
            var cursor = NSRange(location: 0, length: text.length)
            while totalMatches < Self.countCap {
                let found = text.range(of: query, options: [.caseInsensitive], range: cursor)
                guard found.location != NSNotFound, found.length > 0 else { break }
                let standalone = !wordExact
                    || Self.wordSnapped(found, in: text) == found
                if standalone {
                    totalMatches += 1
                    if matches.count < Self.displayCap {
                        matches.append(Match(element: element.id, range: found))
                    }
                }
                let next = found.location + found.length
                guard next < text.length else { break }
                cursor = NSRange(location: next, length: text.length - next)
            }
            if totalMatches >= Self.countCap { break }
        }
        labels = HintLabels.labels(count: matches.count, alphabet: alphabet)
    }
}
