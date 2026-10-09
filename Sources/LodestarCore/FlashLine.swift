import Foundation

/// A flash, as written at its call site: the fact, then, after a newline,
/// the way forward when there is one. Keys in either line are written in
/// brackets, `[⌘][V] pastes it`, and drawn as keys; a bracket key itself
/// is written `[[]` or `[]]`. Every flash speaks one way (DESIGN, the
/// flash rules): what happened in the first line, what to do in a quieter
/// second line, and a key mentioned is a key drawn, never typed into the
/// words.
public enum FlashLine {
    public enum Part: Equatable {
        case words(String)
        case keys([String])
    }

    /// The fact and the way, split at the first newline.
    public static func split(_ text: String) -> (fact: String, way: String?) {
        guard let newline = text.firstIndex(of: "\n") else { return (text, nil) }
        let way = text[text.index(after: newline)...].trimmingCharacters(in: .whitespaces)
        return (String(text[..<newline]), way.isEmpty ? nil : way)
    }

    /// A line as words and runs of keys. Keys next to each other, with or
    /// without a space between, are one run; words keep their own spaces
    /// trimmed at the edges.
    public static func parts(_ line: String) -> [Part] {
        var parts: [Part] = []
        var words = ""
        var run: [String] = []
        func flushWords() {
            let trimmed = words.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { parts.append(.words(trimmed)) }
            words = ""
        }
        func flushRun() {
            if !run.isEmpty { parts.append(.keys(run)) }
            run = []
        }
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "[", let close = closing(in: line, after: index) {
                // A key: the first character after the bracket always
                // belongs to it, which is how `[]]` names the ] key.
                let key = String(line[line.index(after: index)..<close])
                if !words.trimmingCharacters(in: .whitespaces).isEmpty {
                    flushRun()
                    flushWords()
                }
                words = ""
                run.append(key)
                index = line.index(after: close)
                continue
            }
            if !run.isEmpty, character != " " { flushRun() }
            words.append(character)
            index = line.index(after: index)
        }
        flushRun()
        flushWords()
        return parts
    }

    /// The line read aloud: keys by name, for accessibility and the log.
    public static func plain(_ line: String) -> String {
        parts(line).map { part in
            switch part {
            case .words(let text): return text
            case .keys(let keys): return keys.joined(separator: " ")
            }
        }.joined(separator: " ")
    }

    private static func closing(in line: String, after open: String.Index) -> String.Index? {
        let first = line.index(after: open)
        guard first < line.endIndex else { return nil }
        let search = line.index(after: first)
        guard search <= line.endIndex else { return nil }
        return line[search...].firstIndex(of: "]")
    }
}
