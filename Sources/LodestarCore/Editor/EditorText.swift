import Foundation
import NaturalLanguage

/// What the editor marks: a word or a few that read wrong, with what they
/// should be. Ranges are UTF-16 offsets into the field's text, the unit
/// every accessibility range speaks.
public struct EditorIssue: Equatable, Hashable {
    public enum Kind: String, Codable { case spelling, grammar }

    public var range: NSRange
    public var original: String
    /// What the range becomes: empty for a word that should go.
    public var replacement: String
    public var kind: Kind
    /// What the chip says when the replacement alone would not show the
    /// change — "remove comma" beside a word that looks the same.
    public var note: String?

    public init(range: NSRange, original: String, replacement: String, kind: Kind, note: String? = nil) {
        self.range = range
        self.original = original
        self.replacement = replacement
        self.kind = kind
        self.note = note
    }

    /// What the lens shows beside the letter.
    public var shown: String { note ?? replacement }

    /// The label's short word for what is wrong, shown beside the letter.
    public var label: String {
        if replacement.isEmpty { return "remove" }
        return kind == .spelling ? "spelling" : "grammar"
    }
}

/// The text as the editor reads it: sentences, words, and the spans it
/// never touches.
public enum EditorText {
    /// Sentence ranges, in order, by the system's own tokenizer — which
    /// already knows "Dr." and "e.g." and a URL's dots from a full stop.
    public static func sentences(in text: String) -> [NSRange] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        var out: [NSRange] = []
        // A line break ends a sentence whatever the tokenizer thinks: a
        // list item, a chat line, a greeting above a paragraph.
        var lineStart = 0
        while lineStart <= ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let line = trimmed(lineRange, in: ns)
            if line.length > 0 {
                let piece = ns.substring(with: line)
                let tokenizer = NLTokenizer(unit: .sentence)
                tokenizer.string = piece
                tokenizer.enumerateTokens(in: piece.startIndex..<piece.endIndex) { range, _ in
                    let local = NSRange(range, in: piece)
                    let sentence = trimmed(NSRange(location: line.location + local.location, length: local.length), in: ns)
                    if sentence.length > 0 { out.append(sentence) }
                    return true
                }
            }
            guard lineRange.length > 0, lineRange.location + lineRange.length > lineStart else { break }
            lineStart = lineRange.location + lineRange.length
            if lineStart >= ns.length { break }
        }
        return out
    }

    /// Where a quoted thread begins in an email reply — everything from
    /// there down is someone else's words, and is not read.
    public static func quoteStart(in text: String) -> Int? {
        let ns = text as NSString
        let patterns = [
            "(?m)^On .{3,200}wrote:\\s*$",                  // Apple Mail, Gmail
            "(?m)^-{2,}\\s*Original Message\\s*-{2,}",       // Outlook, older
            "(?m)^_{10,}\\s*$",                              // Outlook's rule
            "(?m)^From: .+\\n(?:.*\\n){0,3}?(?:Sent|Date): ", // a header block
            "(?m)^>",                                         // quoted lines
        ]
        var earliest: Int?
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { continue }
            earliest = min(earliest ?? match.range.location, match.range.location)
        }
        return earliest
    }

    /// A sentence confidently in another language: it is not read — a
    /// Spanish sentence is not an English one full of mistakes.
    public static func isForeign(_ sentence: String) -> Bool {
        guard sentence.split(whereSeparator: \.isWhitespace).count >= 3 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sentence)
        guard let language = recognizer.dominantLanguage, language != .english else { return false }
        return (recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0) > 0.8
    }

    /// A range without the whitespace at either end.
    static func trimmed(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location, end = range.location + range.length
        let space = CharacterSet.whitespacesAndNewlines
        while start < end, let scalar = UnicodeScalar(text.character(at: start)), space.contains(scalar) { start += 1 }
        while end > start, let scalar = UnicodeScalar(text.character(at: end - 1)), space.contains(scalar) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Spans the editor never reads as prose: code between backticks,
    /// links, and email addresses. A mark inside one would be noise.
    public static func protectedRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        // Fenced blocks first, then inline code: a fence's backticks must
        // not pair with an inline span's.
        if let fence = try? NSRegularExpression(pattern: "```[\\s\\S]*?(```|$)") {
            out += fence.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        }
        if let inline = try? NSRegularExpression(pattern: "`[^`\\n]+`") {
            out += inline.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
                .filter { range in !out.contains { NSIntersectionRange($0, range).length > 0 } }
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            out += detector.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        }
        // Emoji shortcodes: :tada:, :+1:.
        if let shortcode = try? NSRegularExpression(pattern: ":[a-z0-9_+-]+:") {
            out += shortcode.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        }
        // A quoted thread below a reply is someone else's.
        if let quote = quoteStart(in: text) {
            out.append(NSRange(location: quote, length: ns.length - quote))
        }
        // Paths and identifiers a detector does not call links:
        // ~/x, ./x, Sources/x.swift, snake_case, dotted.names.
        if let technical = try? NSRegularExpression(pattern: "(?<![\\w])(~|\\.{1,2})?/[\\w./~-]+|\\b[\\w.-]+(?:/[\\w.-]+)+|\\b\\w+_\\w+\\b|\\b\\w+\\.\\w+\\.\\w+\\b") {
            out += technical.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        }
        return out
    }

    /// Whitespace-separated tokens with their ranges.
    static func tokens(in text: NSString, range: NSRange) -> [(String, NSRange)] {
        var out: [(String, NSRange)] = []
        var index = range.location
        let end = range.location + range.length
        let space = CharacterSet.whitespacesAndNewlines
        func isSpace(_ i: Int) -> Bool {
            guard let scalar = UnicodeScalar(text.character(at: i)) else { return false }
            return space.contains(scalar)
        }
        while index < end {
            while index < end, isSpace(index) { index += 1 }
            let start = index
            while index < end, !isSpace(index) { index += 1 }
            if index > start {
                let r = NSRange(location: start, length: index - start)
                out.append((text.substring(with: r), r))
            }
        }
        return out
    }

    /// A token compared the way the filter compares: lowercase letters,
    /// digits and apostrophes, curly or straight.
    static func normalized(_ token: String) -> String {
        String(token.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .filter { $0.isLetter || $0.isNumber || $0 == "'" })
    }
}
