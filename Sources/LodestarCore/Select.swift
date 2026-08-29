import CoreGraphics
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
        /// Where the element sits on screen, so a span crossing elements
        /// can tell the column it runs down from the ones beside it.
        /// `.null` is "unknown", and unknown never excludes anything.
        public let frame: CGRect

        public init(id: Int, text: String, frame: CGRect = .null) {
            self.id = id
            self.text = text
            self.frame = frame
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
        /// The start anchor landed on a whole word; the query reset for
        /// the far end.
        case anchored
        /// Both anchors placed: the span in document order, as one piece
        /// per element it covers — the two ends clipped to the words that
        /// were named, everything between taken whole.
        case selected(pieces: [Match])
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
    /// Whether the count stopped at the cap: only then may the band wear
    /// a "+" — below it the total is exact, and "45+" claims matches
    /// that do not exist.
    public var countCapped: Bool { totalMatches >= Self.countCap }

    let elements: [Element]
    let alphabet: String
    /// Element id → its place in reading order, so a match can be put
    /// before or after another without scanning.
    private let order: [Int: Int]
    /// Each element's text with OCR's classic glyph confusions folded —
    /// what the search runs against, so the truth you type finds the
    /// misread the recognizer stored. Built once per world, not per
    /// keystroke.
    private let folded: [NSString]

    public init(elements: [Element], alphabet: String) {
        self.elements = elements
        self.alphabet = alphabet
        // First occurrence wins: ids come from the harvest, which this
        // layer does not control, and a duplicate is a reading-order tie —
        // never a reason to trap.
        order = Dictionary(elements.enumerated().map { ($0.element.id, $0.offset) },
                           uniquingKeysWith: { first, _ in first })
        folded = elements.map { Self.confusionFolded($0.text) as NSString }
    }

    /// The single-glyph confusions clean-screen recognition actually
    /// makes — 1/l/I, 0/O, 5/S, 8/B, 2/Z, and the pipe — folded to one
    /// representative on both sides of the search, so a quarter of failed
    /// aims stop failing. Every fold maps one UTF-16 unit to one, which
    /// is what keeps a range found in folded text valid in the original;
    /// rn↔m is a real confusion but a length-changing one, and a matcher
    /// that lies about ranges corrupts every highlight downstream, so it
    /// stays out.
    static func confusionFolded(_ text: String) -> String {
        let source = text as NSString
        guard source.length > 0 else { return text }
        var units = [unichar](repeating: 0, count: source.length)
        source.getCharacters(&units)
        var changed = false
        for index in units.indices {
            switch units[index] {
            case 0x30, 0x4F: units[index] = 0x6F; changed = true // 0, O → o
            case 0x31, 0x49, 0x69, 0x7C: units[index] = 0x6C; changed = true // 1, I, i, | → l
            case 0x35, 0x53: units[index] = 0x73; changed = true // 5, S → s
            case 0x38, 0x42: units[index] = 0x62; changed = true // 8, B → b
            case 0x32, 0x5A: units[index] = 0x7A; changed = true // 2, Z → z
            default: break
            }
        }
        // The fold runs at every world adoption on the run loop the tap
        // shares; an element with nothing to fold keeps its own string.
        guard changed else { return text }
        return String(utf16CodeUnits: units, count: units.count)
    }

    /// Whether an unshifted key would extend the query — the gate a
    /// pre-sensor buffer uses so an arrow's repeat cannot hoard slots
    /// that only aiming deserves.
    public static func isSearchKey(_ key: String) -> Bool {
        character(for: key, shift: false) != nil
    }

    /// Shifted punctuation and digits are search characters — labels are
    /// letters only, so `⇧4` can never be a pick and `$100` types as seen.
    /// That is the one rule this mode adds; what a key types is
    /// `Keys.character`, shared with the clipboard strip's search so both
    /// bands answer a keyboard the same way.
    static func character(for key: String, shift: Bool) -> String? {
        if shift, key.count == 1, key.first?.isLetter == true { return nil }
        return Keys.character(for: key, shift: shift)
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
                return .selected(pieces: span(from: anchor, to: match))
            }
            // The anchor is the whole word from the moment it lands, not
            // the two characters that named it — so the highlight shows a
            // word, and a start that never gets a far end is still a
            // selection someone can take.
            anchor = snapped(match)
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

    /// A match grown to the word it sits inside.
    private func snapped(_ match: Match) -> Match {
        guard let index = order[match.element] else { return match }
        return Match(element: match.element,
                     range: Self.wordSnapped(match.range,
                                             in: elements[index].text as NSString))
    }

    /// The span two anchors make, piece by piece.
    ///
    /// Word snap first: two typed characters name a word, they do not
    /// dissect it — "fo" means through "fox", "uick" means from "quick",
    /// whitespace-delimited so a URL or an identifier comes out whole.
    ///
    /// Inside one element the span is simply the stretch between the two,
    /// snapped out at both ends. Across elements it is the tail of the
    /// first, every element between taken whole, and the head of the last
    /// — what a drag down the page would have taken. Crossing is the
    /// normal case, not the exotic one: prose arrives shattered into
    /// per-line runs (a diff, a chat log, half of any web page), and a
    /// span that stopped at the line it started on stopped at an edge
    /// nobody could see. Document order is the element order the caller
    /// supplied, so there is still no direction to get wrong.
    func span(from a: Match, to b: Match) -> [Match] {
        // The order index exists for exactly this question.
        guard let indexA = order[a.element], let indexB = order[b.element]
        else { return [] }
        let forward = indexA < indexB
            || (indexA == indexB && a.range.location <= b.range.location)
        let firstIndex = forward ? indexA : indexB
        let lastIndex = forward ? indexB : indexA
        let first = forward ? a : b
        let last = forward ? b : a
        let firstText = elements[firstIndex].text as NSString
        let lastText = elements[lastIndex].text as NSString

        if firstIndex == lastIndex {
            let start = min(first.range.location, last.range.location)
            let end = max(NSMaxRange(first.range), NSMaxRange(last.range))
            let snapped = Self.wordSnapped(
                NSRange(location: start, length: end - start), in: firstText)
            return [Match(element: elements[firstIndex].id, range: snapped)]
        }

        let head = Self.wordSnapped(first.range, in: firstText).location
        let tail = NSMaxRange(Self.wordSnapped(last.range, in: lastText))
        // The column the span runs down is whatever its two ends cover
        // between them. Reading order interleaves columns, so an element
        // between the ends by index may sit beside that column — the
        // sidebar's next item, the neighboring card's line — and a drag
        // from one end to the other would never have crossed it. Two
        // ends in different columns cover both, and then everything
        // between is taken as before: a span may still cross columns, it
        // just has to be asked for at both ends.
        let column = elements[firstIndex].frame.union(elements[lastIndex].frame)
        var pieces = [Match(element: elements[firstIndex].id,
                            range: NSRange(location: head,
                                           length: firstText.length - head))]
        for element in elements[(firstIndex + 1)..<lastIndex] {
            let length = (element.text as NSString).length
            guard length > 0, Self.inColumn(element.frame, column) else { continue }
            pieces.append(Match(element: element.id,
                                range: NSRange(location: 0, length: length)))
        }
        pieces.append(Match(element: elements[lastIndex].id,
                            range: NSRange(location: 0, length: tail)))
        return pieces
    }

    /// Whether an element between a span's ends lies in the column those
    /// ends define — the stitching layer's own definition of a column, so
    /// the two never disagree about what a column is. Unknown geometry
    /// on either side never excludes: a caller without frames gets the
    /// span it always got.
    static func inColumn(_ frame: CGRect, _ column: CGRect) -> Bool {
        if frame.isNull || column.isNull { return true }
        return SelectRuns.sharesColumn(frame, column)
    }

    /// Expand a range outward to whitespace boundaries. Scans UTF-16
    /// units, which is safe: every whitespace character is BMP, so a
    /// surrogate pair is always non-whitespace and never splits.
    /// Hoisted: this runs inside the per-keystroke match loop, and
    /// building a CharacterSet per call was the loop's only allocation.
    private static let whitespace = CharacterSet.whitespacesAndNewlines

    static func wordSnapped(_ range: NSRange, in text: NSString) -> NSRange {
        let whitespace = Self.whitespace
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
        // Both stages search everything on screen. Stage two used to
        // confine itself to the anchor's element, back when a span could
        // not cross one; a span crosses now (`span(from:to:)`), so every
        // chip below the anchor is a promise the highlight can keep.
        //
        // A single character is below the substring threshold — "i" as a
        // substring is confetti — but "I" and "a" are real words that
        // deserve addresses. So a one-character query matches only exact
        // standalone words: whole and whitespace-bounded, case folded.
        let wordExact = (query as NSString).length < 2
        // The search runs in the confusion-folded world — needle and
        // haystack alike — and every range it finds is used against the
        // original text, which the unit-for-unit fold keeps honest.
        let needle = Self.confusionFolded(query)
        var hits: [Match] = []
        for (index, element) in elements.enumerated() {
            let text = element.text as NSString
            let haystack = folded[index]
            var cursor = NSRange(location: 0, length: haystack.length)
            while totalMatches < Self.countCap {
                let found = haystack.range(of: needle, options: [.caseInsensitive], range: cursor)
                guard found.location != NSNotFound, found.length > 0 else { break }
                let standalone = !wordExact
                    || Self.wordSnapped(found, in: text) == found
                if standalone {
                    totalMatches += 1
                    hits.append(Match(element: element.id, range: found))
                }
                let next = found.location + found.length
                guard next < haystack.length else { break }
                cursor = NSRange(location: next, length: haystack.length - next)
            }
            if totalMatches >= Self.countCap { break }
        }
        matches = capped(hits)
        labels = HintLabels.labels(count: matches.count, alphabet: alphabet)
    }

    /// Which of the hits wear chips when there are more than chips should
    /// ever be. Reading order decides, from the top — except in stage two,
    /// where the window slides to sit around the anchor. Screen-wide
    /// search is what lets a span run down the page; without this, thirty
    /// chips at the top of a dense page would be the answer to a far end
    /// chosen at the bottom of it, and the only remedy would be typing
    /// more of a word already on screen.
    private func capped(_ hits: [Match]) -> [Match] {
        guard hits.count > Self.displayCap else { return hits }
        guard let anchor else { return Array(hits.prefix(Self.displayCap)) }
        let pivot = hits.firstIndex { !precedes($0, anchor) } ?? hits.count
        let start = min(max(0, pivot - Self.displayCap / 2), hits.count - Self.displayCap)
        return Array(hits[start..<(start + Self.displayCap)])
    }

    /// Document order between two matches: element first, offset second.
    private func precedes(_ a: Match, _ b: Match) -> Bool {
        guard let left = order[a.element], let right = order[b.element] else { return false }
        if left != right { return left < right }
        return a.range.location < b.range.location
    }
}
