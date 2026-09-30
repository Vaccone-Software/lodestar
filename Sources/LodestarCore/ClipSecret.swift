import Foundation

/// A secret in a clip — an API key, a token, a password written after its
/// label, a private key — found so a card can draw its middle as blocks.
///
/// The clip itself is kept whole and searched whole: a key copied from a
/// dashboard was copied to be pasted, and "the one ending a9F2" is how a hand
/// tells two keys apart. What the blocks guard against is the screen: a strip
/// opened during a screen share shows every card to everyone watching, and
/// the one thing on a card that does harm there is a secret. So the ends
/// stay, enough to tell it from its neighbours, and the middle never draws.
///
/// Four readings, in the order they win an overlap:
/// - a private key block, whose body is hidden and whose armour lines stay;
/// - a known format, which keeps its prefix (`sk-proj-`, `ghp_`) and its
///   last characters, the way GitHub and Stripe show a key on their pages;
/// - a value written after a label that names a secret (`password:`,
///   `OPENAI_API_KEY=`, `"client_secret": "…"`, `Bearer …`, a URL's
///   password), which keeps its ends;
/// - a random-looking run of letters and digits, which keeps its ends. Never
///   digits alone, which is an order number or a code, and never hex alone,
///   which is a commit or an identifier the hand meant to paste.
///
/// A password made of words (`Summer2024!`) looks like nothing here unless a
/// label says what it is. That is the honest limit of reading text.
public enum ClipSecret {
    /// A hidden middle in the masked text: a run of full blocks, the same
    /// length for every secret, so it says "hidden" and never how long.
    /// The strip draws one bar where the run stands.
    public static let blocks = String(repeating: "\u{2588}", count: 6)

    public enum Kind: String, Equatable {
        case privateKey, known, labelled, random
    }

    /// One secret: where it is in the text (UTF-16, as the card's
    /// attributed string counts), and how much of each end stays.
    public struct Span: Equatable {
        public let range: NSRange
        public let kind: Kind
        public let head: Int
        public let tail: Int
    }

    /// A text with every secret's middle drawn as blocks, and where the
    /// blocks are, so the card can set them apart.
    public struct Masked: Equatable {
        public let text: String
        public let blocks: [NSRange]
    }

    // MARK: - Reading

    /// Every secret in the text, in order, none overlapping.
    public static func spans(in text: String) -> [Span] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        guard ns.length >= 8 else { return [] }
        var found: [Span] = []
        func take(_ span: Span) {
            guard span.range.length > 0,
                  !found.contains(where: { NSIntersectionRange($0.range, span.range).length > 0 })
            else { return }
            found.append(span)
        }

        for match in privateKey.matches(in: text, range: whole) {
            let body = match.range(at: 3)
            guard body.location != NSNotFound else { continue }
            take(Span(range: body, kind: .privateKey, head: 0, tail: 0))
        }
        for format in formats {
            for match in format.pattern.matches(in: text, range: whole) {
                let range = match.range
                let prefix = format.prefix(ns.substring(with: range))
                let rest = range.length - prefix
                guard format.accepts(ns.substring(with: NSRange(location: range.location + prefix,
                                                                 length: rest))) else { continue }
                take(Span(range: range, kind: .known, head: prefix, tail: ends(rest)))
            }
        }
        for pattern in labelled {
            for match in pattern.matches(in: text, range: whole) {
                let value = match.range(at: 1)
                guard value.location != NSNotFound,
                      isValue(ns.substring(with: value)) else { continue }
                take(Span(range: value, kind: .labelled, head: ends(value.length), tail: ends(value.length)))
            }
        }
        let links = url.matches(in: text, range: whole).map(\.range)
        for match in token.matches(in: text, range: whole) {
            var range = match.range
            // Base64's padding is not part of what tells a key apart.
            while range.length > 0, ns.character(at: range.location + range.length - 1) == 0x3D {
                range.length -= 1
            }
            // A link's path is an address, not a secret: a Google Doc's id
            // is forty random characters the hand means to share. A link's
            // secrets are its password and its labelled parameters, which
            // the labels above have already read.
            guard !links.contains(where: { NSIntersectionRange($0, range).length > 0 }),
                  isRandom(ns.substring(with: range)) else { continue }
            take(Span(range: range, kind: .random, head: ends(range.length), tail: ends(range.length)))
        }
        return found.sorted { $0.range.location < $1.range.location }
    }

    /// The text with each secret's middle replaced by blocks, or nil when
    /// the text holds none.
    public static func masked(_ text: String) -> Masked? {
        let spans = spans(in: text)
        guard !spans.isEmpty else { return nil }
        let ns = text as NSString
        var out = ""
        var ranges: [NSRange] = []
        var cursor = 0
        let blockLength = (blocks as NSString).length
        for span in spans {
            out += ns.substring(with: NSRange(location: cursor, length: span.range.location - cursor))
            out += ns.substring(with: NSRange(location: span.range.location, length: span.head))
            ranges.append(NSRange(location: (out as NSString).length, length: blockLength))
            out += blocks
            out += ns.substring(with: NSRange(location: NSMaxRange(span.range) - span.tail, length: span.tail))
            cursor = NSMaxRange(span.range)
        }
        out += ns.substring(from: cursor)
        return Masked(text: out, blocks: ranges)
    }

    /// How many characters stay at an end of a secret this long: four at
    /// most, and a fifth of it at most, so a short password keeps a
    /// character or two and never most of itself.
    static func ends(_ length: Int) -> Int {
        min(4, length / 5)
    }

    // MARK: - Private keys

    private static let privateKey = regex(
        #"(-----BEGIN ([A-Z0-9 ]*)PRIVATE KEY-----)\s*([\s\S]*?)(?=\s*-----END [A-Z0-9 ]*PRIVATE KEY-----|\s*\z)"#)

    // MARK: - Known formats

    struct Format {
        let pattern: NSRegularExpression
        /// How much of a match is the format's own prefix, which stays.
        let prefix: (String) -> Int
        /// A last word on the body, for prefixes a name could also start with.
        let accepts: (String) -> Bool
    }

    /// A key that starts with one of these is a key: the providers chose
    /// the prefixes so that scanners like this one could find them.
    private static let formats: [Format] = {
        func format(_ prefixes: [String], body: String, accepts: @escaping (String) -> Bool = { _ in true }) -> Format {
            let alternation = prefixes.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            let pattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_\-])(?:"# + alternation + ")" + body)
            return Format(pattern: pattern, prefix: { match in
                prefixes.first(where: { match.hasPrefix($0) }).map { ($0 as NSString).length } ?? 0
            }, accepts: accepts)
        }
        // Longest first within each family, so `sk-proj-` keeps all of
        // itself rather than only `sk-`.
        return [
            format(["sk-ant-api03-", "sk-ant-admin01-", "sk-ant-", "sk-proj-", "sk-svcacct-", "sk-admin-", "sk-"],
                   body: #"[A-Za-z0-9_\-]{20,}"#, accepts: hasDigit),
            format(["sk_live_", "sk_test_", "rk_live_", "rk_test_", "whsec_"], body: #"[A-Za-z0-9]{16,}"#),
            format(["github_pat_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_"], body: #"[A-Za-z0-9_]{30,}"#),
            format(["glpat-"], body: #"[A-Za-z0-9_\-]{20,}"#),
            format(["lin_api_"], body: #"[A-Za-z0-9]{30,}"#),
            format(["xoxb-", "xoxp-", "xoxa-", "xoxr-", "xoxe-", "xapp-"], body: #"[A-Za-z0-9\-]{10,}"#),
            format(["AKIA", "ASIA"], body: #"[A-Z0-9]{16}(?![A-Za-z0-9])"#),
            format(["AIza"], body: #"[A-Za-z0-9_\-]{35}(?![A-Za-z0-9_\-])"#),
            format(["hf_"], body: #"[A-Za-z]{30,}(?![A-Za-z0-9])"#),
            format(["npm_"], body: #"[A-Za-z0-9]{36}(?![A-Za-z0-9])"#),
            format(["pypi-"], body: #"[A-Za-z0-9_\-]{50,}"#),
            format(["dop_v1_", "shpat_", "shpss_", "shpca_"], body: #"[a-f0-9]{32,}"#),
            format(["SG."], body: #"[A-Za-z0-9_\-]{16,}\.[A-Za-z0-9_\-]{16,}"#),
            // Resend, whose prefix is also how a name in snake case starts,
            // so its body has to look like a key and not like words.
            format(["re_"], body: #"[A-Za-z0-9_]{20,}"#, accepts: { isRandom($0) }),
            // A JSON web token: a header and a payload that both begin as
            // JSON objects do in base64, and a signature.
            format(["eyJ"], body: #"[A-Za-z0-9_\-]{8,}\.eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#),
        ]
    }()

    // MARK: - Labelled values

    /// The words a label ends in when what follows it is a secret. A label
    /// must end in one — `tokenizer:` and `max_tokens:` are not secrets —
    /// and may begin however it likes: `OPENAI_API_KEY`, `client_secret`,
    /// `db-password`.
    private static let secretWord =
        #"(?:password|passwd|passphrase|passcode|pwd|secret|token|api[_\-]?key|access[_\-]?key|private[_\-]?key|credentials?)"#

    private static let labelled: [NSRegularExpression] = [
        // `password: x`, `API_KEY=x`, `"client_secret": "x"`, `?access_token=x&`
        regex(#"(?i)(?<![A-Za-z0-9])[A-Za-z0-9_\-]*"# + secretWord
              + #"(?![A-Za-z])["']?[ \t]*[:=][ \t]*["']?([^\s"'`&,;<>)\]}]{4,})"#),
        // `the password is x`
        regex(#"(?i)\b(?:password|passcode|passphrase)\s+is\s+["']?([^\s"'`,;<>]{4,})"#),
        // `Authorization: Bearer x`
        regex(#"(?i)\b(?:bearer|basic)\s+([A-Za-z0-9._~+/\-]{12,}=*)"#),
        // `postgres://user:password@host`
        regex(#"://[^/\s:@]+:([^/\s@]{3,})@"#),
    ]

    /// A value worth hiding: not a placeholder, a reference to where the
    /// secret really lives, or something already hidden.
    static func isValue(_ value: String) -> Bool {
        guard let first = value.first else { return false }
        if "$<{%*•".contains(first) { return false }
        if value.hasPrefix("process.env") || value.hasPrefix("os.environ") || value.hasPrefix("ENV[") {
            return false
        }
        if Set(value).count == 1 { return false }
        let lowered = value.lowercased()
        return !["true", "false", "null", "none", "nil", "required", "optional", "undefined"].contains(lowered)
    }

    // MARK: - Random-looking

    private static let url = regex(#"(?i)\b(?:https?|ftp|wss?)://[^\s<>"']+"#)
    private static let token = regex(#"(?<![A-Za-z0-9_\-+/=.])[A-Za-z0-9_\-+/=]{16,}(?![A-Za-z0-9_\-+/=])"#)

    /// Whether a run of characters reads as random rather than as words,
    /// a path, a number, or an identifier. A key is characters drawn from
    /// letters and digits by chance, which leaves three marks a name does
    /// not: digits among the letters, few repeats, and no words — cut at
    /// every change of case, between a letter and a digit, and at every
    /// separator, a key falls into short pieces, and a name falls into
    /// words.
    public static func isRandom(_ run: String) -> Bool {
        let characters = Array(run.trimmingCharacters(in: ["="]))
        guard characters.count >= 16 else { return false }
        let letters = characters.filter { $0.isASCII && $0.isLetter }.count
        let digits = characters.filter { $0.isASCII && $0.isNumber }.count
        // Digits alone is an order number, a code, a timestamp.
        guard letters > 0, digits > 0 else { return false }
        // Hex alone is a commit, a hash, a UUID — an identifier.
        if characters.allSatisfy({ $0.isHexDigit || $0 == "-" }) { return false }
        // An identifier is built of fields — a date, a version, a record
        // number — and a key is drawn in one piece: three separators or
        // more is a built thing.
        if characters.filter({ $0 == "-" || $0 == "_" }).count >= 3 { return false }
        // A lowercase word and an underscore in front is how an API names
        // its objects — Stripe's `cus_`, Clerk's `user_`, PostHog's `phc_`,
        // a publishable `pk_test_` — and the prefixes that name a secret
        // are read above, as known formats, before this is asked.
        if let underscore = characters.firstIndex(of: "_"), (2...10).contains(underscore),
           characters[..<underscore].allSatisfy({ $0.isASCII && $0.isLowercase }) {
            return false
        }
        let upper = characters.contains { $0.isASCII && $0.isUppercase }
        let lower = characters.contains { $0.isASCII && $0.isLowercase }
        // One case and digits is how licence codes and slugs look too, so
        // it takes more length before it counts.
        if !(upper && lower), characters.count < 20 { return false }
        // Few repeats: a random run of this length is mostly distinct.
        if Double(Set(characters).count) < Double(characters.count) * 0.45 { return false }
        // No words.
        let pieces = pieces(of: characters)
        let wordy = pieces.filter(isWord).reduce(0) { $0 + $1.count }
        return Double(wordy) <= Double(letters + digits) * 0.35
    }

    /// The run cut at separators, at each change between letter and
    /// digit, and where a lowercase letter meets an uppercase one — so
    /// `fetchUserProfile2024` is `fetch`, `User`, `Profile`, `2024`.
    static func pieces(of characters: [Character]) -> [[Character]] {
        var pieces: [[Character]] = []
        var current: [Character] = []
        for c in characters {
            guard c.isASCII, c.isLetter || c.isNumber else {
                if !current.isEmpty { pieces.append(current) }
                current = []
                continue
            }
            if let last = current.last {
                let breaks = last.isNumber != c.isNumber || (last.isLowercase && c.isUppercase)
                if breaks { pieces.append(current); current = [] }
            }
            current.append(c)
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// A piece that reads as a word: four letters or more, lowercase, or
    /// capitalised, or all capitals.
    static func isWord(_ piece: [Character]) -> Bool {
        guard piece.count >= 4, piece.allSatisfy(\.isLetter) else { return false }
        let tail = piece.dropFirst()
        return tail.allSatisfy(\.isLowercase) || piece.allSatisfy(\.isUppercase)
    }

    private static func hasDigit(_ s: String) -> Bool { s.contains(where: \.isNumber) }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern)
    }
}

extension Clipboard.Clip {
    /// The card's text with any secret's middle drawn as blocks, or nil
    /// for the clip that holds none. Text only: an image's caption is read
    /// for search and never drawn.
    public var masked: ClipSecret.Masked? {
        kind == .text ? ClipSecret.masked(preview) : nil
    }
}
