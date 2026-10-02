import Foundation

/// Your names put back where the recognizer misheard them, by sound,
/// with precision first: a correct word swapped for a name is worse than
/// a name missed.
///
/// It looks at every run of one to three words and asks whether it
/// sounds like one of your terms ("load star" → Lodestar, "super base" →
/// Supabase, "Cloud Code" → Claude Code). The gates are what make it
/// safe as the list grows, measured on 175 recordings with a list of 312
/// terms: no false swaps with them, 41–49 without.
///
/// - A name within 0.20 of the heard sounds is taken.
/// - A single ordinary word is replaced only when the match is very
///   close (0.10) and the recognizer was unsure of it (below 0.6).
/// - Two or three ordinary words read as one name need a very close match.
/// - It never fuzzes into a term that is itself an ordinary word
///   (Compass, Convex): those are capitalized by context, not by sound.
/// - A run never starts or ends on a function word, and never swallows
///   another of your terms.
///
/// It replaces `Vocabulary`, whose spelling distance turned "ghostly"
/// into Ghostty and "Lodestar 0.39.5" into "Lodestar.39.5".
public struct NameMatcher: Sendable {
    public struct Term: Sendable, Equatable {
        public let text: String
        /// The user's own words outrank terms gathered automatically.
        public let isOwn: Bool
        /// What it sounds like, as written ("Zonar" for Xonar), when the
        /// spelling is no guide. The term's own spelling is always tried.
        public let soundsLike: [String]
        /// Mishearings learned from corrections, lower-cased words.
        public let aliases: [[String]]

        public init(_ text: String, isOwn: Bool = true, soundsLike: [String] = [], aliases: [[String]] = []) {
            self.text = text
            self.isOwn = isOwn
            self.soundsLike = soundsLike
            self.aliases = aliases
        }
    }

    /// One change, for the record and for the marks. Never stored with
    /// its words.
    public struct Edit: Equatable, Sendable {
        public let heard: String
        public let term: String
        public let distance: Double
        public let kind: Kind
        public enum Kind: String, Sendable { case casing, alias, sound }
    }

    struct Entry: Sendable {
        let term: Term
        let lower: String
        let words: [String]
        let phones: [[String]]
        let isCommon: Bool
    }

    public struct Token: Equatable, Sendable {
        public let text: String
        public let confidence: Double?
        public init(_ text: String, confidence: Double? = nil) {
            self.text = text
            self.confidence = confidence
        }
    }

    // Thresholds, as measured.
    static let nameDistance = 0.20
    static let autoDistance = 0.12
    static let commonDistance = 0.10
    static let commonConfidence = 0.60
    static let multiDistance = 0.10
    static let aliasCommonConfidence = 0.9
    static let minimumPhones = 3
    static let minimumAutoPhones = 5

    static let stop: Set<String> = Set("""
        a an the and but or nor so if than that this these those to of in on at for with by from into onto
        about over under up out as is are was were be been am do does did has have had it its it's i i'm we you he she they
        me my your our their his her them us not no yes just very also then there here when where what which who how
        """.split(whereSeparator: \.isWhitespace).map(String.init))

    let entries: [Entry]
    let pronouncer: Pronouncer
    let isCommon: @Sendable (String) -> Bool

    /// `isCommon` says whether a lower-case word is an ordinary English
    /// word; `isFrequent`, whether it is everyday enough that, written as
    /// a name, it is more often meant as the word (Compass, Telegram).
    public init(terms: [Term], pronouncer: Pronouncer, isCommon: @escaping @Sendable (String) -> Bool,
                isFrequent: (@Sendable (String) -> Bool)? = nil) {
        self.pronouncer = pronouncer
        self.isCommon = isCommon
        let isFrequent = isFrequent ?? isCommon
        entries = terms.compactMap { term in
            let text = term.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            let words = text.split(separator: " ").map(String.init)
            var phones = [pronouncer.phones(text)]
            for hint in term.soundsLike where !hint.isEmpty { phones.append(pronouncer.phones(hint)) }
            let camel = text.contains { $0.isUppercase } && text.dropFirst().contains { $0.isUppercase }
                && text.contains { $0.isLowercase }
            let common = !camel && words.allSatisfy { isFrequent($0.lowercased()) }
            return Entry(term: term, lower: text.lowercased(), words: words.map { $0.lowercased() },
                         phones: phones, isCommon: common)
        }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// The text with your terms put back, and what changed.
    public func apply(_ text: String) -> (text: String, edits: [Edit]) {
        apply(tokens: text.split(separator: " ", omittingEmptySubsequences: true).map { Token(String($0)) })
    }

    public func apply(tokens: [Token]) -> (text: String, edits: [Edit]) {
        guard !entries.isEmpty, !tokens.isEmpty else { return (tokens.map(\.text).joined(separator: " "), []) }
        let found = candidates(tokens)
        let chosen = Self.select(found.filter { gate($0) })
        var out = tokens.map(\.text)
        var edits: [Edit] = []
        for c in chosen.sorted(by: { $0.start > $1.start }) {
            let replacement = c.lead + c.entry.term.text + c.possessive + c.trail
            out.replaceSubrange(c.start..<(c.start + c.count), with: [replacement])
            edits.append(Edit(heard: c.surface, term: c.entry.term.text, distance: c.distance, kind: c.kind))
        }
        return (out.joined(separator: " "), edits.reversed())
    }

    // MARK: - Candidates

    struct Candidate {
        let start: Int
        let count: Int
        let entry: Entry
        let distance: Double
        let confidence: Double?
        let kind: Edit.Kind
        let lead: String
        let trail: String
        let possessive: String
        let surface: String
        let allCommon: Bool
    }

    static func split(_ token: String) -> (lead: String, word: String, trail: String) {
        let chars = Array(token)
        var a = 0, b = chars.count
        while a < b, !(chars[a].isLetter || chars[a].isNumber) { a += 1 }
        while b > a, !(chars[b - 1].isLetter || chars[b - 1].isNumber) { b -= 1 }
        return (String(chars[..<a]), String(chars[a..<b]), String(chars[b...]))
    }

    static func isCode(_ word: String) -> Bool {
        word.range(of: #"\w[./]\w"#, options: .regularExpression) != nil
    }

    func common(_ word: String) -> Bool {
        var w = word.lowercased().replacingOccurrences(of: "’", with: "'")
        if w.hasSuffix("'s") { w.removeLast(2) }
        w = w.filter { $0.isLetter || $0.isNumber || $0 == "'" }
        guard !w.isEmpty else { return false }
        if isCommon(w) { return true }
        if w.hasSuffix("s"), isCommon(String(w.dropLast())) { return true }
        if w.hasSuffix("es"), isCommon(String(w.dropLast(2))) { return true }
        if w.hasSuffix("ed"), isCommon(String(w.dropLast(2))) { return true }
        return false
    }

    func candidates(_ tokens: [Token]) -> [Candidate] {
        var out: [Candidate] = []
        let lexiconWords = Set(entries.filter { !$0.lower.contains(" ") }.map(\.lower))
        let parts = tokens.map { Self.split($0.text) }
        for i in tokens.indices {
            for n in 1...3 where i + n <= tokens.count {
                // A run of plain words: no punctuation inside it, no code.
                var ok = true
                for k in 0..<n {
                    let part = parts[i + k]
                    if part.word.isEmpty || !part.word.contains(where: \.isLetter) || Self.isCode(part.word) { ok = false }
                    if k < n - 1, !part.trail.isEmpty { ok = false }
                    if k > 0, !part.lead.isEmpty { ok = false }
                }
                guard ok else { break }
                var words = (0..<n).map { parts[i + $0].word }
                var possessive = ""
                if let last = words.last, last.lowercased().hasSuffix("'s") || last.lowercased().hasSuffix("’s") {
                    possessive = "'s"
                    words[words.count - 1] = String(last.dropLast(2))
                }
                let surface = words.joined(separator: " ")
                let low = words.map { $0.lowercased() }
                let joined = low.joined()
                if n > 1, Self.stop.contains(low[0]) || Self.stop.contains(low[n - 1]) { continue }
                let hits = n > 1 ? low.filter { lexiconWords.contains($0) } : []
                let confidences = (0..<n).compactMap { tokens[i + $0].confidence }
                let confidence = confidences.min()
                let allCommon = words.allSatisfy { common($0) }
                var spanPhones: [String]?
                for entry in entries {
                    if surface == entry.term.text { continue }
                    // A correct term inside the run belongs to that term.
                    if !hits.isEmpty, hits.contains(where: { !entry.lower.contains($0) }) { continue }
                    if n > entry.words.count,
                       (0...(n - entry.words.count)).contains(where: { Array(low[$0..<($0 + entry.words.count)]) == entry.words }) {
                        continue    // "Tell Claude Code" never becomes "Claude Code"
                    }
                    let make = { (distance: Double, kind: Edit.Kind, poss: String) in
                        Candidate(start: i, count: n, entry: entry, distance: distance, confidence: confidence, kind: kind,
                                  lead: parts[i].lead, trail: parts[i + n - 1].trail, possessive: poss,
                                  surface: surface, allCommon: allCommon)
                    }
                    // Casing and joining: "lodestar", "Swift UI", "proton pass".
                    if joined == entry.lower.replacingOccurrences(of: " ", with: "") {
                        // An ordinary word's case needs its context, not this.
                        if entry.isCommon, n == 1, !entry.lower.contains(" ") { continue }
                        if !entry.term.isOwn,
                           !(entry.term.text.range(of: #"[a-z][A-Z]|[A-Z]{2}"#, options: .regularExpression) != nil
                             && surface == surface.lowercased()) { continue }
                        out.append(make(0, .casing, possessive))
                        continue
                    }
                    if !entry.term.aliases.isEmpty, entry.term.aliases.contains(low), joined.count >= 3 {
                        out.append(make(0, .alias, possessive))
                    }
                    if spanPhones == nil { spanPhones = pronouncer.phones(surface) }
                    guard let heard = spanPhones, heard.count >= 2 else { break }
                    if !entry.term.isOwn, common(entry.term.text) || entry.phones[0].count < Self.minimumAutoPhones { continue }
                    var best = 9.0
                    for phones in entry.phones where phones.count >= Self.minimumPhones {
                        let ratio = Double(heard.count) / Double(phones.count)
                        guard ratio >= 0.6, ratio <= 1.6 else { continue }
                        best = min(best, Pronouncer.distance(heard, phones))
                    }
                    var poss = possessive
                    if best > Self.nameDistance, possessive.isEmpty, let last = low.last, last.hasSuffix("s"),
                       !entry.lower.hasSuffix("s") {
                        let singular = pronouncer.phones((words.dropLast() + [String(words.last!.dropLast())]).joined(separator: " "))
                        for phones in entry.phones where phones.count >= Self.minimumPhones {
                            let ratio = Double(singular.count) / Double(phones.count)
                            guard ratio >= 0.6, ratio <= 1.6 else { continue }
                            let d = Pronouncer.distance(singular, phones)
                            if d < best { best = d; poss = "'s" }
                        }
                    }
                    if best <= Self.nameDistance {
                        out.append(make((best * 1000).rounded() / 1000, .sound, poss))
                    }
                }
            }
        }
        return out
    }

    func gate(_ c: Candidate) -> Bool {
        let lexicon = Set(entries.map(\.lower))
        if lexicon.contains(c.surface.lowercased()), c.kind != .casing { return false }
        if c.kind == .casing { return true }
        let confidence = c.confidence ?? 1
        if c.kind == .alias {
            if c.allCommon, c.count == 1 { return false }
            if c.allCommon, confidence >= Self.aliasCommonConfidence { return false }
            return true
        }
        if c.entry.isCommon { return false }
        let limit = c.entry.term.isOwn ? Self.nameDistance : Self.autoDistance
        if c.distance > limit { return false }
        if c.allCommon, !c.entry.term.isOwn { return false }
        if c.allCommon, c.count == 1 {
            return c.distance <= Self.commonDistance && confidence < Self.commonConfidence
        }
        if c.allCommon { return c.distance <= Self.multiDistance }
        return true
    }

    /// No two changes overlap: the closest first, then the shorter run,
    /// then your own terms over gathered ones.
    static func select(_ found: [Candidate]) -> [Candidate] {
        let sorted = found.sorted {
            let a = $0.distance + ($0.entry.term.isOwn ? 0 : 0.1)
            let b = $1.distance + ($1.entry.term.isOwn ? 0 : 0.1)
            return a != b ? a < b : $0.count < $1.count
        }
        var used = Set<Int>()
        var out: [Candidate] = []
        for c in sorted {
            let span = Set(c.start..<(c.start + c.count))
            guard span.isDisjoint(with: used) else { continue }
            used.formUnion(span)
            out.append(c)
        }
        return out
    }
}
