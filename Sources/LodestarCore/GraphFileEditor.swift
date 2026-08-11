import Foundation

/// Surgical edits to the `graph:` section of lodestar.yaml: insert or
/// remove one path while every other byte of the file — comments above
/// all — survives untouched. There is no serializer on purpose; a parse →
/// mutate → dump round trip would strip the comments that make the file
/// teachable, so edits are line insertions and deletions only.
public enum GraphFileEditor {
    public enum EditError: Error, Equatable, CustomStringConvertible {
        case noGraphSection
        /// An existing leaf sits on the path — nothing can live past it.
        case blockedByLeaf(String)
        case taken(String)
        case missing(String)

        public var description: String {
            switch self {
            case .noGraphSection: return "the config has no graph section"
            case .blockedByLeaf(let path): return "hyper \(path) is already a destination"
            case .taken(let path): return "hyper \(path) is already bound"
            case .missing(let path): return "hyper \(path) is not in the config"
            }
        }
    }

    /// Insert `letters` → `target` as a new leaf, nested at its alphabetical
    /// spot, creating intermediate branch lines as needed. Free paths only:
    /// the exact path and every prefix must not already be a leaf.
    public static func addingPath(_ letters: [String], target: String, in text: String) throws -> String {
        precondition(!letters.isEmpty)
        var raw = text.components(separatedBy: "\n")
        let lines = raw.map(analyze)
        guard let section = sectionRange(in: lines) else { throw EditError.noGraphSection }

        var range = section.body
        var parentIndent = lines[section.header].indent
        var depth = 0
        while true {
            let level = entries(in: lines, range: range)
            let levelIndent = level.first.map { lines[$0.line].indent } ?? parentIndent + 2
            let letter = letters[depth]

            if let hit = level.first(where: { $0.key.lowercased() == letter }) {
                let walked = describe(Array(letters[...depth]))
                if depth == letters.count - 1 { throw EditError.taken(walked) }
                if hit.hasValue { throw EditError.blockedByLeaf(walked) }
                range = hit.body
                parentIndent = levelIndent
                depth += 1
                continue
            }
            // A multi-letter sugar key here can hold the exact remaining chain.
            let remaining = letters[depth...].joined()
            if level.contains(where: { $0.key.lowercased() == remaining && $0.hasValue }) {
                throw EditError.taken(describe(letters))
            }

            // Free from here: the remaining letters become new lines.
            let step = level.isEmpty ? 2 : max(1, levelIndent - parentIndent)
            var inserted: [String] = []
            var indent = levelIndent
            for (offset, l) in letters[depth...].enumerated() {
                let pad = String(repeating: " ", count: indent)
                if depth + offset == letters.count - 1 {
                    inserted.append("\(pad)\(l): \(escaped(target))")
                } else {
                    inserted.append("\(pad)\(l):")
                    indent += step
                }
            }
            let at: Int
            if let next = level.first(where: { $0.key.lowercased() > letter }) {
                // Comments directly above the displaced sibling stay glued to it.
                var line = next.line
                while line > range.lowerBound, lines[line - 1].key == nil,
                      !raw[line - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    line -= 1
                }
                at = line
            } else if let last = level.last {
                at = last.body.upperBound
            } else {
                at = range.lowerBound
            }
            raw.insert(contentsOf: inserted, at: at)
            return raw.joined(separator: "\n")
        }
    }

    /// Remove the leaf at `letters`, then prune every ancestor branch the
    /// deletion left childless — a chain that leads nowhere teaches nothing.
    public static func deletingPath(_ letters: [String], in text: String) throws -> String {
        precondition(!letters.isEmpty)
        let raw = text.components(separatedBy: "\n")
        let lines = raw.map(analyze)
        guard let section = sectionRange(in: lines) else { throw EditError.noGraphSection }

        var range = section.body
        var depth = 0
        var ancestors: [Entry] = []
        var leaf: Entry?
        while leaf == nil {
            let level = entries(in: lines, range: range)
            // The whole remaining chain may live on one sugar line ("ep: X").
            let remaining = letters[depth...].joined()
            if let sugar = level.first(where: { $0.key.lowercased() == remaining && $0.hasValue }) {
                leaf = sugar
                break
            }
            guard let hit = level.first(where: { $0.key.lowercased() == letters[depth] }),
                  hit.hasValue == (depth == letters.count - 1)
            else { throw EditError.missing(describe(letters)) }
            if depth == letters.count - 1 {
                leaf = hit
            } else {
                ancestors.append(hit)
                range = hit.body
                depth += 1
            }
        }

        var doomed: Set<Int> = [leaf!.line]
        for ancestor in ancestors.reversed() {
            let survivors = entries(in: lines, range: ancestor.body)
                .filter { !doomed.contains($0.line) }
            guard survivors.isEmpty else { break }
            // The body is now only the doomed subtree and its comments.
            doomed.insert(ancestor.line)
            ancestor.body.forEach { doomed.insert($0) }
        }
        return raw.enumerated()
            .filter { !doomed.contains($0.offset) }
            .map(\.element)
            .joined(separator: "\n")
    }

    // MARK: - Line model

    private struct Line {
        let indent: Int
        /// nil for blank, comment-only, or non-mapping lines.
        let key: String?
        let hasValue: Bool
    }

    private struct Entry {
        let line: Int
        let key: String
        let hasValue: Bool
        /// Child lines, trailing blank/comment lines trimmed — those belong
        /// to whatever follows, not to this entry.
        let body: Range<Int>
    }

    private static func analyze(_ raw: String) -> Line {
        let uncommented = stripComment(raw)
        let content = uncommented.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty, let colon = content.firstIndex(of: ":") else {
            return Line(indent: 0, key: nil, hasValue: false)
        }
        let key = String(content[..<colon]).trimmingCharacters(in: .whitespaces)
        let rest = String(content[content.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return Line(indent: uncommented.prefix { $0 == " " }.count,
                    key: key.isEmpty ? nil : key,
                    hasValue: !rest.isEmpty)
    }

    private static func sectionRange(in lines: [Line]) -> (header: Int, body: Range<Int>)? {
        guard let header = lines.firstIndex(where: { $0.key == "graph" && $0.indent == 0 }) else {
            return nil
        }
        var end = header + 1
        while end < lines.count, lines[end].key == nil || lines[end].indent > 0 {
            end += 1
        }
        return (header, (header + 1)..<end)
    }

    private static func entries(in lines: [Line], range: Range<Int>) -> [Entry] {
        guard let first = range.first(where: { lines[$0].key != nil }) else { return [] }
        let levelIndent = lines[first].indent
        var result: [Entry] = []
        var i = range.lowerBound
        while i < range.upperBound {
            guard let key = lines[i].key, lines[i].indent == levelIndent else { i += 1; continue }
            var next = i + 1
            while next < range.upperBound,
                  lines[next].key == nil || lines[next].indent > levelIndent {
                next += 1
            }
            var bodyEnd = next
            while bodyEnd > i + 1, lines[bodyEnd - 1].key == nil { bodyEnd -= 1 }
            result.append(Entry(line: i, key: key, hasValue: lines[i].hasValue, body: (i + 1)..<bodyEnd))
            i = next
        }
        return result
    }

    private static func stripComment(_ line: String) -> String {
        var inQuotes = false
        var previous: Character = " "
        for (offset, ch) in line.enumerated() {
            if ch == "\"" && previous != "\\" { inQuotes.toggle() }
            if ch == "#" && !inQuotes { return String(line.prefix(offset)) }
            previous = ch
        }
        return line
    }

    /// Quote a target the parser (or a YAML editor) could misread bare.
    private static func escaped(_ value: String) -> String {
        let bareSafe = !value.isEmpty
            && !value.contains("#") && !value.contains(":") && !value.contains("\"")
            && value.first?.isWhitespace != true && value.last?.isWhitespace != true
            && value != "true" && value != "false"
            && Double(value) == nil
        guard !bareSafe else { return value }
        let body = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(body)\""
    }

    private static func describe(_ letters: [String]) -> String {
        letters.map { $0.uppercased() }.joined(separator: " ")
    }
}
