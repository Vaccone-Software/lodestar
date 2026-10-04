import Foundation

/// The intent pass's checker: a model's rewrite of a dictated text is taken
/// only when every change is one these rules allow. No model, a few
/// milliseconds. A faithful port of the probe's `checker.py`, measured on
/// 2,065 outputs from seven models with no accepted output adding or
/// substituting a content word, and on 8,826 arbitrary deletions from
/// ordinary speech with under 1% let through.
///
/// What may change (anything else rejects the whole output):
///
///   * case, spacing and punctuation (. , ; : ? ! quotes, line breaks);
///   * a separator word becomes its character inside a token: dot -> ".",
///     slash -> "/", underscore -> "_", dash/hyphen -> "-" (a leading "/" or
///     "--" too: "slash compact" -> "/compact"); the words around it may be
///     joined and re-cased ("draft controller dot swift" ->
///     "DraftController.swift"), but no separator may appear that was not
///     spoken, except "-" inside a joined token ("row-level"); "_" must be
///     spoken, and a written token may not hold both a separator and a
///     separator word ("Lodestar_dot_log"). "." only before a known
///     extension or domain ending, a digit, or after an already-dotted token
///     (so "dot product" can never become "dot.product" or ".product");
///   * words joined or split with no letters changed ("read me" -> "README",
///     spelled letters "M E H" -> "meh"); number words <-> digits;
///   * a list layout ("1. ", "- " at a line start) only when the input
///     enumerates (two or more of first/second/third/one/two/three...), and
///     then those enumerating words (and an "and" before the last) may go;
///   * deleted words, but only in runs of these shapes:
///       filler     um, uh, er, hmm ... anywhere
///       discourse  so / well / okay / oh at a sentence start, like / you know
///                  between commas or fillers
///       restart    a short abandoned start the speaker begins again: the run
///                  is <= 4 words, has no and/or/but, and is said again right
///                  after it ("the thing the thing"), or ends at a break
///                  (comma, sentence end, filler) and the words after repeat
///                  its first two words, or its first word when it is two
///                  words or fewer ("to send, to explain" -> "to explain");
///                  a word said twice in a row ("keeps keeps")
///       takeback   the run holds a take-back cue and words follow the run.
///                  After the cue, at most 3 words, each a pronoun-like word
///                  ("I didn't mean him", "actually let's") or a word kept
///                  just before the run (the repair re-saying it). Before the
///                  cue, 1-8 words (up to 30 back to the sentence start after
///                  "scratch that"), and either the repair echoes one of them
///                  within its first 3 words ("the red one, actually no, the
///                  blue one") or they are <= 3 words with no function word
///                  after the first ("three, sorry, four"). Weak cues
///                  (actually, no, hmm) need the echo. A cue right after
///                  what/you/not/that's is talk about meaning ("not what I
///                  meant"), never a take-back.
///       cue        a strong cue alone, only mid-clause with no break before
///                  it ("for I mean Tuesday"); at a boundary never ("make it
///                  bigger, wait, no, make it smaller" must not become "make
///                  it bigger. Make it smaller.")
///       spelled    "capital"/"cap" before a spelled letter or an all-caps word
///       instead    "instead" after a take-back in the same sentence
///   * no more than half of the input's non-filler words may go outside
///     take-backs, and no more than 80% in all.
///
/// Any added or substituted word rejects the output: the caller keeps the
/// input.
public enum IntentChecker {
    public struct Verdict: Equatable {
        public let ok: Bool
        /// Why it was rejected, empty when it was not.
        public let reason: String
        /// What was deleted, by class, for the record.
        public let edits: [Edit]
        public let listItems: Int
    }

    public struct Edit: Equatable {
        public let kind: String
        public let words: [String]
    }

    public static func check(_ input: String, _ output: String, maxDeleteFraction: Double = 0.5) -> Verdict {
        let (I, _) = tokenize(input)
        let (O, markers) = tokenize(output, output: true)
        if O.isEmpty { return Verdict(ok: false, reason: "empty output", edits: [], listItems: 0) }
        guard let (deleted, matches) = align(I, O) else {
            return Verdict(ok: false, reason: "added or changed words", edits: [], listItems: 0)
        }
        let words = I.map(\.w)
        let dset = Set(deleted)
        // Separators: "." only where a file, domain, version or path is plausible.
        for match in matches {
            let (i, j) = (match.i, match.j)
            if O[j].sep, O[j].w == ".", !I[i].sep {
                let after = j + 1 < O.count ? O[j + 1].w : ""
                if !ext.contains(after), !(after.first.map(isDigit) ?? false),
                   !(j >= 2 && O[j - 2].sep && O[j - 2].w == ".") {
                    return Verdict(ok: false, reason: "'.' before '\(after)' is not a file or domain",
                                   edits: [], listItems: 0)
                }
            }
            if O[j].sep, ["/", "_", "-"].contains(O[j].w), !I[i].sep,
               j + 1 >= O.count || (O[j + 1].sep && O[j].w != "-") {
                return Verdict(ok: false, reason: "separator with nothing after it", edits: [], listItems: 0)
            }
        }
        // A written token holding a separator must not also hold a spoken
        // separator word ("Lodestar_dot_log").
        var byRaw: [Int: [Piece]] = [:]
        for p in O { byRaw[p.raw, default: []].append(p) }
        if byRaw.values.contains(where: { ps in
            ps.contains(where: \.sep) && ps.contains(where: { !$0.sep && spokenSeps.contains($0.w) })
        }) {
            return Verdict(ok: false, reason: "separator word left inside a written token", edits: [], listItems: 0)
        }
        // List layout.
        if markers >= 2, I.filter({ enumStrong.contains($0.w) }).count < 2 {
            return Verdict(ok: false, reason: "list layout without a dictated list", edits: [], listItems: 0)
        }
        let listMode = markers >= 2
        // Deleted runs; a gap of free hyphens does not break one.
        var runs: [[Int]] = []
        var cur: [Int] = []
        for i in deleted.sorted() {
            if let last = cur.last, i != last + 1,
               !((last + 1)..<i).allSatisfy({ I[$0].sep && I[$0].optional }) {
                runs.append(cur)
                cur = []
            }
            cur.append(i)
        }
        if !cur.isEmpty { runs.append(cur) }
        let contentTotal = I.filter { !fillers.contains($0.w) && !$0.sep }.count
        var edits: [Edit] = []
        var takebacks: [Int] = []
        for run in runs {
            guard let got = classifySplit(run, I, words, dset, listMode, &takebacks) else {
                return Verdict(ok: false, reason: "deleted words: " + run.map { words[$0] }.joined(separator: " "),
                               edits: edits, listItems: 0)
            }
            edits += got
        }
        // A cap on what goes outside take-backs, which may replace most of a
        // short text.
        let loose = edits.filter { !["takeback", "cue", "filler"].contains($0.kind) }
            .flatMap(\.words).filter { !fillers.contains($0) }.count
        let every = edits.flatMap(\.words).filter { !fillers.contains($0) }.count
        if contentTotal > 0,
           Double(loose) > maxDeleteFraction * Double(contentTotal) || Double(every) > 0.8 * Double(contentTotal) {
            return Verdict(ok: false, reason: "deleted \(every) of \(contentTotal) words", edits: edits, listItems: 0)
        }
        return Verdict(ok: true, reason: "", edits: edits, listItems: markers)
    }

    // MARK: - Words

    static let fillers: Set<String> = ["um", "uh", "uhm", "umm", "uhh", "erm", "er", "ah", "hmm", "hm", "mm", "mhm", "eh"]
    static let discourseStart: Set<String> = ["so", "well", "okay", "ok", "oh", "yeah", "alright"]
    static let discourseComma: Set<String> = ["like"]
    static let conjunctions: Set<String> = ["and", "or", "but"]
    /// Take-back cues, as words after tokenizing (lowercase, numbers as digits).
    static let strongCues: [[String]] = [
        ["no", "wait"], ["wait", "no"], ["wait", "wait"], ["no", "no"], ["i", "mean"], ["i", "meant"],
        ["sorry"], ["or", "rather"], ["rather"], ["i", "didn't", "mean"], ["didn't", "mean"],
        ["not", "that"], ["let", "me", "rephrase"], ["correction"], ["actually", "no"], ["no", "actually"],
        ["make", "that"], ["make", "it"], ["hold", "on"], ["let", "me", "think"], ["wait"],
    ]
    static let scratchCues: [[String]] = [["scratch", "that"], ["never", "mind"], ["nevermind"], ["forget", "that"],
                                          ["forget", "it"], ["delete", "that"], ["strike", "that"]]
    static let weakCues: [[String]] = [["actually"], ["no"], ["hmm"]]
    static let enumerators: Set<String> = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "second", "firstly",
                                           "secondly", "thirdly", "lastly", "finally", "number", "and", "then", "next"]
    static let enumStrong: Set<String> = ["1", "2", "3", "4", "5", "second", "firstly", "secondly", "thirdly"]
    static let ext = Set("""
        swift py js ts tsx jsx json md txt log yml yaml toml sh zsh bash html css scss c h m mm cpp hpp rs go
        java kt rb php plist xcodeproj xcworkspace app dmg zip tar gz png jpg jpeg gif svg pdf csv sql env lock edn clj
        cljs ex exs lua vim conf cfg ini xml wav mp3 mp4 mov ipynb pkl db sqlite strings entitlements xcconfig
        com org net io dev ai co edu gov me xyz so us uk ca de fr app sh tv fm gg ly to
        """.split(whereSeparator: \.isWhitespace).map(String.init))
    static let sepWords: [String: Set<String>] = [
        ".": ["dot", "period", "point"], "/": ["slash"], "_": ["underscore"], "-": ["dash", "hyphen", "minus"],
        "+": ["plus"], "@": ["at"], "~": ["tilde"], ":": ["colon"],
    ]
    static let spokenSeps: Set<String> = sepWords.values.reduce(into: Set<String>()) { $0.formUnion($1) }
    /// A hyphen may join words nobody said "dash" between; "_" must be spoken.
    static let optionalSeps: Set<String> = ["-"]
    static let units: [String: Int] = Dictionary(uniqueKeysWithValues:
        "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen"
            .split(separator: " ").enumerated().map { (String($1), $0) })
    static let tens: [String: Int] = Dictionary(uniqueKeysWithValues:
        "twenty thirty forty fifty sixty seventy eighty ninety"
            .split(separator: " ").enumerated().map { (String($1), 10 * ($0 + 2)) })
    static let ordinals: [String: String] = [
        "first": "one", "third": "three", "fourth": "four", "fifth": "five", "sixth": "six",
        "seventh": "seven", "eighth": "eight", "ninth": "nine", "tenth": "ten", "eleventh": "eleven",
        "twelfth": "twelve", "thirteenth": "thirteen", "fourteenth": "fourteen", "fifteenth": "fifteen",
        "sixteenth": "sixteen", "seventeenth": "seventeen", "eighteenth": "eighteen", "nineteenth": "nineteen",
        "twentieth": "twenty", "thirtieth": "thirty",
    ]
    /// Words a take-back may carry after its cue: "I didn't mean him", "actually let's".
    static let afterCue: Set<String> = ["him", "her", "it", "them", "that", "this", "those", "these", "one", "let's",
                                        "lets", "i", "we", "said", "say", "meant", "mean", "to", "use"]
    static let function = Set("""
        to of in on at for with by from into onto about over under is are was were be the a an and or but
        than as via it this that
        """.split(whereSeparator: \.isWhitespace).map(String.init))
    static let midclauseCues: [[String]] = [["i", "mean"], ["no", "wait"], ["wait", "no"], ["sorry"], ["or", "rather"],
                                            ["actually", "no"], ["no", "actually"]]
    /// "not what I meant": talk about meaning.
    static let metaBefore: Set<String> = ["what", "you", "they", "he", "she", "that's", "not"]

    // MARK: - Tokens

    struct Piece {
        /// Lowercased word, digits for numbers, or the separator character.
        var w: String
        /// A separator character inside a token.
        var sep = false
        /// A separator that may stand for no spoken word ("-").
        var optional = false
        /// Index of the whitespace token it came from.
        var raw = 0
        /// First piece of a sentence.
        var start = false
        var commaBefore = false
        var commaAfter = false
        /// Written in capitals in the input: a spelled word the recognizer joined.
        var caps = false
    }

    private enum Bit { case word, sep, numdot }

    static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let meridiem = regex(#"\b([ap])\.m\.?$"#, .caseInsensitive)
    private static let initials = regex(#"^((?:[A-Za-z]\.){2,})$"#)
    private static let ordinalSuffix = regex(#"(\d+)(st|nd|rd|th)\b"#)
    private static let camel = regex(#"(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])|(?<=\d)(?=[A-Za-z])|(?<=[A-Za-z])(?=\d)"#)
    private static let listMark = regex(#"^\s*(?:[-*•]|\d{1,2}[.)])\s+"#)
    private static let lead = regex(#"^["'(\[{“‘…*]+"#)
    private static let trail = regex(#"["')\]}”’…,;:!?*]+$|\.+$|(?<=[^.])[.]+["')\]}”’]*$"#)
    private static let meridiemEnd = regex(#"\b[ap]\.m\.$"#, .caseInsensitive)
    private static let initialsWhole = regex(#"^(?:[A-Za-z]\.){2,}$"#)
    private static let sentenceEnd = regex(#"[.!?:]"#)
    private static let sentenceStop = regex(#"[.!?]"#)

    private static func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    private static func firstMatch(_ re: NSRegularExpression, in s: String) -> Range<String.Index>? {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)).flatMap { Range($0.range, in: s) }
    }

    /// A token's core, outer punctuation gone, as words and separators.
    private static func splitCore(_ core: String) -> [(String, Bool)] {
        var s = core.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
        s = replace(meridiem, in: s, with: "$1m")
        if firstMatch(initials, in: s) != nil { s = s.replacingOccurrences(of: ".", with: "") }   // U.S. -> US
        s = s.replacingOccurrences(of: "&", with: " and ").replacingOccurrences(of: "%", with: " percent ")
        var out: [(String, Bit)] = []
        let separators: Set<Character> = [".", "/", "_", "-", "+", "@", "~", ":"]
        for part in s.split(whereSeparator: \.isWhitespace) {
            // re.split with a capturing group: text, separator, text, ...
            var bits: [String] = []
            var text = ""
            for c in part {
                if separators.contains(c) {
                    bits.append(text)
                    bits.append(String(c))
                    text = ""
                } else {
                    text.append(c)
                }
            }
            bits.append(text)
            for (k, b) in bits.enumerated() where !b.isEmpty {
                if b.count == 1, separators.contains(b.first!) {
                    let prev = k > 0 ? bits[k - 1] : ""
                    let next = k + 1 < bits.count ? bits[k + 1] : ""
                    let between = (prev.last.map(isDigit) ?? false) && (next.first.map(isDigit) ?? false)
                    if b == ".", between { out.append((".", .numdot)); continue }   // 0.39 stays one number
                    if b == ":", between { continue }                               // 10:30 -> 10 30
                    out.append((b, .sep))
                    continue
                }
                let plain = replace(ordinalSuffix, in: b, with: "$1")
                for w in replace(camel, in: plain, with: " ").split(whereSeparator: \.isWhitespace) {
                    out.append((String(w), .word))
                }
            }
        }
        // Glue digit.digit back together.
        var glued: [(String, Bit)] = []
        for t in out {
            if let last = glued.last, t.1 == .numdot || last.1 == .numdot {
                glued[glued.count - 1] = (last.0 + t.0, t.1 == .numdot ? .numdot : .word)
            } else {
                glued.append(t)
            }
        }
        return glued.map { ($0.0, $0.1 == .sep) }
    }

    /// Number words to digits, and "X point Y" to "X.Y", on plain pieces.
    private static func numbers(_ pieces: [Piece]) -> [Piece] {
        var out: [Piece] = []
        var i = 0
        while i < pieces.count {
            let p = pieces[i]
            let x0 = ordinals[p.w] ?? p.w
            if p.sep || (units[x0] == nil && tens[x0] == nil) {
                out.append(p)
                i += 1
                continue
            }
            var total = 0, current = 0, j = i
            var last: String? = nil
            while j < pieces.count, !pieces[j].sep {
                let x = ordinals[pieces[j].w] ?? pieces[j].w
                if let u = units[x], last == nil || last == "hundred" || last == "thousand" || (last == "tens" && u < 10) {
                    current += u; last = "unit"
                } else if let t = tens[x], last == nil || last == "hundred" || last == "thousand" {
                    current += t; last = "tens"
                } else if x == "hundred", last == "unit" || last == "tens", current < 100 {
                    current *= 100; last = "hundred"
                } else if x == "thousand", last == "unit" || last == "tens" || last == "hundred" {
                    total += current * 1000; current = 0; last = "thousand"
                } else {
                    break
                }
                j += 1
            }
            out.append(Piece(w: String(total + current), raw: p.raw, start: p.start, commaBefore: p.commaBefore,
                             commaAfter: pieces[j - 1].commaAfter))
            i = j
        }
        func allDigits(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy(isDigit) }
        var merged: [Piece] = []
        i = 0
        while i < out.count {
            let p = out[i]
            if !p.sep, allDigits(p.w.replacingOccurrences(of: ".", with: "")), i + 2 < out.count,
               ["point", "dot"].contains(out[i + 1].w), allDigits(out[i + 2].w) {
                var s = p.w, j = i
                while j + 2 < out.count, ["point", "dot"].contains(out[j + 1].w), allDigits(out[j + 2].w) {
                    s += "." + out[j + 2].w
                    j += 2
                }
                merged.append(Piece(w: s, raw: p.raw, start: p.start, commaBefore: p.commaBefore,
                                    commaAfter: out[j].commaAfter))
                i = j + 1
                continue
            }
            merged.append(p)
            i += 1
        }
        return merged
    }

    /// The pieces of a text, and on the output side the list markers taken
    /// off line starts and counted.
    static func tokenize(_ text: String, output: Bool = false) -> ([Piece], Int) {
        var markers = 0
        var raws: [(String, Bool)] = []
        for line in text.components(separatedBy: "\n") {
            var line = line
            if output, let m = firstMatch(listMark, in: line) {
                markers += 1
                line = String(line[m.upperBound...])
            }
            for (k, t) in line.split(whereSeparator: \.isWhitespace).enumerated() {
                raws.append((String(t), k == 0))
            }
        }
        var pieces: [Piece] = []
        var prevEnd: Character = "."
        var prevComma = false
        for (ri, (t, lineStart)) in raws.enumerated() {
            var core = firstMatch(lead, in: t).map { String(t[$0.upperBound...]) } ?? t
            var tail = ""
            if let m = firstMatch(trail, in: core), firstMatch(meridiemEnd, in: core) == nil,
               firstMatch(initialsWhole, in: core) == nil {
                tail = String(core[m.lowerBound...])
                core = String(core[..<m.lowerBound])
            }
            // A token that was only punctuation (", --").
            if core.isEmpty {
                if tail.contains(",") || tail.contains(";") { prevComma = true }
                if firstMatch(sentenceStop, in: tail) != nil { prevEnd = "." }
                continue
            }
            let start = lineStart || ".!?:".contains(prevEnd)
            let parts = splitCore(core)
            guard !parts.isEmpty else { continue }
            let first = pieces.count
            for (k, (w, isSep)) in parts.enumerated() {
                if isSep {
                    pieces.append(Piece(w: w, sep: true,
                                        optional: optionalSeps.contains(w) && 0 < k && k < parts.count - 1, raw: ri))
                } else {
                    let caps = w.count > 1 && w.allSatisfy(\.isLetter) && w == w.uppercased() && w != w.lowercased()
                    pieces.append(Piece(w: w.lowercased(), raw: ri, caps: caps))
                }
            }
            pieces[first].start = start
            pieces[first].commaBefore = prevComma
            pieces[pieces.count - 1].commaAfter = tail.contains(",") || tail.contains(";") || tail.contains("—")
            prevComma = pieces[pieces.count - 1].commaAfter
            prevEnd = tail.last ?? "x"
            if !tail.isEmpty, firstMatch(sentenceEnd, in: tail) != nil { prevEnd = "." }
        }
        return (numbers(pieces), markers)
    }

    // MARK: - Alignment

    struct Match { let i: Int, di: Int, j: Int, dj: Int }

    /// Deletion-only alignment of the output's pieces onto the input's,
    /// where a group of output words may match a group of input words with
    /// the same letters. The input pieces deleted, or nil when an output
    /// piece has no source.
    static func align(_ I: [Piece], _ O: [Piece]) -> (deleted: [Int], matches: [Match])? {
        let n = I.count, m = O.count
        let inf = Int.max / 4
        let width = m + 1
        var dp = [Int](repeating: inf, count: (n + 1) * width)
        var back = [(Int, Int, Int)](repeating: (0, 0, 0), count: (n + 1) * width)   // kind 0 none, 1 del, 2 skip, 3 match
        dp[n * width + m] = 0
        let outLetters = O.map { $0.w.replacingOccurrences(of: "'", with: "") }
        let inLetters = I.map { $0.w.replacingOccurrences(of: "'", with: "") }
        // Lengths as the original counts them, in code points.
        let outLength = outLetters.map(\.unicodeScalars.count)
        let inLength = inLetters.map(\.unicodeScalars.count)
        for i in stride(from: n, through: 0, by: -1) {
            for j in stride(from: m, through: 0, by: -1) {
                if i == n, j == m { continue }
                var best = inf
                var how = (0, 0, 0)
                // Delete an input piece; deletion wins ties, so earlier copies go.
                if i < n {
                    let c = dp[(i + 1) * width + j] + (I[i].sep && I[i].optional ? 0 : 1)
                    if c < best { best = c; how = (1, 1, 0) }
                }
                // An optional output separator stands for no spoken word.
                if j < m, O[j].sep, O[j].optional {
                    let c = dp[i * width + j + 1]
                    if c < best { best = c; how = (2, 0, 1) }
                }
                if i < n, j < m {
                    if O[j].sep || I[i].sep {
                        // Separators: character to character, or character to
                        // its spoken word, either side.
                        let ok = (O[j].sep && I[i].sep && O[j].w == I[i].w)
                            || (O[j].sep && !I[i].sep && (sepWords[O[j].w]?.contains(I[i].w) ?? false))
                            || (I[i].sep && !O[j].sep && (sepWords[I[i].w]?.contains(O[j].w) ?? false))
                        if ok, dp[(i + 1) * width + j + 1] < best {
                            best = dp[(i + 1) * width + j + 1]; how = (3, 1, 1)
                        }
                    } else {
                        // Groups with the same letters.
                        var ostr = "", olen = 0
                        for a in 1...4 {
                            if j + a > m || O[j + a - 1].sep { break }
                            ostr += outLetters[j + a - 1]
                            olen += outLength[j + a - 1]
                            var istr = "", ilen = 0
                            for b in 1..<24 {
                                if i + b > n { break }
                                if I[i + b - 1].sep {
                                    if I[i + b - 1].optional, b > 1 { continue }   // spelled with hyphens: C-O-N-T-R-O-L
                                    break
                                }
                                istr += inLetters[i + b - 1]
                                ilen += inLength[i + b - 1]
                                if ilen > olen { break }
                                if ilen == olen, istr == ostr, a == 1 || b == 1 || a == b, dp[(i + b) * width + j + a] < best {
                                    best = dp[(i + b) * width + j + a]; how = (3, b, a)
                                }
                            }
                        }
                    }
                }
                dp[i * width + j] = best
                back[i * width + j] = how
            }
        }
        guard dp[0] < inf else { return nil }
        var i = 0, j = 0
        var deleted: [Int] = []
        var matches: [Match] = []
        while i != n || j != m {
            let (kind, di, dj) = back[i * width + j]
            if kind == 1, !(I[i].sep && I[i].optional) { deleted.append(i) }
            if kind == 3 { matches.append(Match(i: i, di: di, j: j, dj: dj)) }
            i += di
            j += dj
        }
        return (deleted, matches)
    }

    // MARK: - Deleted runs

    /// A run is fine whole, or as two adjacent fine runs ("so | the thing").
    private static func classifySplit(_ run: [Int], _ I: [Piece], _ words: [String], _ dset: Set<Int>,
                                      _ listMode: Bool, _ takebacks: inout [Int]) -> [Edit]? {
        let ws = run.map { words[$0] }
        if let kind = classify(run, ws, I, words, dset, listMode, &takebacks) {
            return [Edit(kind: kind, words: ws)]
        }
        for s in 1..<max(1, run.count) {
            guard let a = classify(Array(run[..<s]), Array(ws[..<s]), I, words, dset, listMode, &takebacks) else {
                continue
            }
            if let b = classify(Array(run[s...]), Array(ws[s...]), I, words, dset, listMode, &takebacks) {
                return [Edit(kind: a, words: Array(ws[..<s])), Edit(kind: b, words: Array(ws[s...]))]
            }
        }
        return nil
    }

    private static func sentence(of I: [Piece], _ i: Int) -> Int {
        for k in stride(from: i, through: 0, by: -1) where I[k].start { return k }
        return 0
    }

    private static func cue(at k: Int, in words: [String], _ cues: [[String]]) -> Int {
        var best = 0
        for c in cues where k + c.count <= words.count && Array(words[k..<(k + c.count)]) == c {
            best = max(best, c.count)
        }
        return best
    }

    private static func classify(_ run: [Int], _ ws: [String], _ I: [Piece], _ words: [String], _ dset: Set<Int>,
                                 _ listMode: Bool, _ takebacks: inout [Int]) -> String? {
        let core = ws.filter { !fillers.contains($0) }
        if core.isEmpty { return "filler" }
        let n = I.count
        let first = run[0], last = run[run.count - 1]
        let next = ((last + 1)..<max(last + 1, n)).first { !dset.contains($0) && !I[$0].sep }
        // Spelled letters: "capital" before a single letter.
        if core.allSatisfy({ ["capital", "cap", "uppercase"].contains($0) }), let next,
           words[next].count == 1 || I[next].caps {
            return "spelled"
        }
        // Discourse markers.
        if core.count == 1 {
            let w = core[0]
            let k = run[ws.firstIndex(of: w)!]
            if discourseStart.contains(w),
               I[k].start || I[k].commaBefore || (sentence(of: I, k)..<k).allSatisfy({ dset.contains($0) }) {
                return "discourse"
            }
            if discourseComma.contains(w),
               I[k].commaBefore || I[k].commaAfter || (k > 0 && fillers.contains(words[k - 1]))
                || (k + 1 < n && fillers.contains(words[k + 1])) {
                return "discourse"
            }
        }
        if core == ["you", "know"], I[run[0]].commaBefore || I[run[run.count - 1]].commaAfter { return "discourse" }
        if core.count == 2, discourseStart.contains(core[0]), discourseComma.contains(core[1]) { return "discourse" }
        // List enumerators.
        if listMode, core.allSatisfy({ enumerators.contains($0) }) { return "list" }
        // "instead" after a take-back in this sentence.
        if core == ["instead"] {
            let s = sentence(of: I, first)
            if takebacks.contains(where: { s <= $0 && $0 < first }) { return "instead" }
        }
        // A cue alone is never deleted at a boundary: "make it bigger, wait,
        // no, make it smaller" would say both things and lose the sign that
        // one was withdrawn. Mid-clause, with no break before it ("for I mean
        // Tuesday"), its reparandum is already gone and the cue may go too.
        if next != nil, !I[first].start, !I[first].commaBefore, first == 0 || !I[first - 1].commaAfter,
           midclauseCues.contains(core), first == 0 || !metaBefore.contains(words[first - 1]) {
            return "cue"
        }
        // Take-back: the run ends in a cue (<= 3 words after it), a repair follows.
        if let next {
            for k in 0..<ws.count {
                for (group, limit) in [(0, 30), (1, 8), (2, 8)] {
                    let cues = group == 0 ? scratchCues : group == 1 ? strongCues : weakCues
                    let length = cue(at: k, in: ws, cues)
                    if length == 0 { continue }
                    if k > 0, metaBefore.contains(ws[k - 1]) { continue }   // "not what I meant", "you mean"
                    let after = ws[(k + length)...].filter { !fillers.contains($0) }
                    let before = ws[..<k].filter { !fillers.contains($0) }
                    // Words the run carries after its cue: a pronoun ("I didn't
                    // mean him"), or the repair re-saying words kept just before
                    // the run.
                    let keptBefore = Set((max(0, first - 8)..<first).filter { !dset.contains($0) }.map { words[$0] })
                    if after.count > 3 || after.contains(where: { !afterCue.contains($0) && !keptBefore.contains($0) })
                        || before.isEmpty || before.count > limit {
                        continue
                    }
                    if group != 0 {
                        // The repair echoes the words it replaces, or replaces a
                        // short phrase with no function word inside it.
                        let keptAfter = ((last + 1)..<max(last + 1, n)).filter { !dset.contains($0) && !I[$0].sep }
                            .prefix(3).map { words[$0] }
                        let echo = !Set(before).isDisjoint(with: keptAfter)
                        let short = before.count <= 3 && Set(before.dropFirst()).isDisjoint(with: function)
                        if !(echo || short) { continue }
                    }
                    if group == 2 {
                        // A weak cue needs the repair to echo the reparandum
                        // within the next 6 kept words, or the run restarts.
                        let keptAfter = ((last + 1)..<max(last + 1, min(n, last + 12))).filter { !dset.contains($0) }
                            .prefix(6).map { words[$0] }
                        if Set(before).isDisjoint(with: keptAfter), words[next] != ws[0] { continue }
                    }
                    takebacks.append(first)
                    return "takeback"
                }
            }
        }
        if !Set(core).isDisjoint(with: spokenSeps) { return nil }
        // Restart: a short abandoned start begun again. An exact repeat needs
        // nothing more; a start that changes after its first word must be at
        // most two words and end at an audible break.
        if core.contains(where: { $0.count == 1 && $0.allSatisfy(\.isLetter) && $0 != "a" && $0 != "i" }) {
            return nil   // spelled letters are never stutters ("S E E N")
        }
        if let next, core.count <= 4, Set(core).isDisjoint(with: conjunctions) {
            let keptAfter = (next..<n).filter { !dset.contains($0) && !I[$0].sep }.prefix(core.count).map { words[$0] }
            if keptAfter == core { return "restart" }
            let pause = I[last].commaAfter || (last + 1 < n && (I[last + 1].start || fillers.contains(words[last + 1])))
                || fillers.contains(ws[ws.count - 1])
            if core.count <= 2, words[next] == core[0], pause { return "restart" }
            if core.count >= 2, Array(keptAfter.prefix(2)) == Array(core.prefix(2)), pause { return "restart" }
        }
        // A stutter of the word just before the run ("keeps keeps").
        if let prev = stride(from: first - 1, through: 0, by: -1).first(where: { !dset.contains($0) && !I[$0].sep }),
           core.count <= 3 {
            // As the original reads it: an index before the start wraps to the end.
            let from = prev - core.count + 1
            if from >= -words.count,
               (from...prev).map({ words[$0 < 0 ? $0 + words.count : $0] }) == core {
                return "restart"
            }
        }
        return nil
    }
}
