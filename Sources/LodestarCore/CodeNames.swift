import Foundation

/// Names in code, said as words.
///
/// A file or a symbol is said the way a person says it — "draft controller
/// dot swift", "settle ghost as seen", "local slash dev" — and written the
/// way the code has it: `DraftController.swift`, `settleGhostAsSeen`,
/// `local/dev`. Measured on the maker's own voice, spelling a name out
/// ("capital D R A F T…") failed in every recognizer, while the words came
/// through: Apple wrote `draftcontroller.swift`, right but for its
/// capitals. So existing names are found in the repository being talked
/// about (`CodeNames.Index`), and a name that does not exist yet takes a
/// style from one key in the draft (`CodeNames.Style.cycled`).
public enum CodeNames {
    // MARK: - Styles

    /// How a name is written, in the order the key cycles through them.
    public enum Style: CaseIterable, Sendable {
        case words, pascal, camel, snake, kebab, upperSnake
    }

    /// The style a name is written in now.
    public static func style(of text: String) -> Style {
        if text.contains(" ") { return .words }
        if text.contains("_") { return text.contains(where: \.isLowercase) ? .snake : .upperSnake }
        if text.contains("-") { return .kebab }
        if let first = text.first, first.isUppercase, text.dropFirst().contains(where: \.isUppercase) { return .pascal }
        if text.dropFirst().contains(where: \.isUppercase) { return .camel }
        return .words
    }

    /// The name in a style. A trailing spoken extension ("dot swift")
    /// becomes `.swift`, and a run-together word ("draftcontroller") is
    /// split into its words first, by `isWord`.
    public static func restyled(_ text: String, as style: Style, isWord: (String) -> Bool) -> String {
        let (words, ext) = parts(of: text, isWord: isWord)
        guard !words.isEmpty else { return text }
        return written(words, as: style) + ext
    }

    public static func written(_ words: [String], as style: Style) -> String {
        let lower = words.map { $0.lowercased() }
        switch style {
        case .words: return lower.joined(separator: " ")
        case .pascal: return lower.map(capitalized).joined()
        case .camel: return (lower.first ?? "") + lower.dropFirst().map(capitalized).joined()
        case .snake: return lower.joined(separator: "_")
        case .kebab: return lower.joined(separator: "-")
        case .upperSnake: return lower.map { $0.uppercased() }.joined(separator: "_")
        }
    }

    static func capitalized(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }

    /// A name's words and its extension, however it is written now.
    static func parts(of text: String, isWord: (String) -> Bool) -> (words: [String], ext: String) {
        var body = text.trimmingCharacters(in: .whitespaces)
        var ext = ""
        // "draft controller dot swift", "DraftController.swift"
        let spoken = body.components(separatedBy: " dot ")
        if spoken.count == 2, !spoken[1].contains(" ") {
            body = spoken[0]
            ext = "." + spoken[1].lowercased()
        } else if let dot = body.lastIndex(of: "."), !body[body.index(after: dot)...].contains(where: { !$0.isLetter && !$0.isNumber }),
                  dot != body.startIndex {
            ext = String(body[dot...]).lowercased()
            body = String(body[..<dot])
        }
        var words: [String] = []
        for chunk in body.split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" }) {
            words += camelWords(String(chunk))
        }
        // One run-together lower-case word: its dictionary words, if it
        // splits cleanly into them.
        if words.count == 1, let only = words.first, only == only.lowercased(),
           let split = segment(only, isWord: isWord), split.count > 1 {
            words = split
        }
        return (words.map { $0.lowercased() }, ext)
    }

    /// "settleGhostAsSeen" → settle, Ghost, As, Seen; "MLXModel" → MLX, Model.
    static func camelWords(_ word: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(word)
        for (i, c) in chars.enumerated() {
            if !current.isEmpty {
                let prev = current.last!
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if (c.isUppercase && prev.isLowercase) || (c.isUppercase && prev.isUppercase && (next?.isLowercase ?? false))
                    || (c.isNumber != prev.isNumber) {
                    out.append(current)
                    current = ""
                }
            }
            current.append(c)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// A run of letters split into dictionary words, fewest words first;
    /// nil when it does not split cleanly.
    static func segment(_ word: String, isWord: (String) -> Bool) -> [String]? {
        let chars = Array(word)
        let n = chars.count
        guard n >= 4, n <= 40 else { return nil }
        var best: [[String]?] = Array(repeating: nil, count: n + 1)
        best[0] = []
        for end in 1...n {
            for start in stride(from: end - 1, through: 0, by: -1) {
                guard let head = best[start], end - start >= 2 || (end - start == 1 && "ai".contains(chars[start])) else { continue }
                let piece = String(chars[start..<end])
                guard isWord(piece) else { continue }
                let candidate = head + [piece]
                if best[end] == nil || candidate.count < best[end]!.count { best[end] = candidate }
            }
        }
        return best[n]
    }

    // MARK: - Extensions

    /// File extensions a name can end in, said as a word.
    static let extensions: Set<String> = [
        "swift", "py", "md", "json", "ts", "tsx", "js", "jsx", "log", "txt", "yaml", "yml", "toml", "sh", "rs", "go",
        "kt", "java", "rb", "css", "html", "plist", "xml", "csv", "sql", "c", "h", "m", "cpp",
    ]

    /// A name written as code with its extension split off — "ModelStore.
    /// Swift." as a recognizer punctuates it, or "ModelStore dot swift" as
    /// it was said — joined into `ModelStore.swift`. Only after a name that
    /// is plainly code (capitals inside it, a digit or an underscore), so a
    /// sentence that ends and the next one starting "Swift" are left alone.
    public static func joinedExtensions(_ text: String) -> String {
        var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i + 1 < tokens.count {
            let name = NameMatcher.split(tokens[i])
            let codeShaped = name.word.dropFirst().contains(where: \.isUppercase) && name.word.contains(where: \.isLowercase)
                || name.word.contains("_")
            guard codeShaped, !name.word.contains(".") else { i += 1; continue }
            // "ModelStore. Swift."
            if name.trail == ".", let ext = extensionWord(tokens[i + 1]) {
                tokens.replaceSubrange(i...(i + 1), with: [name.lead + name.word + "." + ext.word + ext.trail])
                continue
            }
            // "ModelStore dot swift"
            if name.trail.isEmpty, i + 2 < tokens.count, tokens[i + 1].lowercased() == "dot",
               let ext = extensionWord(tokens[i + 2]) {
                tokens.replaceSubrange(i...(i + 2), with: [name.lead + name.word + "." + ext.word + ext.trail])
                continue
            }
            i += 1
        }
        return tokens.joined(separator: " ")
    }

    private static func extensionWord(_ token: String) -> (word: String, trail: String)? {
        let piece = NameMatcher.split(token)
        let word = piece.word.lowercased()
        guard piece.lead.isEmpty, extensions.contains(word) else { return nil }
        return (word, piece.trail)
    }

    // MARK: - The repository's names

    /// The names a repository already has — its files, its symbols, its
    /// branches — found from how they are said.
    public struct Index: Sendable {
        struct Entry: Sendable {
            let name: String
            let key: String
            let phones: [String]
            let words: Int
        }

        private let byKey: [String: String]
        private let entries: [Entry]
        private let pronouncer: Pronouncer?

        /// Only names shaped like code are kept — inner capitals, a dot, a
        /// slash, an underscore, a hyphen or a digit — so a file called
        /// `Draft` never turns every "draft" into a name.
        public init(names: [String], pronouncer: Pronouncer? = nil) {
            var byKey: [String: String] = [:]
            var entries: [Entry] = []
            for raw in names {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard Self.isCodeShaped(name) else { continue }
                let key = Self.key(name)
                guard key.count >= 5, byKey[key] == nil else { continue }
                byKey[key] = name
                let words = Self.spokenWords(name)
                entries.append(Entry(name: name, key: key, phones: pronouncer?.phones(words.joined(separator: " ")) ?? [],
                                     words: words.count))
            }
            self.byKey = byKey
            self.entries = entries
            self.pronouncer = pronouncer
        }

        public var count: Int { byKey.count }

        static func isCodeShaped(_ name: String) -> Bool {
            guard name.count >= 4, name.count <= 80, !name.contains(" "),
                  name.first.map({ $0.isLetter || $0 == "_" || $0 == "." }) ?? false else { return false }
            let innerCapital = name.dropFirst().contains(where: \.isUppercase) && name.contains(where: \.isLowercase)
            return innerCapital || name.contains { "._/-".contains($0) } || (name.contains(where: \.isNumber) && name.contains(where: \.isLetter))
        }

        /// A name as letters and digits only, lower-cased: what a spoken
        /// form and a written form share.
        static func key(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }

        static func spokenWords(_ name: String) -> [String] {
            name.split(whereSeparator: { "._/-".contains($0) }).flatMap { camelWords(String($0)) }.map { $0.lowercased() }
        }

        /// Spoken separators, dropped when a run of words is compared.
        static let separators: Set<String> = ["dot", "slash", "dash", "hyphen", "underscore"]

        /// The text with each run of words that names something in the
        /// repository written as the code writes it, and how many changed.
        ///
        /// A name written exactly ("draft controller dot swift", or the
        /// recognizer's own `draftcontroller.swift`) is found before one
        /// said almost right ("settle ghost as scene"), and the longest
        /// exact run wins. Everyday phrases that happen to be symbols ("is
        /// running", "set up", "window model") stay prose unless something
        /// says code: a spoken "dot" or "slash", a file or a branch, a word
        /// that is not an everyday one, or three words or more.
        public func apply(_ text: String, isCommon: (String) -> Bool = { _ in false }) -> (text: String, edits: Int) {
            guard !byKey.isEmpty else { return (text, 0) }
            var tokens = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            var edits = 0
            var i = 0
            while i < tokens.count {
                if let hit = exact(at: i, tokens, isCommon: isCommon) ?? soundAlike(at: i, tokens, isCommon: isCommon) {
                    tokens.replaceSubrange(i..<(i + hit.count), with: [hit.text])
                    edits += 1
                }
                i += 1
            }
            return (tokens.joined(separator: " "), edits)
        }

        private struct Span {
            let words: [String]       // as written, punctuation off
            let lowered: [String]
            let spoken: [String]      // without the spoken separators
            let lead: String
            let trail: String
            let separated: Bool       // a spoken separator inside it
        }

        private func span(_ tokens: [String], _ i: Int, _ n: Int) -> Span? {
            let parts = tokens[i..<(i + n)].map { NameMatcher.split($0) }
            if (0..<(n - 1)).contains(where: { !parts[$0].trail.isEmpty }) { return nil }
            if (1..<n).contains(where: { !parts[$0].lead.isEmpty }) { return nil }
            let lowered = parts.map { $0.word.lowercased() }
            guard !lowered.contains(where: \.isEmpty) else { return nil }
            if Self.separators.contains(lowered.first!) || Self.separators.contains(lowered.last!) { return nil }
            let spoken = lowered.filter { !Self.separators.contains($0) }
            return Span(words: parts.map(\.word), lowered: lowered, spoken: spoken, lead: parts[0].lead,
                        trail: parts[n - 1].trail, separated: spoken.count < lowered.count)
        }

        /// An everyday word, endings and all: the system's list has few
        /// plurals ("labels", "keyboards").
        static func everyday(_ word: String, _ isCommon: (String) -> Bool) -> Bool {
            if isCommon(word) { return true }
            for ending in ["s", "es", "ed", "ing", "'s"] where word.hasSuffix(ending) && word.count > ending.count + 2 {
                let stem = String(word.dropLast(ending.count))
                if isCommon(stem) || (ending != "s" && isCommon(stem + "e")) { return true }
            }
            return false
        }

        private func allowed(_ found: String, _ span: Span, isCommon base: (String) -> Bool) -> Bool {
            func isCommon(_ word: String) -> Bool { Self.everyday(word, base) }
            if span.words.count == 1 {
                let word = span.words[0]
                if word == found { return false }
                // One token becomes a name only when it was run together or
                // dotted the way the name is: "modelstore.swift".
                if word.contains(where: { "._/-".contains($0) }) { return true }
                return word == word.lowercased() && word.count >= 8 && !isCommon(word)
            }
            if span.separated || found.contains(".") || found.contains("/") { return true }
            if span.spoken.contains(where: { !isCommon($0) }) { return true }
            return span.spoken.count >= 3
        }

        private func exact(at i: Int, _ tokens: [String], isCommon: (String) -> Bool) -> (text: String, count: Int)? {
            for n in stride(from: min(6, tokens.count - i), through: 1, by: -1) {
                guard let span = span(tokens, i, n), let found = byKey[Self.key(span.spoken.joined())],
                      allowed(found, span, isCommon: isCommon) else { continue }
                return (span.lead + found + span.trail, n)
            }
            return nil
        }

        private func soundAlike(at i: Int, _ tokens: [String], isCommon: (String) -> Bool) -> (text: String, count: Int)? {
            guard let pronouncer else { return nil }
            var best: (d: Double, text: String, count: Int)?
            for n in 3...min(6, max(3, tokens.count - i)) where i + n <= tokens.count {
                guard let span = span(tokens, i, n), span.spoken.count >= 3,
                      !NameMatcher.stop.contains(span.spoken.last!) else { continue }
                let key = Self.key(span.spoken.joined())
                guard key.count >= 8 else { continue }
                let heard = pronouncer.phones(span.spoken.joined(separator: " "))
                for entry in entries where entry.words == span.spoken.count && entry.key.first == key.first {
                    let d = Pronouncer.distance(heard, entry.phones)
                    guard d <= 0.12, best == nil || d < best!.d, allowed(entry.name, span, isCommon: isCommon) else { continue }
                    best = (d, span.lead + entry.name + span.trail, n)
                }
            }
            return best.map { ($0.text, $0.count) }
        }
    }
}
