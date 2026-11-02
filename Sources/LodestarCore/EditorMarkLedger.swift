import Foundation

/// The life of every mark the editor puts under a word, kept in memory so
/// that each mark ends in exactly one outcome.
///
/// The record used to count a mark the instant it was placed, keyed by its
/// words and where it stood, so typing before it counted it again, a field
/// that flickered counted every mark again, and a mark withdrawn a second
/// later, or backspaced over two keystrokes after it was drawn, was
/// "shown, not fixed". The ledger gives a mark an identity that survives
/// edits elsewhere in the field (its range is moved through each change
/// by the common prefix and suffix of the old and new text), and writes
/// nothing until the mark ends.
///
/// A mark is *shown* only if it stood a second or more, or the hand
/// answered it: a mark that came and went inside a second was never read.
/// It ends one of six ways: `fixed` (the lens, the card or ⏎), `answered`
/// (kept, or learned), `byHand` (the hand edited its words and they now
/// read as the fix, or no longer read as wrong), `edited` (the hand
/// edited them into something else that still reads wrong), `withdrawn`
/// (the editor dropped it with the words unchanged: the model read the
/// sentence and overruled the spell checker) and `left` (the field was
/// left with it standing). A withdrawn mark was never the hand's to
/// judge, so it is not counted as shown.
///
/// Only kinds and durations leave the ledger. The words it holds for
/// matching are the ones the controller already holds, and none is ever
/// recorded.
public struct EditorMarkLedger {
    /// A mark must stand this long to count as shown.
    public static let stand: TimeInterval = 1.0
    /// A mark the editor stops reporting is given this long to come back
    /// before it is withdrawn: the spell checker skips the word the caret
    /// is in, and a model's answer arrives a beat after the rules'.
    public static let absence: TimeInterval = 3.0

    public enum Outcome: Equatable {
        case fixed(via: String)
        case answered(learned: Bool, via: String)
        case byHand
        case edited
        case withdrawn
        case left
    }

    public struct Ending: Equatable {
        public let kind: EditorIssue.Kind
        public let outcome: Outcome
        /// How long the mark stood, up to the moment it ended (for the
        /// hand's own edits, up to the first keystroke in its words).
        public let stood: TimeInterval

        /// Counted as shown: all but a mark the editor took back itself.
        public var shown: Bool { outcome != .withdrawn }
    }

    public struct Sync {
        public var endings: [Ending] = []
        /// Marks drawn for the first time.
        public var appeared = 0
    }

    private struct Standing {
        let kind: EditorIssue.Kind
        let original: String
        let replacement: String
        var range: NSRange
        let since: Date
        var absentSince: Date?
        /// When the hand first edited the mark's words: from then on the
        /// mark waits for the text to settle.
        var touched: Date?

        func reads(as issue: EditorIssue) -> Bool {
            kind == issue.kind && original == issue.original && replacement == issue.replacement
        }
    }

    private var standing: [Standing] = []

    public init() {}

    public var count: Int { standing.count }

    // MARK: - Edits

    /// The field's text changed from `old` to `new`: every mark moves with
    /// the text before it, and a mark whose words the change touches waits
    /// for the hand to finish (`sync`). A change that merely abuts a mark
    /// (a space after the word) leaves it alone; letters typed against
    /// either end of it are an edit of the word.
    public mutating func edit(from old: String, to new: String, at now: Date) {
        guard old != new, !standing.isEmpty else { return }
        let o = Array(old.utf16), n = Array(new.utf16)
        var p = 0
        while p < o.count, p < n.count, o[p] == n[p] { p += 1 }
        var s = 0
        while s < o.count - p, s < n.count - p, o[o.count - 1 - s] == n[n.count - 1 - s] { s += 1 }
        let oldEnd = o.count - s, newEnd = n.count - s, delta = n.count - o.count
        let inserted = n[p..<newEnd]
        for i in standing.indices {
            let a = standing[i].range.location, b = a + standing[i].range.length
            var touches = p < b && oldEnd > a
            if !touches, p == b, let first = inserted.first, Self.isWordUnit(first) { touches = true }
            if !touches, oldEnd == a, let last = inserted.last, Self.isWordUnit(last) { touches = true }
            if touches {
                let start = min(a, p)
                let end = max(b, oldEnd) + delta
                standing[i].range = NSRange(location: start, length: max(0, end - start))
                if standing[i].touched == nil { standing[i].touched = now }
            } else if oldEnd <= a {
                standing[i].range.location += delta
            }
        }
    }

    private static func isWordUnit(_ unit: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || unit == 0x27 || unit == 0x2019
    }

    // MARK: - Reading the marks

    /// The marks as the editor stands them now. `drawn` are the ones with
    /// a place on the screen, `all` every issue the text has, so a mark
    /// scrolled out of view is not a mark withdrawn. `quiet` is whether
    /// the hand has stopped typing: an edited mark is judged only then.
    /// Answers the marks that ended and how many were drawn for the first
    /// time.
    public mutating func sync(drawn: [EditorIssue], all: [EditorIssue], text: String, caret: Int?,
                              quiet: Bool, at now: Date) -> Sync {
        var result = Sync()
        var claimed = Set<EditorIssue>()
        var live = Array(standing.indices)
        // A mark is the same mark where its words and its place are the
        // same, or, after an edit that left the words as they were, where
        // they still stand inside the span the edit touched.
        for exact in [true, false] {
            for i in live {
                guard let issue = all.first(where: { candidate in
                    !claimed.contains(candidate) && standing[i].reads(as: candidate)
                        && (exact ? candidate.range == standing[i].range
                            : standing[i].touched != nil
                                && NSIntersectionRange(standing[i].range, candidate.range).length == candidate.range.length)
                }) else { continue }
                claimed.insert(issue)
                standing[i].range = issue.range
                standing[i].touched = nil
                standing[i].absentSince = nil
                live.removeAll { $0 == i }
            }
        }
        var ended: [Int] = []
        for i in live {
            let mark = standing[i]
            let inside = caret.map { $0 >= mark.range.location && $0 <= mark.range.location + mark.range.length } ?? false
            if let touched = mark.touched {
                // The word the caret is in is unfinished, and the spell
                // checker does not mark it: wait for the hand to leave,
                // unless the words already read as the fix.
                guard quiet, !inside || Self.current(mark, in: text) == mark.replacement else { continue }
                if let ending = Self.ending(mark, Self.judge(mark, text: text, all: all), until: touched) {
                    result.endings.append(ending)
                }
                ended.append(i)
            } else if inside {
                standing[i].absentSince = nil
            } else {
                let since = standing[i].absentSince ?? now
                standing[i].absentSince = since
                guard now.timeIntervalSince(since) >= Self.absence else { continue }
                let outcome: Outcome = Self.reads(mark, in: text) ? .withdrawn : .edited
                if let ending = Self.ending(mark, outcome, until: since) { result.endings.append(ending) }
                ended.append(i)
            }
        }
        for index in ended.sorted(by: >) { standing.remove(at: index) }
        for issue in drawn where !claimed.contains(issue) {
            standing.append(Standing(kind: issue.kind, original: issue.original, replacement: issue.replacement,
                                     range: issue.range, since: now))
            result.appeared += 1
        }
        return result
    }

    /// The hand answered a mark: a fix, or kept, or learned. The mark was
    /// plainly read, however briefly it stood, so an answer is always
    /// shown.
    public mutating func answer(_ issue: EditorIssue, _ outcome: Outcome, at now: Date) -> Ending {
        let found = standing.firstIndex { $0.reads(as: issue) && $0.range == issue.range }
            ?? standing.firstIndex { $0.reads(as: issue) }
        var stood: TimeInterval = 0
        if let found {
            stood = now.timeIntervalSince(standing[found].since)
            standing.remove(at: found)
        }
        return Ending(kind: issue.kind, outcome: outcome, stood: stood)
    }

    /// The field was left, or the editor switched off: every mark still
    /// standing ends. One the hand was editing is judged on the text as
    /// it was last read.
    public mutating func clear(text: String, all: [EditorIssue], at now: Date) -> [Ending] {
        defer { standing = [] }
        return standing.compactMap { mark in
            if let touched = mark.touched {
                return Self.ending(mark, Self.judge(mark, text: text, all: all), until: touched)
            }
            if let absent = mark.absentSince {
                return Self.ending(mark, Self.reads(mark, in: text) ? .withdrawn : .edited, until: absent)
            }
            return Self.ending(mark, .left, until: now)
        }
    }

    // MARK: - Judging

    /// What the hand's edit made of a mark's words. A spelling mark is
    /// done with when the spell checker no longer finds the word wrong;
    /// a grammar mark only when it reads as the fix, since the model has
    /// not read the sentence again.
    private static func judge(_ mark: Standing, text: String, all: [EditorIssue]) -> Outcome {
        let range = NSIntersectionRange(mark.range, NSRange(location: 0, length: (text as NSString).length))
        if current(mark, in: text) == mark.replacement { return .byHand }
        if mark.kind == .spelling,
           !all.contains(where: { $0.kind == .spelling && NSIntersectionRange($0.range, range).length > 0 }) {
            return .byHand
        }
        return .edited
    }

    /// What stands where the mark stood.
    private static func current(_ mark: Standing, in text: String) -> String {
        let ns = text as NSString
        return ns.substring(with: NSIntersectionRange(mark.range, NSRange(location: 0, length: ns.length)))
    }

    /// Do the mark's words still read as the editor first marked them?
    private static func reads(_ mark: Standing, in text: String) -> Bool {
        current(mark, in: text) == mark.original
    }

    /// The record of a mark that ended `until` some moment, or nothing: a
    /// mark that stood under a second was never read.
    private static func ending(_ mark: Standing, _ outcome: Outcome, until: Date) -> Ending? {
        let stood = until.timeIntervalSince(mark.since)
        guard stood >= stand else { return nil }
        return Ending(kind: mark.kind, outcome: outcome, stood: stood)
    }
}
