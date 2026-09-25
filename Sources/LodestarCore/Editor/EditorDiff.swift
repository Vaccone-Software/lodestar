import Foundation

/// What the editor refuses to change, whatever a model proposes.
public struct EditorGuards: Equatable {
    /// Words never marked: the draft's vocabulary and every name the hand
    /// has taught. Compared lowercased. Grammar is never learned: the same
    /// change is right in one sentence and wrong in the next.
    public var vocabulary: Set<String>

    public init(vocabulary: Set<String> = []) {
        self.vocabulary = Set(vocabulary.map { $0.lowercased() })
    }
}

/// A model's corrected sentence, turned into the few words it changed.
///
/// The model is asked for the whole sentence back, which measured more
/// accurate and faster than asking it for a list of edits; the filter
/// here is what keeps a sentence-writer to word-sized corrections. A
/// change of more than three words is a rewrite and is refused. Case and
/// punctuation the writer chose stand. A capitalized word inside a
/// sentence is a name and is never touched, and neither is anything the
/// hand has taught or anything inside code or a link.
public enum EditorDiff {
    public static let maxBlock = 3

    /// Is the reply a reading of the sentence at all? A reply far longer
    /// than the sentence is talk, and many small changes are one rewrite:
    /// when the model changed more than two words in five, it rewrote the
    /// sentence — or answered it, as a small model will a sentence that
    /// is itself a request. Neither is the editor's to offer, and neither
    /// counts as having read the words.
    public static func isReading(text: NSString, sentence: NSRange, corrected: String) -> Bool {
        let a = EditorText.tokens(in: text, range: sentence).map { EditorText.normalized($0.0) }
        let cleaned = clean(corrected)
        let b = EditorText.tokens(in: cleaned as NSString, range: NSRange(location: 0, length: (cleaned as NSString).length))
            .map { EditorText.normalized($0.0) }
        return isReading(a, b)
    }

    static func isReading(_ na: [String], _ nb: [String]) -> Bool {
        guard !na.isEmpty, !nb.isEmpty, nb.count <= na.count * 3 / 2 + 3 else { return false }
        let changed = opcodes(na, nb).filter { $0.kind != .equal }
            .reduce(0) { $0 + max($1.i2 - $1.i1, $1.j2 - $1.j1) }
        return changed <= max(maxBlock, na.count * 2 / 5)
    }

    public static func issues(text: NSString, sentence: NSRange, corrected: String,
                              guards: EditorGuards, protected: [NSRange]) -> [EditorIssue] {
        let a = EditorText.tokens(in: text, range: sentence)
        let cleaned = clean(corrected)
        let b = EditorText.tokens(in: cleaned as NSString,
                                  range: NSRange(location: 0, length: (cleaned as NSString).length))
        let na = a.map { EditorText.normalized($0.0) }
        let nb = b.map { EditorText.normalized($0.0) }
        guard isReading(na, nb) else { return [] }
        let blocks = opcodes(na, nb)
        // The sentence starts at its first word: an emoji or a list's dash
        // before it does not make that word a name.
        let firstWord = a.firstIndex { $0.0.contains(where: \.isLetter) } ?? 0
        var out: [EditorIssue] = []
        // Words the model kept but punctuated or cased differently. Two
        // kinds are mistakes rather than style, and only these are taken:
        // a comma the model removed (never one it added — adding commas is
        // tidying), and a little word it lowercased mid-sentence ("I like
        // This message"), which is never a name.
        for block in blocks where block.kind == .equal {
            let (writer, model) = (a[block.i1], b[block.j1].0)
            guard let fixed = punctuationOrCaseFix(writer.0, model, first: block.i1 <= firstWord) else { continue }
            if protected.contains(where: { NSIntersectionRange($0, writer.1).length > 0 }) { continue }
            out.append(EditorIssue(range: writer.1, original: writer.0, replacement: fixed.text,
                                   kind: .grammar, note: fixed.note))
        }
        for block in blocks where block.kind != .equal {
            let (i1, i2, j1, j2) = (block.i1, block.i2, block.j1, block.j2)
            guard max(i2 - i1, j2 - j1) <= maxBlock else { continue }
            let src = na[i1..<i2].filter { !$0.isEmpty }.joined(separator: " ")
            let dst = nb[j1..<j2].filter { !$0.isEmpty }.joined(separator: " ")
            guard src != dst else { continue }                       // case or punctuation only
            // A doubled word is a slip whatever its case: "The The".
            func doubled(_ k: Int) -> Bool {
                (k > 0 && na[k] == na[k - 1]) || (k + 1 < na.count && na[k] == na[k + 1])
            }
            if (i1..<i2).contains(where: { isName(a[$0].0, first: $0 <= firstWord) && !doubled($0) }) { continue }
            // A word dropped is the model trimming — "ok so the" to "ok,
            // the" — unless it was doubled.
            if block.kind == .delete, !(i1..<i2).allSatisfy(doubled) { continue }
            // Chat's own words are the writer's register: "gonna" stays.
            if (i1..<i2).contains(where: { EditorSpelling.casual.contains(na[$0]) }) { continue }
            // A hyphen joined or split is house style, not a mistake.
            let rawSrc = a[i1..<i2].map(\.0).joined(), rawDst = b[j1..<j2].map(\.0).joined()
            if rawSrc.contains("-") || rawDst.contains("-"),
               src.replacingOccurrences(of: " ", with: "") == dst.replacingOccurrences(of: " ", with: "") { continue }
            if (i1..<i2).contains(where: { guards.vocabulary.contains(na[$0]) }) { continue }

            // Inserts and deletes are carried by a neighbour, so every
            // issue has a word to stand under and one range to replace.
            var from = i1, to = i2
            var tokens = b[j1..<j2].map(\.0)
            if block.kind == .insert || block.kind == .delete {
                if i2 < a.count {
                    to = i2 + 1
                    tokens = tokens + [a[i2].0]
                } else if i1 > 0 {
                    from = i1 - 1
                    tokens = [a[i1 - 1].0] + tokens
                } else { continue }
            }
            let span = NSRange(location: a[from].1.location,
                               length: a[to - 1].1.location + a[to - 1].1.length - a[from].1.location)
            if protected.contains(where: { NSIntersectionRange($0, span).length > 0 }) { continue }
            var replacement = shaped(tokens, like: Array(a[from..<to].map(\.0)))
            // The writer's apostrophes: a Mac that curls them gets its fix
            // curled, or the fix reads as someone else's typing.
            if curls(text, sentence) { replacement = replacement.replacingOccurrences(of: "'", with: "\u{2019}") }
            let original = text.substring(with: span)
            guard replacement != original else { continue }
            out.append(EditorIssue(range: span, original: original, replacement: replacement,
                                   kind: .grammar))
        }
        return out
    }

    /// Does the writer curl apostrophes? Their sentence says so if it has
    /// any; otherwise the rest of the field does.
    static func curls(_ text: NSString, _ sentence: NSRange) -> Bool {
        let own = text.substring(with: sentence)
        if own.contains("\u{2019}") { return true }
        if own.contains("'") { return false }
        return text.range(of: "\u{2019}").location != NSNotFound
    }

    /// Little words that are practically never names: a capital on one of
    /// these mid-sentence is a slip.
    static let closedClass: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "my", "your", "his", "her", "its", "our",
        "their", "is", "are", "was", "were", "be", "been", "am", "and", "or", "but", "of", "to", "in",
        "on", "at", "for", "with", "from", "by", "as", "it", "we", "you", "he", "she", "they", "me",
        "him", "us", "them", "so", "if", "then", "than", "not", "no", "do", "does", "did", "have", "has",
        "had", "would", "can", "could", "should", "just", "very", "some", "any", "all",
    ]

    /// The writer's token fixed as the model fixed it, when the difference
    /// is a removed comma or semicolon or a lowercased little word.
    static func punctuationOrCaseFix(_ writer: String, _ model: String, first: Bool) -> (text: String, note: String)? {
        var text = writer
        var notes: [String] = []
        let writerTail = String(writer.reversed().prefix { !$0.isLetter && !$0.isNumber && $0 != "'" }.reversed())
        let modelTail = String(model.reversed().prefix { !$0.isLetter && !$0.isNumber && $0 != "'" }.reversed())
        // Removed, not replaced: a comma the model turned into a full stop
        // split the sentence, which is a rewrite, not a stray comma.
        let replaced = modelTail.contains { ".;:!?".contains($0) }
        for mark in [",", ";"] where writerTail.contains(mark) && !modelTail.contains(mark) && !replaced {
            if let at = text.lastIndex(of: Character(mark)) { text.remove(at: at) }
            notes.append(mark == "," ? "remove comma" : "remove semicolon")
        }
        if !first, let w = writer.first(where: \.isLetter), w.isUppercase,
           let m = model.first(where: \.isLetter), m.isLowercase,
           closedClass.contains(EditorText.normalized(writer)), writer.filter(\.isLetter).count > 1 {
            if let index = text.firstIndex(where: \.isLetter) {
                text.replaceSubrange(index...index, with: String(text[index]).lowercased())
            }
            notes.append("lowercase")
        }
        return notes.isEmpty || text == writer ? nil : (text, notes.joined(separator: ", "))
    }

    /// A capitalized word past a sentence's start: a name, the editor's
    /// most common false alarm and its most expensive one.
    static func isName(_ token: String, first: Bool) -> Bool {
        guard !first, let letter = token.first(where: \.isLetter), letter.isUppercase else { return false }
        let bare = token.filter(\.isLetter)
        return !(bare == "I" || token.hasPrefix("I'") || token.hasPrefix("I\u{2019}"))
    }

    /// The model's words, dressed as the writer's: the original's leading
    /// and trailing punctuation kept, and its casing at the start.
    static func shaped(_ tokens: [String], like original: [String]) -> String {
        guard var words = Optional(tokens), !words.isEmpty, let first = original.first,
              let last = original.last else { return tokens.joined(separator: " ") }
        let lead = String(first.prefix { !$0.isLetter && !$0.isNumber })
        let tail = String(last.reversed().prefix { !$0.isLetter && !$0.isNumber && $0 != "'" }.reversed())
        words[0] = String(words[0].drop { !$0.isLetter && !$0.isNumber })
        let lastIndex = words.count - 1
        while let c = words[lastIndex].last, !c.isLetter, !c.isNumber, c != "'" { words[lastIndex].removeLast() }
        // Casing follows the writer at the first letter, sentence start
        // included: a lowercase message is a style, not a mistake.
        if let writerFirst = first.first(where: \.isLetter), let modelFirst = words[0].first,
           words[0] != words[0].uppercased() || words[0].count == 1 {
            if writerFirst.isLowercase, modelFirst.isUppercase {
                words[0] = words[0].prefix(1).lowercased() + words[0].dropFirst()
            } else if writerFirst.isUppercase, modelFirst.isLowercase {
                words[0] = words[0].prefix(1).uppercased() + words[0].dropFirst()
            }
        }
        return lead + words.joined(separator: " ") + tail
    }

    /// The reply as a sentence: without a label, quotes, or a thinking
    /// block a model may add.
    static func clean(_ reply: String) -> String {
        var s = reply
        if let close = s.range(of: "</think>") { s = String(s[close.upperBound...]) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Corrected text:", "Corrected:", "Here is the corrected text:"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.count > 1, let f = s.first, let l = s.last, (f == "\"" && l == "\"") || (f == "\u{201C}" && l == "\u{201D}") {
            s = String(s.dropFirst().dropLast())
        }
        // One line: a model that answers in paragraphs is not correcting.
        return s.components(separatedBy: .newlines).first ?? s
    }

    // MARK: - The diff

    struct Opcode: Equatable {
        enum Kind { case equal, replace, delete, insert }
        let kind: Kind
        let i1: Int, i2: Int, j1: Int, j2: Int
    }

    /// Word-level opcodes by longest common subsequence — the sentences
    /// are short, so the quadratic table costs nothing.
    static func opcodes(_ a: [String], _ b: [String]) -> [Opcode] {
        let n = a.count, m = b.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var matches: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] { matches.append((i, j)); i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { i += 1 } else { j += 1 }
        }
        var out: [Opcode] = []
        var ai = 0, bj = 0
        for (mi, mj) in matches + [(n, m)] {
            if ai < mi || bj < mj {
                let kind: Opcode.Kind = ai < mi && bj < mj ? .replace : ai < mi ? .delete : .insert
                out.append(Opcode(kind: kind, i1: ai, i2: mi, j1: bj, j2: mj))
            }
            if mi < n, mj < m { out.append(Opcode(kind: .equal, i1: mi, i2: mi + 1, j1: mj, j2: mj + 1)) }
            ai = mi + 1; bj = mj + 1
        }
        return out
    }
}
