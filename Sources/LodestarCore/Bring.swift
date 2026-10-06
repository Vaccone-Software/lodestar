import Foundation

/// Bring: text from your other windows, typed where you are.
///
/// The windows are read by the shell, by accessibility, the moment Bring
/// opens — the one being typed into never, every other one whether it is
/// in front on another display or covered — and held only while Bring is
/// up. This is the pure half: which lines answer a query, in what order,
/// and what a match brings.
public enum Bring {
    /// A window that was read: where it came from, and how recently its
    /// app was in front (0 the most recent).
    public struct Source: Equatable {
        public let app: String
        public let window: String
        public let rank: Int
        public init(app: String, window: String, rank: Int) {
            self.app = app
            self.window = window
            self.rank = rank
        }
    }

    public struct Line: Equatable {
        public let source: Int
        public let text: String
        public init(source: Int, text: String) {
            self.source = source
            self.text = text
        }
    }

    /// One answer: the line, where the query sits in it, and the token
    /// that sits around it — what a plain pick brings.
    public struct Match: Equatable {
        public let source: Int
        public let line: String
        public let hit: NSRange
        public let token: NSRange

        public var tokenText: String { (line as NSString).substring(with: token) }
        public var lineText: String {
            line.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// A query shorter than this finds too much to read and answers
    /// nothing yet.
    public static let minimumQuery = 2
    /// A line longer than this is cut there: a minified page or a log
    /// line is not something a hand brings whole.
    public static let longestLine = 400

    /// The lines a window's text gives: split, trimmed, cut to a length a
    /// card can show, the empty dropped, each once, in reading order.
    public static func lines(of text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = String(raw.prefix(longestLine)).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, seen.insert(line).inserted else { continue }
            out.append(line)
        }
        return out
    }

    /// Every line that holds the query, the most recently used app's
    /// first, a hit at the start of a word before one inside a word, then
    /// reading order. The same line in two windows answers once, from the
    /// more recent. `total` is how many answered before the limit.
    public static func search(_ lines: [Line], sources: [Source], query: String,
                              limit: Int = 64) -> (matches: [Match], total: Int) {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard (needle as NSString).length >= minimumQuery else { return ([], 0) }
        var scored: [(match: Match, rank: Int, inside: Int, order: Int)] = []
        var seen = Set<String>()
        for (order, line) in lines.enumerated() {
            let text = line.text as NSString
            let hit = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive])
            guard hit.location != NSNotFound else { continue }
            let token = SelectCore.bringRange(hit, in: text, size: 0)
            let inside = hit.location > 0
                && (CharacterSet.alphanumerics.contains(UnicodeScalar(text.character(at: hit.location - 1)) ?? " ")) ? 1 : 0
            let rank = sources.indices.contains(line.source) ? sources[line.source].rank : Int.max
            scored.append((Match(source: line.source, line: line.text, hit: hit, token: token), rank, inside, order))
        }
        scored.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.inside != b.inside { return a.inside < b.inside }
            return a.order < b.order
        }
        var out: [Match] = []
        for entry in scored where seen.insert(entry.match.line).inserted {
            out.append(entry.match)
        }
        return (Array(out.prefix(limit)), out.count)
    }
}
