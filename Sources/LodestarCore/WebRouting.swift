import Foundation

/// Pure web-bar routing logic: what the typed text is, and which profile it
/// belongs to. No UI, no browser — testable in isolation.
public enum WebRouting {
    /// Does this input look like a destination rather than a query?
    /// A single token containing a dot (youtube.com, linear.app/team), an
    /// explicit scheme, a machine on your desk (localhost:3000), or a
    /// host:port counts; anything with spaces is a query.
    public static func isDomainLike(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return false }
        if hasScheme(trimmed) { return true }
        guard let host = trimmed.split(separator: "/").first else { return false }
        // A port is as good as a dot: nothing you would search for carries
        // one, and a dev server is the reason you typed it.
        if let port = host.split(separator: ":").dropFirst().first,
           !port.isEmpty, port.allSatisfy(\.isNumber) {
            return true
        }
        if isLocal(host: String(host)) { return true }
        return host.contains(".") && !host.hasPrefix(".") && !host.hasSuffix(".")
    }

    /// Normalize typed input into an openable URL. **https unless the host
    /// is plainly not on the public internet** — loopback, a private
    /// address, one of the local-only suffixes, or a name with no dot in it
    /// at all (a public host needs a TLD, so `api:8000` is someone's
    /// machine). Those get http, because a box on your desk has no
    /// certificate and https is the one guess that could never work.
    /// Everything else, and anything you gave a scheme, is left alone.
    public static func normalize(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if hasScheme(trimmed) { return trimmed }
        let host = bareHost(of: trimmed)
        let local = isLocal(host: host) || !host.contains(".")
        return (local ? "http://" : "https://") + trimmed
    }

    private static func hasScheme(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://")
    }

    /// The host of whatever was typed or clicked, for the observation
    /// layer: the routing fact alone. The path and query are the content
    /// and never leave the URL.
    public static func host(of input: String) -> String? {
        let normalized = normalize(input)
        if let url = URL(string: normalized), let host = url.host?.lowercased(), !host.isEmpty {
            return host
        }
        var stripped = input.trimmingCharacters(in: .whitespaces)
        for scheme in ["https://", "http://"] where stripped.lowercased().hasPrefix(scheme) {
            stripped = String(stripped.dropFirst(scheme.count))
        }
        let bare = bareHost(of: stripped)
        return bare.isEmpty ? nil : bare
    }

    /// The host alone: no path, no port, lowercased.
    private static func bareHost(of input: String) -> String {
        let head = String(input.split(separator: "/").first ?? "")
        return String(head.split(separator: ":").first ?? "").lowercased()
    }

    /// A host that names a machine rather than a site: loopback, a private
    /// address, or one of the suffixes reserved for local use. Deliberately
    /// short — a corporate `.internal` domain is usually served over https,
    /// so guessing http there would break more than it fixed.
    static func isLocal(host: String) -> Bool {
        let bare = bareHost(of: host)
        if ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"].contains(bare) { return true }
        for suffix in [".local", ".localhost", ".test"] where bare.hasSuffix(suffix) {
            return true
        }
        return isPrivateIPv4(bare)
    }

    /// 10/8, 172.16/12, 192.168/16 — the ranges a LAN box lives in.
    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let first = Int(parts[0]), let second = Int(parts[1]) else { return false }
        switch first {
        case 10: return true
        case 172: return (16...31).contains(second)
        case 192: return second == 168
        default: return false
        }
    }

    /// Resolve a routing table against an input. Longest pattern wins, and
    /// ties break by name — deterministic without ordering. A destination
    /// matches on whole host labels; a query matches on whole words.
    public static func route(_ input: String, routes: [String: String]) -> String? {
        routePattern(input, routes: routes).flatMap { routes[$0] }
    }

    /// The pattern that won, rather than what it points at — so a surface can
    /// say *why* a destination is going where it is going.
    ///
    /// The match is bounded, because a substring is how `github.com` swallows
    /// `notgithub.com` and how `ai` hides inside `mail`. A destination is
    /// read as a host — the path and the query are not the site. A pattern
    /// of one label matches any label of that host, so `youtube` still
    /// routes `music.youtube.com` and `ai` does not hide inside `mail`. A
    /// pattern with a dot is a domain: the host is that domain or a
    /// subdomain of it, so `github.com` routes `gist.github.com` and does
    /// not route `notgithub.com`, `mygithub.com.evil.test`, or
    /// `github.com.evil.test`. The same test is also tried with the host's
    /// last label removed, which is how `music.youtube` still routes
    /// `music.youtube.com`. A query has no host, so the boundary is a word:
    /// `acme` routes "acme deploy runbook" and does not route "notacme".
    /// A URL pasted into a query is still a host; its path and query are
    /// not words of the sentence around it.
    public static func routePattern(_ input: String, routes: [String: String]) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        let matches: (String) -> Bool
        if hasScheme(trimmed) || isDomainLike(trimmed) {
            // A URL that does not parse has no host to route on. Falling
            // through to the query rule would search the absolute string,
            // which is the bug.
            guard let host = host(of: trimmed), !host.isEmpty else { return nil }
            matches = { matchesHost(host, pattern: $0) }
        } else {
            matches = { matchesQuery(trimmed, pattern: $0) }
        }
        var best: String?
        for pattern in routes.keys {
            guard matches(pattern.lowercased()) else { continue }
            // Ties broken by name, so the answer never depends on dictionary
            // ordering.
            if let current = best,
               pattern.count < current.count || (pattern.count == current.count && pattern >= current) {
                continue
            }
            best = pattern
        }
        return best
    }

    /// True when `pattern` names `host`. Both are lowercased. A single
    /// label matches any label (`youtube` in `music.youtube.com`). A dotted
    /// pattern is a domain, so the host has to be that domain or a
    /// subdomain of it — a suffix of labels, not a run that merely occurs
    /// inside the name. Empty labels (a leading, trailing, or doubled dot)
    /// are not a run, so they cannot widen the match.
    private static func matchesHost(_ host: String, pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        let patternLabels = pattern.split(separator: ".")
        // `split` drops empty pieces, so ".com" and "github..com" would
        // otherwise collapse into a real label run.
        guard patternLabels.joined(separator: ".") == pattern else { return false }
        let hostLabels = host.split(separator: ".")
        guard !hostLabels.isEmpty else { return false }
        if patternLabels.count == 1 {
            return hostLabels.contains(patternLabels[0])
        }
        if hasSuffixLabels(hostLabels[...], patternLabels) { return true }
        // `music.youtube` is `music.youtube.com` without its last label.
        // One label only: a public suffix of two (`co.uk`) is not guessed.
        guard hostLabels.count > 1 else { return false }
        return hasSuffixLabels(hostLabels.dropLast(), patternLabels)
    }

    private static func hasSuffixLabels(_ host: ArraySlice<Substring>,
                                        _ pattern: [Substring]) -> Bool {
        guard pattern.count <= host.count else { return false }
        return host.suffix(pattern.count).elementsEqual(pattern)
    }

    /// A query, which may have a URL pasted into it. Each URL is matched on
    /// its host; the words around it are matched on word boundaries. The
    /// URL's own path and query never join the sentence.
    private static func matchesQuery(_ text: String, pattern: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        var prose: [String] = []
        for token in text.split(whereSeparator: \.isWhitespace) {
            let word = String(token)
            // A token that contains a scheme is not prose. Its host is read
            // the same way a destination's is, so a pattern in `?next=` is
            // not a word of the sentence it was pasted into.
            if word.contains("://") {
                if let host = host(of: word), matchesHost(host, pattern: pattern) {
                    return true
                }
            } else {
                prose.append(word)
            }
        }
        return matchesWords(prose.joined(separator: " ").lowercased(), pattern: pattern)
    }

    /// True when `pattern` occurs in `text` without starting or ending
    /// mid-word. Both are lowercased. Letters, digits, and underscores are
    /// a word; a space, a hyphen, or a dot ends one.
    private static func matchesWords(_ text: String, pattern: String) -> Bool {
        guard !pattern.isEmpty, !text.isEmpty else { return false }
        var from = text.startIndex
        while let found = text.range(of: pattern, range: from..<text.endIndex) {
            let leftOK = found.lowerBound == text.startIndex
                || !isWord(text[text.index(before: found.lowerBound)])
            let rightOK = found.upperBound == text.endIndex
                || !isWord(text[found.upperBound])
            if leftOK && rightOK { return true }
            from = text.index(after: found.lowerBound)
        }
        return false
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Build a search URL: `%s` is replaced with the encoded query, or the
    /// encoded query is appended when no placeholder exists.
    public static func searchURL(template: String, query: String) -> String {
        // `+` gets the same treatment as `&`: .urlQueryAllowed passes it
        // through, and every form-decoding engine reads a literal `+` as a
        // space — so "c++" searched as typed came back as "c  ".
        let encoded = query.trimmingCharacters(in: .whitespaces)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "&", with: "%26")
            .replacingOccurrences(of: "+", with: "%2B") ?? ""
        if template.contains("%s") {
            return template.replacingOccurrences(of: "%s", with: encoded)
        }
        return template + encoded
    }
}
