import Foundation

/// How words sound, for matching a misheard word to a name by sound
/// rather than by spelling: "load star" and Lodestar share almost no
/// letters in order, and all their sounds.
///
/// Apple's own pronunciation API is gone on macOS 27 (every voice
/// answers error -50, measured), so pronunciations come from the CMU
/// Pronouncing Dictionary (BSD, about 134,000 words, shipped with the
/// app) and, for a word it does not have, from its pieces: the longest
/// dictionary words it starts with ("kin" + "dora" for Kindora), then
/// plain English spelling rules for whatever is left. Sounds are ARPAbet
/// phones without stress.
public final class Pronouncer: @unchecked Sendable {
    private var table: [String: [[String]]]
    private let lock = NSLock()
    private var cache: [String: [String]] = [:]

    /// A pronouncer over a dictionary in CMU's format: one word per line,
    /// its phones after it, a variant written `word(2)`, comments after
    /// `#`.
    public init(cmu: String) {
        var table: [String: [[String]]] = [:]
        table.reserveCapacity(140_000)
        for line in cmu.split(separator: "\n", omittingEmptySubsequences: true) {
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            let parts = content.split(separator: " ")
            guard parts.count > 1 else { continue }
            var word = String(parts[0]).lowercased()
            if let paren = word.firstIndex(of: "(") { word = String(word[..<paren]) }
            let phones = parts.dropFirst().map { String($0.filter { !$0.isNumber }) }
            table[word, default: []].append(phones)
        }
        self.table = table
    }

    /// An empty pronouncer: spelling rules only. For tests and as the
    /// fallback when the dictionary is missing.
    public init() { table = [:] }

    public var wordCount: Int { table.count }

    public func knows(_ word: String) -> Bool { table[word.lowercased()] != nil }

    /// The phones of a phrase: each word in turn.
    public func phones(_ phrase: String) -> [String] {
        phrase.split(whereSeparator: { $0 == " " || $0 == "-" }).flatMap { word(String($0)) }
    }

    /// The phones of one word as written: an acronym is said letter by
    /// letter, a camel-cased name in its pieces, anything else from the
    /// dictionary or its pieces.
    public func word(_ raw: String) -> [String] {
        let w = raw.replacingOccurrences(of: "’", with: "'")
        lock.lock()
        if let hit = cache[w] { lock.unlock(); return hit }
        lock.unlock()
        let core = w.filter { $0.isLetter || $0.isNumber || $0 == "'" }
        var out: [String]
        if core.isEmpty {
            out = []
        } else if core.count <= 4, core.allSatisfy({ $0.isUppercase }), core != "I", core != "A" {
            out = core.flatMap { Self.letters[$0] ?? [] }
        } else if let pieces = Self.camelPieces(core), pieces.count > 1 {
            out = pieces.flatMap { word($0) }
        } else if core.allSatisfy(\.isNumber) {
            out = []
        } else {
            let lower = core.lowercased()
            if let known = table[lower]?.first {
                out = known
            } else if lower.hasSuffix("'s"), let known = table[String(lower.dropLast(2))]?.first {
                out = known + ["Z"]
            } else {
                out = composed(lower)
            }
        }
        lock.lock()
        cache[w] = out
        lock.unlock()
        return out
    }

    /// A word the dictionary lacks, from its pieces: the longest
    /// dictionary word it starts with (three letters or more), then the
    /// rest the same way; whatever has no dictionary word is read by
    /// spelling rules. Two equal consonants meeting at a join are one.
    func composed(_ word: String) -> [String] {
        let letters = Array(word)
        guard letters.count >= 3 else { return Self.spelled(word, alone: false) }
        // Two dictionary words that make the whole ("sup" + "abase",
        // "kin" + "dora"): the most even split, then the longer second
        // half.
        var pair: (left: [String], right: [String], score: (Int, Int))?
        if letters.count >= 6 {
            for cut in 3...(letters.count - 3) {
                guard let left = table[String(letters[..<cut])]?.first,
                      let right = table[String(letters[cut...])]?.first else { continue }
                let score = (min(cut, letters.count - cut), letters.count - cut)
                if pair == nil || score > pair!.score { pair = (left, right, score) }
            }
        }
        if let pair { return Self.joined(pair.left, pair.right) }
        // A dictionary word that ends it ("supa" + "base"): the front read
        // by spelling, the longest such ending.
        if letters.count >= 5 {
            for cut in 2...(letters.count - 3) {
                if let right = table[String(letters[cut...])]?.first {
                    return Self.joined(Self.spelled(String(letters[..<cut])), right)
                }
            }
        }
        // Otherwise the longest dictionary word it starts with, then the
        // rest the same way; what has no dictionary word is read by
        // spelling rules.
        var best: (length: Int, phones: [String])?
        for length in stride(from: letters.count - 1, through: 3, by: -1) {
            if let known = table[String(letters[..<length])]?.first {
                best = (length, known)
                break
            }
        }
        guard let best else { return Self.spelled(word) }
        let rest = String(letters[best.length...])
        let tail = rest.count >= 3 ? composed(rest) : Self.spelled(rest, alone: false)
        return Self.joined(best.phones, tail)
    }

    /// Two pieces of one word: equal consonants meeting at the join are one.
    static func joined(_ a: [String], _ b: [String]) -> [String] {
        var out = a
        if let last = out.last, let first = b.first, last == first, !vowels.contains(last) { out.removeLast() }
        return out + b
    }

    static func camelPieces(_ word: String) -> [String]? {
        guard word.contains(where: \.isLowercase), word.dropFirst().contains(where: \.isUppercase) else { return nil }
        var pieces: [String] = []
        var current = ""
        let chars = Array(word)
        for (i, c) in chars.enumerated() {
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            if !current.isEmpty {
                let prev = current.last!
                let boundary = (c.isUppercase && prev.isLowercase)
                    || (c.isUppercase && prev.isUppercase && (next?.isLowercase ?? false))
                    || (c.isNumber != prev.isNumber)
                if boundary { pieces.append(current); current = "" }
            }
            current.append(c)
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    // MARK: - Spelling rules

    static let vowels: Set<String> = ["AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY", "IH", "IY", "OW", "OY", "UH", "UW"]

    static let letters: [Character: [String]] = [
        "A": ["EY"], "B": ["B", "IY"], "C": ["S", "IY"], "D": ["D", "IY"], "E": ["IY"], "F": ["EH", "F"],
        "G": ["JH", "IY"], "H": ["EY", "CH"], "I": ["AY"], "J": ["JH", "EY"], "K": ["K", "EY"], "L": ["EH", "L"],
        "M": ["EH", "M"], "N": ["EH", "N"], "O": ["OW"], "P": ["P", "IY"], "Q": ["K", "Y", "UW"], "R": ["AA", "R"],
        "S": ["EH", "S"], "T": ["T", "IY"], "U": ["Y", "UW"], "V": ["V", "IY"], "W": ["D", "AH", "B", "AH", "L", "Y", "UW"],
        "X": ["EH", "K", "S"], "Y": ["W", "AY"], "Z": ["Z", "IY"],
    ]

    /// English spelling read aloud by rule: digraphs first, a silent
    /// final e that lengthens the vowel before it, long vowels in open
    /// syllables, short ones elsewhere. Rough, and meant to be: it is
    /// only for names the dictionary lacks, and a near sound is enough
    /// for a tolerant match. `alone` says the letters are a whole word
    /// (a word-initial x is a z) rather than the end of one.
    static func spelled(_ word: String, alone: Bool = true) -> [String] {
        let w = Array(word.lowercased().filter { $0.isLetter })
        let isVowel: (Character?) -> Bool = { c in c.map { "aeiou".contains($0) } ?? false }
        var out: [String] = []
        var i = 0
        func at(_ k: Int) -> Character? { k >= 0 && k < w.count ? w[k] : nil }
        func rest(_ k: Int) -> String { k < w.count ? String(w[k...]) : "" }
        // A final e after a consonant is silent and lengthens the vowel before it.
        let magicE = w.count >= 3 && w.last == "e" && !isVowel(at(w.count - 2)) && isVowel(at(w.count - 3))
        while i < w.count {
            let c = w[i]
            let r = rest(i)
            func take(_ n: Int, _ phones: [String]) { out += phones; i += n }
            if r.hasPrefix("tch") { take(3, ["CH"]); continue }
            if r.hasPrefix("sch") { take(3, ["S", "K"]); continue }
            if r.hasPrefix("ch") { take(2, ["CH"]); continue }
            if r.hasPrefix("sh") { take(2, ["SH"]); continue }
            if r.hasPrefix("th") { take(2, ["TH"]); continue }
            if r.hasPrefix("ph") { take(2, ["F"]); continue }
            if r.hasPrefix("wh") { take(2, ["W"]); continue }
            if r.hasPrefix("ck") { take(2, ["K"]); continue }
            if r.hasPrefix("ng") { take(2, ["NG"]); continue }
            if r.hasPrefix("qu") { take(2, ["K", "W"]); continue }
            if r.hasPrefix("gh") { take(2, i == 0 ? ["G"] : []); continue }
            if r.hasPrefix("kn"), i == 0 { take(2, ["N"]); continue }
            if r.hasPrefix("wr"), i == 0 { take(2, ["R"]); continue }
            if r.hasPrefix("dg") { take(2, ["JH"]); continue }
            // Vowel teams.
            if r.hasPrefix("ee") || r.hasPrefix("ea") { take(2, ["IY"]); continue }
            if r.hasPrefix("oo") { take(2, ["UW"]); continue }
            if r.hasPrefix("ou") { take(2, ["AW"]); continue }
            if r.hasPrefix("ow") { take(2, i + 2 >= w.count ? ["OW"] : ["AW"]); continue }
            if r.hasPrefix("ai") || r.hasPrefix("ay") || r.hasPrefix("ei") || r.hasPrefix("ey") && i + 2 < w.count {
                take(2, ["EY"]); continue
            }
            if r.hasPrefix("ey") { take(2, ["IY"]); continue }
            if r.hasPrefix("oa") { take(2, ["OW"]); continue }
            if r.hasPrefix("oi") || r.hasPrefix("oy") { take(2, ["OY"]); continue }
            if r.hasPrefix("au") || r.hasPrefix("aw") { take(2, ["AO"]); continue }
            if r.hasPrefix("ue") || r.hasPrefix("ui") { take(2, ["UW"]); continue }
            if r.hasPrefix("ie"), i + 2 >= w.count { take(2, ["IY"]); continue }
            // R-colored vowels; at the end of a longer word, unstressed.
            let vowelsBefore = w[..<i].filter { "aeiouy".contains($0) }.count
            if (r == "ar" || r == "or" || r == "er"), vowelsBefore >= 1, w.count >= 4 { take(2, ["ER"]); continue }
            if r.hasPrefix("ar") && !isVowel(at(i + 2)) { take(2, ["AA", "R"]); continue }
            if (r.hasPrefix("er") || r.hasPrefix("ir") || r.hasPrefix("ur")) && !isVowel(at(i + 2)) {
                take(2, ["ER"]); continue
            }
            if r.hasPrefix("or") && !isVowel(at(i + 2)) { take(2, ["AO", "R"]); continue }
            // Doubled consonants are one sound.
            if let next = at(i + 1), next == c, !isVowel(c) {
                i += 1; continue
            }
            switch c {
            case "a", "e", "i", "o", "u":
                let last = i == w.count - 1
                if last {
                    if c == "e" { i += 1; continue }        // silent final e
                    take(1, [c == "a" ? "AH" : c == "o" ? "OW" : c == "i" ? "IY" : "UW"]); continue
                }
                let lengthened = magicE && i == w.count - 3
                // An open syllable: one consonant, then a vowel.
                let open = !isVowel(at(i + 1)) && isVowel(at(i + 2)) && at(i + 2) != nil
                if lengthened || open {
                    switch c {
                    case "a": take(1, lengthened ? ["EY"] : ["AA"])
                    case "e": take(1, ["IY"])
                    case "i": take(1, lengthened ? ["AY"] : ["IY"])
                    case "o": take(1, ["OW"])
                    default: take(1, ["UW"])
                    }
                } else {
                    switch c {
                    case "a": take(1, ["AE"])
                    case "e": take(1, ["EH"])
                    case "i": take(1, ["IH"])
                    case "o": take(1, ["AA"])
                    default: take(1, ["AH"])
                    }
                }
            case "y":
                if i == 0 { take(1, ["Y"]) }
                else if i == w.count - 1 { take(1, w.count <= 3 && alone ? ["AY"] : ["IY"]) }
                else { take(1, ["IH"]) }
            case "c": take(1, "eiy".contains(at(i + 1) ?? " ") ? ["S"] : ["K"])
            case "g": take(1, "eiy".contains(at(i + 1) ?? " ") ? ["JH"] : ["G"])
            case "x": take(1, i == 0 && alone ? ["Z"] : ["K", "S"])
            case "j": take(1, ["JH"])
            case "q": take(1, ["K"])
            case "s": take(1, i > 0 && isVowel(at(i - 1)) && isVowel(at(i + 1)) ? ["Z"] : ["S"])
            case "b": take(1, ["B"])
            case "d": take(1, ["D"])
            case "f": take(1, ["F"])
            case "h": take(1, ["HH"])
            case "k": take(1, ["K"])
            case "l": take(1, ["L"])
            case "m": take(1, ["M"])
            case "n": take(1, ["N"])
            case "p": take(1, ["P"])
            case "r": take(1, ["R"])
            case "t": take(1, ["T"])
            case "v": take(1, ["V"])
            case "w": take(1, ["W"])
            case "z": take(1, ["Z"])
            default: i += 1
            }
        }
        return out
    }

    // MARK: - Distance

    private static let near: [String: Double] = {
        let pairs = [("P", "B"), ("T", "D"), ("K", "G"), ("F", "V"), ("S", "Z"), ("TH", "DH"), ("CH", "JH"),
                     ("SH", "ZH"), ("M", "N"), ("N", "NG"), ("L", "R"), ("S", "SH"), ("Z", "ZH"), ("TH", "F"),
                     ("DH", "V"), ("T", "CH"), ("D", "JH"), ("W", "V"), ("Y", "IY"), ("ER", "R")]
        var out: [String: Double] = [:]
        for (a, b) in pairs { out[a + "|" + b] = 0.5; out[b + "|" + a] = 0.5 }
        return out
    }()
    private static let reduced: Set<String> = ["AH", "IH", "ER", "UH", "EH"]

    static func substitution(_ a: String, _ b: String) -> Double {
        if a == b { return 0 }
        if vowels.contains(a), vowels.contains(b) { return reduced.contains(a) || reduced.contains(b) ? 0.3 : 0.5 }
        return near[a + "|" + b] ?? 1
    }

    static func indel(_ a: String) -> Double {
        a == "AH" || a == "IH" || a == "ER" || a == "HH" ? 0.5 : 1
    }

    /// How far apart two pronunciations are: a weighted edit distance
    /// over phones, where near sounds (t and d, an unstressed vowel and
    /// another) cost less than unrelated ones, over the longer length. 0
    /// is the same sounds; 0.2 is about one near-miss in a name.
    public static func distance(_ a: [String], _ b: [String]) -> Double {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return 1 }
        var previous = [Double](repeating: 0, count: m + 1)
        for j in 1...m { previous[j] = previous[j - 1] + indel(b[j - 1]) }
        var current = [Double](repeating: 0, count: m + 1)
        for i in 1...n {
            current[0] = previous[0] + indel(a[i - 1])
            for j in 1...m {
                current[j] = min(previous[j] + indel(a[i - 1]), current[j - 1] + indel(b[j - 1]),
                                 previous[j - 1] + substitution(a[i - 1], b[j - 1]))
            }
            swap(&previous, &current)
        }
        return previous[m] / Double(max(n, m))
    }
}
