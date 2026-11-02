import AppKit

/// The instant layer: the system's spell checker over finished words.
/// Main thread, as NSSpellChecker asks; a paragraph costs about 1.5 ms.
public enum EditorSpelling {
    /// One document tag for the process: the vocabulary is set on it as
    /// ignored words, so the Mac's own dictionary is never written.
    private static let tag = NSSpellChecker.uniqueSpellDocumentTag()

    public static func issues(in text: String, caret: Int?, language: String,
                              guards: EditorGuards, protected: [NSRange]) -> [EditorIssue] {
        let checker = NSSpellChecker.shared
        checker.setIgnoredWords(ignorable(guards.vocabulary), inSpellDocumentWithTag: tag)
        let ns = text as NSString
        let sentences = EditorText.sentences(in: text)
        var out: [EditorIssue] = []
        var start = 0
        while start < ns.length {
            let range = checker.checkSpelling(of: text, startingAt: start, language: language, wrap: false,
                                              inSpellDocumentWithTag: tag, wordCount: nil)
            guard range.location != NSNotFound, range.length > 0 else { break }
            start = range.location + range.length
            let word = ns.substring(with: range)
            // Unfinished: the word the caret is in or just after. A letter
            // typed next would change it, so it is not a mistake yet.
            if let caret, caret >= range.location, caret <= range.location + range.length { continue }
            if protected.contains(where: { NSIntersectionRange($0, range).length > 0 }) { continue }
            if skips(word) || opens(at: range.location, in: ns) { continue }
            // The first word of its sentence, whatever emoji or dash
            // stands before it.
            let sentenceStart = sentences.contains { sentence in
                NSLocationInRange(range.location, sentence)
                    && !ns.substring(with: NSRange(location: sentence.location, length: range.location - sentence.location))
                        .contains(where: \.isLetter)
            }
            if EditorDiff.isName(word, first: sentenceStart) { continue }
            // A capitalized word on a line of its own, or nearly — the name
            // under a sign-off, the one in a greeting — is a name too.
            if word.first?.isUppercase == true,
               let line = sentences.first(where: { NSLocationInRange(range.location, $0) }),
               ns.substring(with: line).split(whereSeparator: \.isWhitespace).count <= 2 { continue }
            let correction = checker.correction(forWordRange: range, in: text, language: language,
                                                inSpellDocumentWithTag: tag)
            let guesses = checker.guesses(forWordRange: range, in: text, language: language,
                                          inSpellDocumentWithTag: tag) ?? []
            guard let suggestion = fix(for: word, correction: correction, guesses: guesses) else { continue }
            out.append(EditorIssue(range: range, original: word, replacement: suggestion, kind: .spelling))
        }
        return out
    }

    /// Is this word misspelled, by itself? Used to tell a model's typo fix
    /// from its grammar fix, for the label.
    public static func isMisspelled(_ word: String, language: String) -> Bool {
        let range = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                                        inSpellDocumentWithTag: tag, wordCount: nil)
        return range.location != NSNotFound
    }


    /// The fix the checker's answers earn for a word, or nil when the word
    /// is better left alone. The checker is sure of every word it flags and
    /// right about few of them: it flags names, products and jargon, and
    /// when it has no real typo to offer it offers a case, an apostrophe or
    /// a stranger. The writer's casing and punctuation are theirs, so a
    /// word is only marked when the best answer is a typo's repair:
    ///
    /// - Any answer that is the word again in another case or with other
    ///   apostrophes (jeff, github, iphone, dont, im, ive) says the checker
    ///   knows these letters, and what it dislikes is the casing or the
    ///   apostrophe. That is the writer's, so the word is left whole, and
    ///   the other answers (im → in, dont → done) are not taken as the
    ///   repair either.
    /// - A capital the word does not have (jira → Mira) is a name offered
    ///   for a lowercase word.
    /// - A typo is nearly always a slip or two from the word meant: the
    ///   best answer must lie within `allowance` of the word, so priya →
    ///   prayer (three away) is a name, teh → the (one) is a typo.
    static func fix(for word: String, correction: String?, guesses: [String]) -> String? {
        guard let best = correction ?? guesses.first, best != word else { return nil }
        let letters = folded(word)
        if ([best] + guesses).contains(where: { folded($0) == letters }) { return nil }
        if best.first?.isUppercase == true, word.first?.isUppercase != true { return nil }
        let distance = EditorSpelling.distance(Array(word.lowercased()), Array(best.lowercased()))
        return distance <= allowance(forLength: word.count) ? best : nil
    }

    /// How far a repair may lie from the word: a third of its length, one
    /// at least and two at most. Every typo in the tests' list of the
    /// commonest (teh, recieve, seperate, definately, wierd, becuase, adn,
    /// thier, untill, occured) is one slip from its word, a transposition
    /// counting as one; the names and jargon the checker answered with a
    /// stranger were three or more.
    static func allowance(forLength length: Int) -> Int { min(2, max(1, length / 3)) }

    /// A word without its case and its apostrophes, curly or straight.
    static func folded(_ word: String) -> String {
        word.lowercased().filter { $0 != "'" && $0 != "\u{2019}" }
    }

    /// Damerau–Levenshtein distance (optimal string alignment): insertions,
    /// deletions, substitutions and the swap of two neighbours, each one
    /// step, since a swapped pair is the commonest slip a hand makes.
    static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var rows = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { rows[i][0] = i }
        for j in 0...b.count { rows[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                rows[i][j] = min(rows[i - 1][j] + 1, rows[i][j - 1] + 1, rows[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    rows[i][j] = min(rows[i][j], rows[i - 2][j - 2] + 1)
                }
            }
        }
        return rows[a.count][b.count]
    }

    /// What the checker is told to ignore: the vocabulary, and every word
    /// of an entry of several ("Claude Code", "say Vaccone"), since the
    /// checker meets words one at a time and would never match the pair.
    /// The checker's ignored list is not case-sensitive (lowercase
    /// "vaccone" quiets "Vaccone" and "VACCONE"), and the guards already
    /// hold the vocabulary lowercased.
    static func ignorable(_ vocabulary: Set<String>) -> [String] {
        var words = vocabulary
        for entry in vocabulary {
            let parts = entry.split(whereSeparator: \.isWhitespace)
            if parts.count > 1 { words.formUnion(parts.map(String.init)) }
        }
        return Array(words)
    }

    /// A word written as part of something else: a #channel, an @mention,
    /// a /command, a :shortcode:, a $variable or a ~home. The checker
    /// hands back the word without its sigil (it answers "qqmorp" for
    /// "#qqmorp"), so the sigil is read from the text before it. A colon
    /// after a letter ("note:x") never reaches here: the checker takes
    /// that for one word.
    static func opens(at location: Int, in text: NSString) -> Bool {
        guard location > 0, let scalar = UnicodeScalar(text.character(at: location - 1)) else { return false }
        return "#@/$~:".contains(Character(scalar))
    }

    /// Chat's own words: never a spelling mistake in a message.
    static let casual: Set<String> = [
        "lol", "lmao", "np", "ok", "okay", "ty", "thx", "idk", "imo", "imho", "tbh", "btw", "brb", "lmk",
        "fyi", "asap", "omg", "nvm", "wfh", "eod", "eta", "pr", "prs", "lgtm", "afaik", "iirc", "tldr",
        "u", "ur", "pls", "plz", "dm", "dms", "gonna", "wanna", "gotta", "kinda", "sorta", "yeah", "yep",
        "nope", "hmm", "haha", "hahaha", "ya", "yup", "ugh", "rn", "tmrw", "tmr", "sgtm", "wip", "nit", "ack",
        "ptal", "irl", "ooo", "eow", "cc", "fwiw", "ic", "k", "kk",
        "ngl", "tfw", "smh", "ikr", "iykyk", "fomo", "ftw", "yolo", "bc", "cuz", "cus", "tho", "thru",
        "gg", "wtf", "wth", "bruh", "yall", "lemme", "gimme", "dunno", "nah", "meh", "yay", "oof", "aight",
    ]

    /// Tokens that are not prose: chat's words, acronyms, anything with a
    /// digit, camel case, and anything without a vowel (nyc, tbh, pls). A
    /// typo keeps most of its word's letters, so a vowelless token is an
    /// abbreviation, and the checker's answer for one ("nyc" → "nye") is a
    /// stranger.
    static func skips(_ word: String) -> Bool {
        if word.count < 2 { return true }
        if !word.lowercased().contains(where: { "aeiou".contains($0) }) { return true }
        if casual.contains(word.lowercased()) { return true }
        if word.contains(where: \.isNumber) { return true }
        if word == word.uppercased(), word.contains(where: \.isLetter) { return true }
        let inner = word.dropFirst()
        return inner.contains(where: \.isUppercase)
    }
}

/// One field's reading: the model's answers per sentence, kept, and the
/// issues the text has right now.
///
/// The model is asked about a sentence once. Its answer is keyed by the
/// sentence's text, so an edit elsewhere in the field costs nothing, and a
/// sentence that comes back — an undo, a paste — is answered from memory.
public final class EditorSession {
    public var language = "en_US"
    public var guards = EditorGuards()
    /// Each sentence's answer; an inner nil is a question the model did
    /// not answer — asked, so not asked again, but not a reading either:
    /// the spell checker still speaks there.
    private var answers: [String: String?] = [:]
    private var order: [String] = []
    private let capacity = 600
    /// Per-sentence issue lists that the hand dismissed "just once", by
    /// sentence text and range-free identity.
    private var dismissedOnce: Set<String> = []
    private var dismissedOrder: [String] = []

    public init() {}

    /// A model answer for a sentence, kept — or nil, the model had none.
    public func record(sentence: String, corrected: String?) {
        if answers[sentence] == nil {
            order.append(sentence)
            if order.count > capacity { answers[order.removeFirst()] = nil }
        }
        answers[sentence] = .some(corrected)
    }

    public func hasAnswer(for sentence: String) -> Bool { answers[sentence] != nil }

    /// Sentences the model should read now: finished ones without an
    /// answer. A sentence is finished when the caret is past it, or when
    /// it ends in a full stop the caret is beyond, or — after a pause —
    /// whatever holds the caret too.
    public func sentencesToCheck(text: String, caret: Int?, paused: Bool) -> [String] {
        let ns = text as NSString
        let protected = EditorText.protectedRanges(in: text)
        return EditorText.sentences(in: text).compactMap { range in
            let sentence = ns.substring(with: range)
            if EditorText.isForeign(sentence) { return nil }
            guard !hasAnswer(for: sentence), sentence.split(whereSeparator: \.isWhitespace).count >= 2 else { return nil }
            // A sentence that is all code or link has nothing to read.
            if protected.contains(where: { NSIntersectionRange($0, range).length == range.length }) { return nil }
            guard let caret else { return sentence }
            let end = range.location + range.length
            if caret < range.location || caret > end { return sentence }
            if paused { return sentence }
            let last = ns.character(at: end - 1)
            let finished = [".", "!", "?"].contains(Character(UnicodeScalar(last) ?? " "))
            return finished && caret >= end ? sentence : nil
        }
    }

    /// Everything wrong in the text as it stands: the model's corrections
    /// for the sentences it has read, the fixed rules' (a doubled word,
    /// "should of") everywhere, and the spell checker's for finished words
    /// the model has not read. Where two speak about the same words the
    /// model wins, because it read the sentence, and a rule beats the spell
    /// checker, because it knows the phrase.
    public func issues(text: String, caret: Int?) -> [EditorIssue] {
        let ns = text as NSString
        // Sentences in another language are protected like code: read by
        // neither layer.
        let protected = EditorText.protectedRanges(in: text)
            + EditorText.sentences(in: text).filter { EditorText.isForeign(ns.substring(with: $0)) }
        var modelIssues: [EditorIssue] = []
        var read: [NSRange] = []
        for range in EditorText.sentences(in: text) {
            let sentence = ns.substring(with: range)
            guard let answer = answers[sentence], let corrected = answer else { continue }
            // A reply that rewrote or answered the sentence did not read
            // it: the spell checker still speaks there.
            guard EditorDiff.isReading(text: ns, sentence: range, corrected: corrected) else { continue }
            read.append(range)
            for var issue in EditorDiff.issues(text: ns, sentence: range, corrected: corrected,
                                               guards: guards, protected: protected) {
                if issue.original.split(whereSeparator: \.isWhitespace).count == 1,
                   issue.replacement.split(whereSeparator: \.isWhitespace).count == 1,
                   EditorSpelling.isMisspelled(issue.original, language: language) {
                    issue.kind = .spelling
                }
                if !dismissedOnce.contains(Self.onceKey(sentence: sentence, issue: issue)) {
                    modelIssues.append(issue)
                }
            }
        }
        func dismissed(_ issue: EditorIssue) -> Bool {
            guard let sentence = EditorText.sentences(in: text).first(where: {
                NSLocationInRange(issue.range.location, $0) }) else { return false }
            return dismissedOnce.contains(Self.onceKey(sentence: ns.substring(with: sentence), issue: issue))
        }
        let rules = EditorRules.issues(in: text, caret: caret, protected: protected)
            .filter { issue in !modelIssues.contains { NSIntersectionRange($0.range, issue.range).length > 0 } }
            .filter { !dismissed($0) }
        let spelling = EditorSpelling.issues(in: text, caret: caret, language: language,
                                             guards: guards, protected: protected)
            .filter { issue in !(modelIssues + rules).contains { NSIntersectionRange($0.range, issue.range).length > 0 } }
            .filter { issue in
                // A sentence the model read keeps the words it left alone:
                // the spell checker does not overrule a reading that
                // accepted a name or a term.
                !read.contains { NSIntersectionRange($0, issue.range).length > 0 }
            }
            .filter { !dismissed($0) }
        return (modelIssues + rules + spelling).sorted { $0.range.location < $1.range.location }
    }

    /// Kept as written: the issue stays quiet while its sentence stands,
    /// and nothing is learned — edit the sentence and it is read afresh.
    public func dismissOnce(_ issue: EditorIssue, in text: String) {
        let ns = text as NSString
        guard let sentence = EditorText.sentences(in: text).first(where: {
            NSLocationInRange(issue.range.location, $0) }) else { return }
        let key = Self.onceKey(sentence: ns.substring(with: sentence), issue: issue)
        if dismissedOnce.insert(key).inserted {
            dismissedOrder.append(key)
            if dismissedOrder.count > capacity { dismissedOnce.remove(dismissedOrder.removeFirst()) }
        }
    }

    static func onceKey(sentence: String, issue: EditorIssue) -> String {
        "\(sentence)\u{1}\(issue.original)\u{1}\(issue.replacement)"
    }
}
