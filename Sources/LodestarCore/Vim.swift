import Foundation

/// The draft's editor: stock vim's normal and visual modes as a pure
/// state machine over a `Draft.Buffer`. Motions, operators, counts, text
/// objects, find, join, replace, case, undo, redo, dot repeat, and the
/// visual modes. No file, no ex line, no registers beyond the two the
/// design allows: `y` writes the pasteboard, `p` reads it, everything
/// else stays inside.
///
/// Two deliberate deviations, both decided before a line was written:
/// `⏎` is never the editor's (the bar commits on it in every mode), and
/// deletes never touch the pasteboard, so `dd` then `p` pastes what was
/// yanked, not what was deleted. The shell owns insert mode's typing;
/// the editor is told what was typed so `.` can say it again.
public struct Vim {
    public enum Mode: Equatable, Sendable {
        case normal
        case insert
        case visual(line: Bool)
    }

    /// A key as the editor sees it: the character it produces, or one of
    /// the few named keys that mean something in normal mode.
    public enum Key: Equatable, Sendable {
        case char(Character)
        case escape, delete, left, right, up, down
        case control(Character)
    }

    /// What the shell must do after a key.
    public enum Effect: Equatable, Sendable {
        /// Insert mode begins; the shell types into the buffer from here
        /// and reports it back through `typed`, `insertBackspace`, and
        /// `leaveInsert`.
        case enterInsert
        /// Text for the pasteboard.
        case yank(String)
        case flash(String)
        /// The key meant nothing here; the shell may use it.
        case unhandled
    }

    public private(set) var mode: Mode = .normal

    // Pending grammar.
    private var count: Int?
    private var op: Character?
    private var opCount: Int?
    private var awaiting: Character?
    private var pendingG = false
    private var pendingObject: Character?
    private var lastFind: (key: Character, target: Character)?
    /// The shell's view of soft wrapping: where one visual line up
    /// (false) or down (true) from `index` lands, or nil where the eye's
    /// layout has no line. Set by the shell that renders the buffer;
    /// absent, `j` and `k` walk logical lines. Only bare navigation
    /// asks: an operator's `j` stays a logical line, so `dj` keeps
    /// meaning what vim's `dj` means.
    ///
    /// The buffer travels into the closure by value. The shell must not
    /// reach for its own stored buffer here: this runs inside `key`,
    /// which holds that buffer `inout`, and a second access aborts the
    /// process — the exact crash v0.26.7 shipped on every `j`.
    public var visualLine: ((Draft.Buffer, Int, Bool) -> Int?)?

    /// The find kind (`f`, `t`, `F`, `T`) whose target character is being
    /// awaited, so the panel can light the reachable letters while the
    /// hand decides which one to name.
    public var pendingFind: Character? {
        guard let awaiting, "ftFT".contains(awaiting) else { return nil }
        return awaiting
    }

    /// The letters a pending find could land on: the first instance of
    /// each distinct character in the motion's direction, scanned the way
    /// the motion itself scans (`t` and `T` start one further). Whitespace
    /// is jumpable but never painted.
    public static func findTargets(kind: Character, in buffer: Draft.Buffer) -> [Int] {
        let chars = buffer.characters
        var seen = Set<Character>()
        var positions: [Int] = []
        if kind == "f" || kind == "t" {
            var i = buffer.cursor + (kind == "t" ? 2 : 1)
            while i < chars.count {
                let c = chars[i]
                if !c.isWhitespace, seen.insert(c).inserted { positions.append(i) }
                i += 1
            }
        } else {
            var i = buffer.cursor - (kind == "T" ? 2 : 1)
            while i >= 0 {
                let c = chars[i]
                if !c.isWhitespace, seen.insert(c).inserted { positions.append(i) }
                i -= 1
            }
        }
        return positions
    }
    private var visualAnchor = 0

    // History.
    private struct Snapshot: Equatable { let characters: [Character]; let cursor: Int }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private static let historyCap = 200

    // Dot repeat.
    private var recording: [Key] = []
    private var lastChange: [Key] = []
    /// A change made on a visual selection repeats on a selection of the
    /// same shape from the cursor: this many characters, or this many lines,
    /// and for `c`, what was typed into it.
    private var lastVisual: (op: Character, length: Int, line: Bool)?
    private var lastVisualInsert: [Key] = []
    /// Set while a visual command runs, so the bookkeeping that follows
    /// knows the change came from a selection, not from keys to replay.
    private var inVisualChange = false
    private var inserted: [Key] = []
    private var insertOpen = false
    private var replaying = false

    public init() {}

    static let countCap = 9999

    /// A command is half typed: an operator, a count, a find waiting for
    /// its character. Escape clears it rather than closing anything.
    public var isPending: Bool {
        count != nil || op != nil || awaiting != nil || pendingG || pendingObject != nil
    }

    /// The visual selection, when there is one, in document order and
    /// inclusive of the cursor's character.
    public func selection(in buffer: Draft.Buffer) -> Range<Int>? {
        guard case .visual(let line) = mode else { return nil }
        let a = min(visualAnchor, buffer.cursor), b = max(visualAnchor, buffer.cursor)
        if line {
            return buffer.lineStart(from: a)..<min(buffer.count, buffer.lineEnd(from: b) + 1)
        }
        return a..<min(buffer.count, b + 1)
    }

    // MARK: - Insert mode, reported by the shell

    /// Normal mode from outside: the edit door opens here. The cursor
    /// is put where a normal-mode cursor can be, on a character.
    public mutating func enterNormal(_ buffer: inout Draft.Buffer) {
        mode = .normal
        insertOpen = false
        inserted = []
        recording = []
        clampNormal(&buffer)
    }

    /// Insert mode without a command behind it: the speak door opens
    /// here, and `lode .` inside the bar returns here. Nothing to undo,
    /// nothing for `.` to repeat.
    public mutating func startInsert() {
        guard mode != .insert else { return }
        mode = .insert
        insertOpen = false
        inserted = []
        recording = []
    }

    public mutating func typed(_ text: String) {
        guard mode == .insert, !replaying else { return }
        for character in text { inserted.append(.char(character)) }
    }

    public mutating func insertBackspace() {
        guard mode == .insert, !replaying else { return }
        if case .char = inserted.last { inserted.removeLast() } else { inserted.append(.delete) }
    }

    /// Escape from insert: the cursor steps back one, as vim's does, and
    /// the change that began with the command that opened insert is
    /// complete, with what was typed inside it.
    public mutating func leaveInsert(_ buffer: inout Draft.Buffer) {
        guard mode == .insert else { return }
        mode = .normal
        // Back one, as vim does, unless the cursor is at its line's start.
        if buffer.cursor > buffer.lineStart(from: buffer.cursor) {
            buffer.setCursor(buffer.cursor - 1)
        }
        clampNormal(&buffer)
        if !replaying, insertOpen {
            if visualInsertOpen {
                lastVisualInsert = inserted
                lastChange = []
            } else {
                lastChange = recording + inserted + [.escape]
            }
        }
        visualInsertOpen = false
        insertOpen = false
        recording = []
        inserted = []
    }

    // MARK: - Keys

    public mutating func key(_ key: Key, buffer: inout Draft.Buffer, pasteboard: () -> String?) -> [Effect] {
        if !replaying { recording.append(key) }
        let effects: [Effect]
        switch mode {
        case .insert:
            effects = [.unhandled]
        case .normal, .visual:
            effects = command(key, &buffer, pasteboard: pasteboard)
        }
        if !isPending, mode != .insert, !replaying {
            // A completed command that was not a change leaves nothing
            // for `.` to say again.
            if !changed { recording = [] }
        }
        changed = false
        return effects
    }

    private var changed = false

    private mutating func command(_ key: Key, _ buffer: inout Draft.Buffer, pasteboard: () -> String?) -> [Effect] {
        // A character the last command asked for: f t F T r.
        if let awaiting {
            self.awaiting = nil
            guard case .char(let c) = key else { clearPending(); return [] }
            return resolveAwaited(awaiting, c, &buffer)
        }
        if pendingObject != nil {
            guard case .char(let c) = key else { clearPending(); return [] }
            let kind = pendingObject!
            pendingObject = nil
            return applyTextObject(kind: kind, c, &buffer, pasteboard: pasteboard)
        }
        if pendingG {
            pendingG = false
            switch key {
            case .char("g"): return applyMotion(.line(0), &buffer, pasteboard: pasteboard)
            default: clearPending(); return []
            }
        }

        switch key {
        case .escape:
            if isPending { clearPending(); return [] }
            if case .visual = mode { mode = .normal; clampNormal(&buffer); return [] }
            return [.unhandled]
        case .left: return applyMotion(.left, &buffer, pasteboard: pasteboard)
        case .right: return applyMotion(.right, &buffer, pasteboard: pasteboard)
        case .up: return applyMotion(.lineUp, &buffer, pasteboard: pasteboard)
        case .down: return applyMotion(.lineDown, &buffer, pasteboard: pasteboard)
        case .delete: return applyMotion(.left, &buffer, pasteboard: pasteboard)
        case .control(let c):
            if c == "r" { return redo(&buffer) }
            return [.unhandled]
        case .char(let c):
            return character(c, &buffer, pasteboard: pasteboard)
        }
    }

    private mutating func character(_ c: Character, _ buffer: inout Draft.Buffer, pasteboard: () -> String?) -> [Effect] {
        // Counts, with 0 a motion when no count has begun.
        if c.isNumber, let digit = c.wholeNumberValue, !(digit == 0 && count == nil) {
            // Capped: a count is a small number, and an unbounded one is
            // an overflow trap or a main-thread hang.
            count = min(Self.countCap, (count ?? 0) * 10 + digit)
            return []
        }
        let inVisual: Bool
        if case .visual = mode { inVisual = true } else { inVisual = false }

        // Operators.
        if op == nil, "dcy".contains(c), !inVisual {
            op = c
            opCount = count
            count = nil
            return []
        }
        if let pending = op, pending == c {
            // dd cc yy: this many lines.
            let n = min(Self.countCap, (opCount ?? 1) * (count ?? 1))
            op = nil; opCount = nil; count = nil
            return operate(pending, .lines(n), &buffer, pasteboard: pasteboard)
        }
        if op != nil || inVisual, c == "i" || c == "a" {
            pendingObject = c
            return []
        }

        switch c {
        case "h": return applyMotion(.left, &buffer, pasteboard: pasteboard)
        case "l", " ": return applyMotion(.right, &buffer, pasteboard: pasteboard)
        case "j": return applyMotion(.lineDown, &buffer, pasteboard: pasteboard)
        case "k": return applyMotion(.lineUp, &buffer, pasteboard: pasteboard)
        case "w": return applyMotion(.wordForward(big: false), &buffer, pasteboard: pasteboard)
        case "W": return applyMotion(.wordForward(big: true), &buffer, pasteboard: pasteboard)
        case "b": return applyMotion(.wordBack(big: false), &buffer, pasteboard: pasteboard)
        case "B": return applyMotion(.wordBack(big: true), &buffer, pasteboard: pasteboard)
        case "e": return applyMotion(.wordEnd(big: false), &buffer, pasteboard: pasteboard)
        case "E": return applyMotion(.wordEnd(big: true), &buffer, pasteboard: pasteboard)
        case "0": return applyMotion(.lineStart, &buffer, pasteboard: pasteboard)
        case "^": return applyMotion(.firstNonBlank, &buffer, pasteboard: pasteboard)
        case "$": return applyMotion(.lineEnd, &buffer, pasteboard: pasteboard)
        case "G": return applyMotion(count.map { .line($0 - 1) } ?? .lastLine, &buffer, pasteboard: pasteboard)
        case "g": pendingG = true; return []
        case "f", "t", "F", "T": awaiting = c; return []
        case ";":
            guard let find = lastFind else { return [] }
            return applyMotion(.find(find.key, find.target), &buffer, pasteboard: pasteboard)
        case ",":
            guard let find = lastFind else { return [] }
            let reversed: Character
            switch find.key {
            case "f": reversed = "F"
            case "F": reversed = "f"
            case "t": reversed = "T"
            default: reversed = "t"
            }
            return applyMotion(.find(reversed, find.target), &buffer, pasteboard: pasteboard)
        case "{": return applyMotion(.paragraphBack, &buffer, pasteboard: pasteboard)
        case "}": return applyMotion(.paragraphForward, &buffer, pasteboard: pasteboard)
        case "%": return applyMotion(.matchBracket, &buffer, pasteboard: pasteboard)
        default: break
        }

        // Anything below changes the buffer or the mode, so an operator
        // still pending is a mistake and is dropped.
        if op != nil { clearPending(); return [] }

        if inVisual {
            return visualCommand(c, &buffer, pasteboard: pasteboard)
        }

        let n = count ?? 1
        count = nil
        switch c {
        case "i": return enterInsert(&buffer)
        case "a":
            if buffer.cursor < buffer.lineEnd(from: buffer.cursor) { buffer.setCursor(buffer.cursor + 1) }
            return enterInsert(&buffer)
        case "I": buffer.setCursor(firstNonBlank(buffer, from: buffer.cursor)); return enterInsert(&buffer)
        case "A": buffer.setCursor(buffer.lineEnd(from: buffer.cursor)); return enterInsert(&buffer)
        case "o":
            snapshot(buffer)
            let end = buffer.lineEnd(from: buffer.cursor)
            buffer.replace(end..<end, with: "\n")
            return enterInsert(&buffer, snapshotTaken: true)
        case "O":
            snapshot(buffer)
            let start = buffer.lineStart(from: buffer.cursor)
            buffer.replace(start..<start, with: "\n")
            buffer.setCursor(start)
            return enterInsert(&buffer, snapshotTaken: true)
        case "x":
            return operate("d", .chars(n), &buffer, pasteboard: pasteboard)
        case "X":
            return operate("d", .charsBack(n), &buffer, pasteboard: pasteboard)
        case "s":
            return operate("c", .chars(n), &buffer, pasteboard: pasteboard)
        case "S":
            return operate("c", .lines(n), &buffer, pasteboard: pasteboard)
        case "D":
            return operate("d", .toLineEnd, &buffer, pasteboard: pasteboard)
        case "C":
            return operate("c", .toLineEnd, &buffer, pasteboard: pasteboard)
        case "Y":
            return operate("y", .toLineEnd, &buffer, pasteboard: pasteboard)
        case "r":
            awaiting = "r"; count = n == 1 ? nil : n; return []
        case "~":
            snapshot(buffer)
            for _ in 0..<n where buffer.cursor < buffer.lineEnd(from: buffer.cursor) {
                let ch = buffer.characters[buffer.cursor]
                let flipped = ch.isUppercase ? ch.lowercased() : ch.uppercased()
                buffer.replace(buffer.cursor..<buffer.cursor + 1, with: flipped)
            }
            clampNormal(&buffer)
            noteChange()
            return []
        case "J":
            snapshot(buffer)
            for _ in 0..<max(1, n - 1) { join(&buffer) }
            noteChange()
            return []
        case "p", "P":
            guard let text = pasteboard(), !text.isEmpty else { return [.flash("⌂ nothing to paste")] }
            snapshot(buffer)
            for _ in 0..<n { put(text, after: c == "p", &buffer) }
            noteChange()
            return []
        case "u":
            return undo(&buffer)
        case "v":
            mode = .visual(line: false); visualAnchor = buffer.cursor; return []
        case "V":
            mode = .visual(line: true); visualAnchor = buffer.cursor; return []
        case ".":
            return repeatLast(&buffer, pasteboard: pasteboard, times: n)
        default:
            return [.unhandled]
        }
    }

    private mutating func visualCommand(_ c: Character, _ buffer: inout Draft.Buffer, pasteboard: () -> String?) -> [Effect] {
        guard let range = selection(in: buffer), case .visual(let line) = mode else { return [] }
        count = nil
        if "dxDXcsyYpP~uUJ".contains(c), !replaying {
            let lines = buffer.lineIndex(of: max(range.lowerBound, range.upperBound - 1)) - buffer.lineIndex(of: range.lowerBound) + 1
            lastVisual = (c, line ? lines : range.count, line)
            lastVisualInsert = []
            lastChange = []
        }
        inVisualChange = true
        defer { inVisualChange = false }
        switch c {
        case "o":
            let anchor = visualAnchor
            visualAnchor = buffer.cursor
            buffer.setCursor(anchor)
            return []
        case "v": mode = .visual(line: false); return []
        case "V": mode = .visual(line: true); return []
        case "d", "x", "D", "X":
            let linewise = line || c == "D" || c == "X"
            let target = linewise ? lineRange(covering: range, buffer) : range
            snapshot(buffer)
            delete(target, linewise: linewise, &buffer)
            mode = .normal
            clampNormal(&buffer)
            noteChange()
            return []
        case "c", "s":
            snapshot(buffer)
            let target = line ? lineRange(covering: range, buffer, keepNewline: true) : range
            buffer.replace(target, with: "")
            mode = .normal
            return enterInsert(&buffer, snapshotTaken: true)
        case "y", "Y":
            let linewise = line || c == "Y"
            let target = linewise ? lineRange(covering: range, buffer) : range
            var text = buffer.slice(target)
            if linewise, !text.hasSuffix("\n") { text += "\n" }
            mode = .normal
            buffer.setCursor(target.lowerBound)
            clampNormal(&buffer)
            return [.yank(text)]
        case "p", "P":
            guard let text = pasteboard(), !text.isEmpty else { return [.flash("⌂ nothing to paste")] }
            snapshot(buffer)
            let target = line ? lineRange(covering: range, buffer, keepNewline: true) : range
            buffer.replace(target, with: text)
            buffer.setCursor(max(target.lowerBound, buffer.cursor - 1))
            mode = .normal
            clampNormal(&buffer)
            noteChange()
            return []
        case "~", "u", "U":
            snapshot(buffer)
            let text = buffer.slice(range)
            let flipped: String
            switch c {
            case "u": flipped = text.lowercased()
            case "U": flipped = text.uppercased()
            default: flipped = String(text.map { $0.isUppercase ? Character($0.lowercased()) : Character($0.uppercased()) })
            }
            buffer.replace(range, with: flipped)
            buffer.setCursor(range.lowerBound)
            mode = .normal
            clampNormal(&buffer)
            noteChange()
            return []
        case "J":
            snapshot(buffer)
            let lines = max(1, buffer.lineIndex(of: range.upperBound - 1) - buffer.lineIndex(of: range.lowerBound))
            buffer.setCursor(range.lowerBound)
            for _ in 0..<lines { join(&buffer) }
            mode = .normal
            noteChange()
            return []
        default:
            return [.unhandled]
        }
    }

    // MARK: - Motions

    private enum Motion {
        case left, right, lineUp, lineDown
        case wordForward(big: Bool), wordBack(big: Bool), wordEnd(big: Bool)
        case lineStart, firstNonBlank, lineEnd
        case line(Int), lastLine
        case find(Character, Character)
        case paragraphBack, paragraphForward
        case matchBracket
    }

    /// Where a motion lands, and how an operator should treat the span.
    private struct Target {
        let index: Int
        var inclusive = false
        var linewise = false
    }

    private mutating func applyMotion(_ motion: Motion, _ buffer: inout Draft.Buffer, pasteboard: () -> String?) -> [Effect] {
        let n = min(Self.countCap, (count ?? 1) * (op != nil ? (opCount ?? 1) : 1))
        count = nil
        var target: Target?
        var cursor = buffer.cursor
        for _ in 0..<n {
            // A motion that no longer moves is done, whatever the count.
            guard let step = resolve(motion, from: cursor, buffer), step.index != cursor || target == nil else { break }
            cursor = step.index
            target = step
        }
        guard var landed = target else {
            if op != nil { clearPending() }
            return []
        }
        if let pending = op {
            op = nil; opCount = nil
            // `cw` on a word acts like `ce`: vim's one special case.
            if pending == "c", case .wordForward(let big) = motion, buffer.cursor < buffer.count,
               !buffer.characters[buffer.cursor].isWhitespace {
                // The end of the word under the cursor, then the ends of
                // the words after it; a cursor already on a word's last
                // character changes that character alone.
                var end = buffer.cursor
                let kind = cls(buffer.characters[end], big: big)
                while end + 1 < buffer.count, cls(buffer.characters[end + 1], big: big) == kind,
                      buffer.characters[end + 1] != "\n" { end += 1 }
                var steps = n - 1
                while steps > 0 {
                    end = wordEnd(from: end, big: big, buffer)
                    steps -= 1
                }
                return operate(pending, .range(buffer.cursor..<min(buffer.count, end + 1)), &buffer, pasteboard: pasteboard)
            }
            // `dw` at the end of a line stops at the line end.
            if pending != "y", case .wordForward = motion, landed.index > buffer.lineEnd(from: buffer.cursor) {
                landed = Target(index: buffer.lineEnd(from: buffer.cursor))
            }
            let span = self.span(from: buffer.cursor, to: landed, buffer)
            return operate(pending, span, &buffer, pasteboard: pasteboard)
        }
        buffer.setCursor(landed.index)
        if mode == .normal { clampNormal(&buffer) }
        return []
    }

    private enum Span {
        case range(Range<Int>)
        case lines(Int)
        case chars(Int)
        case charsBack(Int)
        case toLineEnd
        case lineRange(Range<Int>)
    }

    private func span(from start: Int, to target: Target, _ buffer: Draft.Buffer) -> Span {
        if target.linewise {
            let a = min(start, target.index), b = max(start, target.index)
            return .lineRange(buffer.lineStart(from: a)..<buffer.lineEnd(from: b))
        }
        let a = min(start, target.index), b = max(start, target.index)
        let end = target.inclusive ? min(buffer.count, b + 1) : b
        return .range(a..<end)
    }

    private func resolve(_ motion: Motion, from cursor: Int, _ buffer: Draft.Buffer) -> Target? {
        let chars = buffer.characters
        switch motion {
        case .left:
            guard cursor > 0, chars[cursor - 1] != "\n" else { return nil }
            return Target(index: cursor - 1)
        case .right:
            let limit = mode == .insert ? chars.count : max(0, buffer.lineEnd(from: cursor) - (op == nil ? 1 : 0))
            guard cursor < limit || (op != nil && cursor < buffer.lineEnd(from: cursor)) else { return nil }
            return Target(index: min(cursor + 1, buffer.lineEnd(from: cursor)))
        case .lineUp:
            if op == nil, let landed = visualLine?(buffer, cursor, false), landed != cursor {
                return Target(index: landed, linewise: true)
            }
            var copy = buffer; copy.setCursor(cursor); copy.moveUp()
            guard buffer.lineStart(from: cursor) > 0 else { return nil }
            return Target(index: copy.cursor, linewise: true)
        case .lineDown:
            if op == nil, let landed = visualLine?(buffer, cursor, true), landed != cursor {
                return Target(index: landed, linewise: true)
            }
            guard buffer.lineEnd(from: cursor) < chars.count else { return nil }
            var copy = buffer; copy.setCursor(cursor); copy.moveDown()
            return Target(index: copy.cursor, linewise: true)
        case .wordForward(let big):
            guard cursor < chars.count else { return nil }
            return Target(index: wordForward(from: cursor, big: big, buffer))
        case .wordBack(let big):
            guard cursor > 0 else { return nil }
            return Target(index: wordBack(from: cursor, big: big, buffer))
        case .wordEnd(let big):
            guard cursor < chars.count else { return nil }
            return Target(index: wordEnd(from: cursor, big: big, buffer), inclusive: true)
        case .lineStart:
            return Target(index: buffer.lineStart(from: cursor))
        case .firstNonBlank:
            return Target(index: firstNonBlank(buffer, from: cursor))
        case .lineEnd:
            let end = buffer.lineEnd(from: cursor)
            let start = buffer.lineStart(from: cursor)
            // On an empty line there is nothing to land on: an operator
            // gets an empty span, a motion stays put.
            guard end > start else { return Target(index: start, inclusive: false) }
            return Target(index: end - 1, inclusive: true)
        case .line(let number):
            let start = buffer.lineStartOfLine(number)
            return Target(index: firstNonBlank(buffer, from: start), linewise: true)
        case .lastLine:
            let start = buffer.lineStart(from: chars.count)
            return Target(index: firstNonBlank(buffer, from: start), linewise: true)
        case .find(let kind, let c):
            switch kind {
            case "f", "t":
                var i = cursor + 1
                if kind == "t" { i += 1 }
                while i < chars.count {
                    if chars[i] == c {
                        let destination = kind == "t" ? navigableBefore(i, after: cursor, chars) : i
                        if let destination {
                            return Target(index: destination, inclusive: true)
                        }
                    }
                    i += 1
                }
                return nil
            default:
                var i = cursor - 1
                if kind == "T" { i -= 1 }
                while i >= 0 {
                    if chars[i] == c {
                        let destination = kind == "T" ? navigableAfter(i, before: cursor, chars) : i
                        if let destination {
                            return Target(index: destination)
                        }
                    }
                    i -= 1
                }
                return nil
            }
        case .paragraphBack:
            var i = buffer.lineStart(from: cursor)
            if i > 0 { i -= 1 }
            // Skip blank lines, then find the blank line before the paragraph.
            while i > 0, buffer.lineIsBlank(at: i) { i = buffer.lineStart(from: i) - 1 }
            while i > 0, !buffer.lineIsBlank(at: i) { i = buffer.lineStart(from: i) - 1 }
            return Target(index: max(0, i < 0 ? 0 : buffer.lineStart(from: max(0, i))))
        case .paragraphForward:
            var i = buffer.lineEnd(from: cursor)
            while i < chars.count, buffer.lineIsBlank(at: i) { i = buffer.lineEnd(from: i + 1) }
            while i < chars.count, !buffer.lineIsBlank(at: i) { i = buffer.lineEnd(from: i + 1) }
            return Target(index: min(chars.count, i))
        case .matchBracket:
            guard let match = matchingBracket(from: cursor, buffer) else { return nil }
            return Target(index: match, inclusive: true)
        }
    }

    private static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", "<": ">"]
    private static let closers: [Character: Character] = [")": "(", "]": "[", "}": "{", ">": "<"]

    private func matchingBracket(from cursor: Int, _ buffer: Draft.Buffer) -> Int? {
        let chars = buffer.characters
        var i = cursor
        while i < buffer.lineEnd(from: cursor), Self.pairs[chars[i]] == nil, Self.closers[chars[i]] == nil { i += 1 }
        guard i < chars.count else { return nil }
        if let close = Self.pairs[chars[i]] {
            var depth = 0
            for j in i..<chars.count {
                if chars[j] == chars[i] { depth += 1 }
                if chars[j] == close { depth -= 1; if depth == 0 { return j } }
            }
        } else if let open = Self.closers[chars[i]] {
            var depth = 0
            for j in stride(from: i, through: 0, by: -1) {
                if chars[j] == chars[i] { depth += 1 }
                if chars[j] == open { depth -= 1; if depth == 0 { return j } }
            }
        }
        return nil
    }

    // MARK: Word boundaries

    private enum Class: Equatable { case blank, word, punct }

    private func cls(_ c: Character, big: Bool) -> Class {
        if c.isWhitespace || c.isNewline { return .blank }
        if big { return .word }
        return (c.isLetter || c.isNumber || c == "_") ? .word : .punct
    }

    private func wordForward(from start: Int, big: Bool, _ buffer: Draft.Buffer) -> Int {
        let chars = buffer.characters
        var i = start
        guard i < chars.count else { return i }
        let first = cls(chars[i], big: big)
        if first != .blank {
            while i < chars.count, cls(chars[i], big: big) == first { i += 1 }
        }
        while i < chars.count, cls(chars[i], big: big) == .blank {
            // An empty line is a word.
            if chars[i] == "\n", i + 1 < chars.count, chars[i + 1] == "\n" { return i + 1 }
            i += 1
        }
        return i
    }

    private func wordBack(from start: Int, big: Bool, _ buffer: Draft.Buffer) -> Int {
        let chars = buffer.characters
        var i = start
        while i > 0, cls(chars[i - 1], big: big) == .blank { i -= 1 }
        guard i > 0 else { return 0 }
        let first = cls(chars[i - 1], big: big)
        while i > 0, cls(chars[i - 1], big: big) == first { i -= 1 }
        return i
    }

    private func wordEnd(from start: Int, big: Bool, _ buffer: Draft.Buffer) -> Int {
        let chars = buffer.characters
        var i = min(start + 1, chars.count)
        while i < chars.count, cls(chars[i], big: big) == .blank { i += 1 }
        guard i < chars.count else { return max(0, chars.count - 1) }
        let first = cls(chars[i], big: big)
        while i + 1 < chars.count, cls(chars[i + 1], big: big) == first { i += 1 }
        return i
    }

    private func firstNonBlank(_ buffer: Draft.Buffer, from index: Int) -> Int {
        var i = buffer.lineStart(from: index)
        let end = buffer.lineEnd(from: index)
        while i < end, buffer.characters[i].isWhitespace { i += 1 }
        return i
    }

    /// `t` and `T` may now cross a line break, while a normal-mode cursor
    /// may not rest on one. Skip line breaks to the first visible destination
    /// on the appropriate side; if there is none before the original cursor,
    /// that match cannot be navigated to and the scan continues.
    private func navigableBefore(_ index: Int, after cursor: Int, _ chars: [Character]) -> Int? {
        var i = index - 1
        while i > cursor, chars[i] == "\n" { i -= 1 }
        return i > cursor ? i : nil
    }

    private func navigableAfter(_ index: Int, before cursor: Int, _ chars: [Character]) -> Int? {
        var i = index + 1
        while i < cursor, chars[i] == "\n" { i += 1 }
        return i < cursor ? i : nil
    }

    // MARK: - Awaited characters

    private mutating func resolveAwaited(_ kind: Character, _ c: Character, _ buffer: inout Draft.Buffer) -> [Effect] {
        switch kind {
        case "f", "t", "F", "T":
            lastFind = (kind, c)
            return applyMotion(.find(kind, c), &buffer, pasteboard: { nil })
        case "r":
            let n = count ?? 1
            count = nil
            // Past the line's end the command is refused, as vim refuses it.
            guard buffer.cursor + n <= buffer.lineEnd(from: buffer.cursor) else { return [] }
            snapshot(buffer)
            let replacement = String(repeating: String(c), count: n)
            buffer.replace(buffer.cursor..<buffer.cursor + n, with: replacement)
            buffer.setCursor(buffer.cursor - 1)
            noteChange()
            return []
        default:
            return []
        }
    }

    // MARK: - Text objects

    private mutating func applyTextObject(kind: Character, _ c: Character, _ buffer: inout Draft.Buffer,
                                          pasteboard: () -> String?) -> [Effect] {
        let inner = kind == "i"
        guard let range = textObject(c, inner: inner, buffer) else { clearPending(); return [] }
        if let pending = op {
            op = nil; opCount = nil; count = nil
            return operate(pending, .range(range), &buffer, pasteboard: pasteboard)
        }
        if case .visual = mode {
            visualAnchor = range.lowerBound
            buffer.setCursor(max(range.lowerBound, range.upperBound - 1))
            return []
        }
        return []
    }

    private func textObject(_ c: Character, inner: Bool, _ buffer: Draft.Buffer) -> Range<Int>? {
        let chars = buffer.characters
        let cursor = min(buffer.cursor, max(0, chars.count - 1))
        guard !chars.isEmpty else { return nil }
        switch c {
        case "w", "W":
            let big = c == "W"
            let kind = cls(chars[cursor], big: big)
            var a = cursor, b = cursor
            while a > 0, cls(chars[a - 1], big: big) == kind, chars[a - 1] != "\n" { a -= 1 }
            while b + 1 < chars.count, cls(chars[b + 1], big: big) == kind, chars[b + 1] != "\n" { b += 1 }
            var range = a..<b + 1
            if !inner {
                // aw: the word and the whitespace after it, or before when at a line end.
                var end = range.upperBound
                while end < chars.count, chars[end] == " " { end += 1 }
                if end > range.upperBound {
                    range = range.lowerBound..<end
                } else {
                    var start = range.lowerBound
                    while start > 0, chars[start - 1] == " " { start -= 1 }
                    range = start..<range.upperBound
                }
            }
            return range
        case "s":
            // A sentence: to the previous and next sentence end.
            var a = cursor, b = cursor
            while a > 0, !".!?".contains(chars[a - 1]) || (a < chars.count && !chars[a].isWhitespace) { a -= 1 }
            while a < chars.count, chars[a].isWhitespace { a += 1 }
            while b < chars.count, !".!?".contains(chars[b]) { b += 1 }
            var end = min(chars.count, b + 1)
            if !inner { while end < chars.count, chars[end] == " " { end += 1 } }
            return a..<end
        case "p":
            var a = buffer.lineStart(from: cursor)
            var b = buffer.lineEnd(from: cursor)
            while a > 0, !buffer.lineIsBlank(at: a - 1) { a = buffer.lineStart(from: a - 1) }
            while b < chars.count, b + 1 < chars.count, !buffer.lineIsBlank(at: b + 1) { b = buffer.lineEnd(from: b + 1) }
            var end = min(chars.count, b + 1)
            if !inner {
                while end < chars.count, buffer.lineIsBlank(at: end) { end = min(chars.count, buffer.lineEnd(from: end) + 1) }
            }
            return a..<end
        case "\"", "'", "`":
            return quotePair(c, inner: inner, buffer, at: cursor)
        case "q":
            // mini.ai's any-quote, straight from the editor this draft is
            // drifting toward: of the three quote kinds, a pair covering
            // the cursor wins (innermost first), else the nearest ahead.
            let kinds: [Character] = ["\"", "'", "`"]
            return nearestObject(of: kinds.compactMap { quotePair($0, inner: inner, buffer, at: cursor) },
                                 to: cursor)
        case "b":
            // mini.ai's any-bracket, deliberately over vim's ib = parens:
            // of ( ), [ ], and { }, the covering pair wins innermost,
            // else the nearest pair opening ahead.
            let pairs: [(Character, Character)] = [("(", ")"), ("[", "]"), ("{", "}")]
            let enclosing = pairs.compactMap {
                enclosingPair(open: $0.0, close: $0.1, inner: inner, chars, at: cursor)
            }
            if let best = nearestObject(of: enclosing, to: cursor) { return best }
            return nearestObject(of: pairs.compactMap {
                aheadPair(open: $0.0, close: $0.1, inner: inner, chars, from: cursor)
            }, to: cursor)
        case "(", ")", "[", "]", "{", "}", "B", "<", ">":
            let (openChar, closeChar): (Character, Character)
            switch c {
            case "(", ")": (openChar, closeChar) = ("(", ")")
            case "[", "]": (openChar, closeChar) = ("[", "]")
            case "{", "}", "B": (openChar, closeChar) = ("{", "}")
            default: (openChar, closeChar) = ("<", ">")
            }
            return enclosingPair(open: openChar, close: closeChar, inner: inner, chars, at: cursor)
        default:
            return nil
        }
    }

    /// A quote pair of one kind on the cursor's line: the pair covering
    /// the cursor, else the nearest pair ahead. Line-scoped the way
    /// vim's quote objects are; a quoted phrase in a message rarely
    /// crosses a line, and one that does can be reached from inside it.
    private func quotePair(_ quote: Character, inner: Bool, _ buffer: Draft.Buffer, at cursor: Int) -> Range<Int>? {
        let chars = buffer.characters
        let line = buffer.lineStart(from: cursor)..<buffer.lineEnd(from: cursor)
        let quotes = line.filter { chars[$0] == quote }
        guard quotes.count >= 2 else { return nil }
        var open: Int?, close: Int?
        for pair in stride(from: 0, to: quotes.count - 1, by: 2) {
            if quotes[pair] <= cursor && cursor <= quotes[pair + 1] { open = quotes[pair]; close = quotes[pair + 1] }
        }
        if open == nil, let first = quotes.first(where: { $0 > cursor }),
           let index = quotes.firstIndex(of: first), index + 1 < quotes.count {
            open = quotes[index]; close = quotes[index + 1]
        }
        guard let o = open, let k = close else { return nil }
        return inner ? o + 1..<k : o..<k + 1
    }

    /// The innermost pair of one kind enclosing the cursor, balanced.
    private func enclosingPair(open openChar: Character, close closeChar: Character,
                               inner: Bool, _ chars: [Character], at cursor: Int) -> Range<Int>? {
        var depth = 0
        var o: Int?
        var i = cursor
        while i >= 0 {
            if chars[i] == closeChar, i != cursor { depth += 1 }
            if chars[i] == openChar {
                if depth == 0 { o = i; break }
                depth -= 1
            }
            i -= 1
        }
        guard let open = o else { return nil }
        depth = 0
        var k: Int?
        for j in open + 1..<chars.count {
            if chars[j] == openChar { depth += 1 }
            if chars[j] == closeChar {
                if depth == 0 { k = j; break }
                depth -= 1
            }
        }
        guard let close = k else { return nil }
        return inner ? open + 1..<close : open..<close + 1
    }

    /// The first pair of one kind opening at or after the cursor.
    private func aheadPair(open openChar: Character, close closeChar: Character,
                           inner: Bool, _ chars: [Character], from cursor: Int) -> Range<Int>? {
        guard cursor < chars.count,
              let o = (cursor..<chars.count).first(where: { chars[$0] == openChar }) else { return nil }
        var depth = 0
        for j in (o + 1)..<chars.count {
            if chars[j] == openChar { depth += 1 }
            if chars[j] == closeChar {
                if depth == 0 { return inner ? o + 1..<j : o..<j + 1 }
                depth -= 1
            }
        }
        return nil
    }

    /// mini.ai's choice among candidates: covering wins, innermost
    /// first; with none covering, the nearest starting ahead. An empty
    /// interior — the cursor on the bracket of a pair already emptied —
    /// ranks last: an object that selects nothing is a wasted keypress
    /// when a wider pair stands around it.
    private func nearestObject(of candidates: [Range<Int>], to cursor: Int) -> Range<Int>? {
        let covering = candidates.filter { $0.lowerBound <= cursor && cursor < max($0.upperBound, $0.lowerBound + 1) }
        if let best = covering.filter({ !$0.isEmpty }).min(by: { $0.count < $1.count }) { return best }
        return candidates.filter { $0.lowerBound > cursor }.min { $0.lowerBound < $1.lowerBound }
            ?? covering.first
            ?? candidates.first
    }

    // MARK: - Operators

    private mutating func operate(_ op: Character, _ span: Span, _ buffer: inout Draft.Buffer,
                                  pasteboard: () -> String?) -> [Effect] {
        let chars = buffer.characters
        var range: Range<Int>
        var linewise = false
        switch span {
        case .range(let r):
            range = r
        case .chars(let n):
            let end = min(buffer.lineEnd(from: buffer.cursor), buffer.cursor + n)
            range = buffer.cursor..<end
        case .charsBack(let n):
            let start = max(buffer.lineStart(from: buffer.cursor), buffer.cursor - n)
            range = start..<buffer.cursor
        case .toLineEnd:
            range = buffer.cursor..<buffer.lineEnd(from: buffer.cursor)
        case .lines(let n):
            linewise = true
            var end = buffer.lineEnd(from: buffer.cursor)
            for _ in 1..<max(1, n) {
                guard end < chars.count else { break }
                end = buffer.lineEnd(from: end + 1)
            }
            range = buffer.lineStart(from: buffer.cursor)..<end
        case .lineRange(let r):
            linewise = true
            range = r
        }
        if range.isEmpty, !linewise, op != "c" { return [] }

        switch op {
        case "y":
            var text = buffer.slice(range)
            if linewise { text += "\n" }
            buffer.setCursor(range.lowerBound)
            clampNormal(&buffer)
            return [.yank(text)]
        case "d":
            snapshot(buffer)
            if linewise {
                delete(range, linewise: true, &buffer)
            } else {
                buffer.replace(range, with: "")
                buffer.setCursor(range.lowerBound)
            }
            clampNormal(&buffer)
            noteChange()
            return []
        default: // c
            snapshot(buffer)
            if linewise {
                // cc keeps the line: clear its content, stay on it.
                let start = firstNonBlank(buffer, from: range.lowerBound)
                let indent = start > range.lowerBound ? range.lowerBound..<start : nil
                buffer.replace(range, with: indent.map { buffer.slice($0) } ?? "")
            } else {
                buffer.replace(range, with: "")
            }
            return enterInsert(&buffer, snapshotTaken: true)
        }
    }

    /// Delete whole lines, taking the newline after them (or before, on
    /// the last line), and land on the first non-blank of what follows.
    private mutating func delete(_ range: Range<Int>, linewise: Bool, _ buffer: inout Draft.Buffer) {
        guard linewise else {
            buffer.replace(range, with: "")
            buffer.setCursor(range.lowerBound)
            return
        }
        var lower = range.lowerBound
        var upper = range.upperBound
        if upper < buffer.count, buffer.characters[upper] == "\n" {
            upper += 1
        } else if lower > 0 {
            lower -= 1
        }
        buffer.replace(lower..<upper, with: "")
        buffer.setCursor(firstNonBlank(buffer, from: min(lower, max(0, buffer.count - 1))))
    }

    private func lineRange(covering range: Range<Int>, _ buffer: Draft.Buffer, keepNewline: Bool = false) -> Range<Int> {
        let start = buffer.lineStart(from: range.lowerBound)
        let end = buffer.lineEnd(from: max(range.lowerBound, range.upperBound - 1))
        return start..<end
    }

    private mutating func join(_ buffer: inout Draft.Buffer) {
        let end = buffer.lineEnd(from: buffer.cursor)
        guard end < buffer.count else { return }
        var next = end + 1
        while next < buffer.count, buffer.characters[next] == " " { next += 1 }
        let needsSpace = end > 0 && !buffer.characters[end - 1].isWhitespace && next < buffer.count
            && buffer.characters[next] != "\n" && !")".contains(buffer.characters[next])
        buffer.replace(end..<next, with: needsSpace ? " " : "")
        buffer.setCursor(max(0, min(end, buffer.count - 1)))
    }

    private mutating func put(_ text: String, after: Bool, _ buffer: inout Draft.Buffer) {
        if text.hasSuffix("\n") {
            // Linewise: a whole line below or above this one.
            let body = String(text.dropLast())
            if after {
                let end = buffer.lineEnd(from: buffer.cursor)
                let atEnd = end >= buffer.count
                buffer.replace(end..<end, with: (atEnd ? "\n" : "\n") + body + (atEnd ? "" : ""))
                let start = end + 1
                buffer.setCursor(firstNonBlank(buffer, from: start))
            } else {
                let start = buffer.lineStart(from: buffer.cursor)
                buffer.replace(start..<start, with: body + "\n")
                buffer.setCursor(firstNonBlank(buffer, from: start))
            }
        } else {
            let at = after ? min(buffer.count, buffer.cursor + (buffer.count > 0 ? 1 : 0)) : buffer.cursor
            buffer.replace(at..<at, with: text)
            buffer.setCursor(max(at, buffer.cursor - 1))
        }
    }

    // MARK: - Insert

    private var visualInsertOpen = false

    private mutating func enterInsert(_ buffer: inout Draft.Buffer, snapshotTaken: Bool = false) -> [Effect] {
        if !snapshotTaken { snapshot(buffer) }
        if !replaying {
            visualInsertOpen = inVisualChange
            if !inVisualChange { lastVisual = nil }
        }
        mode = .insert
        insertOpen = true
        inserted = []
        changed = true
        return [.enterInsert]
    }

    // MARK: - History

    private mutating func snapshot(_ buffer: Draft.Buffer) {
        undoStack.append(Snapshot(characters: buffer.characters, cursor: buffer.cursor))
        if undoStack.count > Self.historyCap { undoStack.removeFirst() }
        redoStack = []
    }

    private mutating func undo(_ buffer: inout Draft.Buffer) -> [Effect] {
        guard let last = undoStack.popLast() else { return [.flash("⌂ nothing to undo")] }
        redoStack.append(Snapshot(characters: buffer.characters, cursor: buffer.cursor))
        buffer.restore(characters: last.characters, cursor: last.cursor)
        clampNormal(&buffer)
        return []
    }

    private mutating func redo(_ buffer: inout Draft.Buffer) -> [Effect] {
        guard let next = redoStack.popLast() else { return [.flash("⌂ nothing to redo")] }
        undoStack.append(Snapshot(characters: buffer.characters, cursor: buffer.cursor))
        buffer.restore(characters: next.characters, cursor: next.cursor)
        clampNormal(&buffer)
        return []
    }

    private mutating func noteChange() {
        changed = true
        guard !replaying else { return }
        if inVisualChange {
            lastChange = []
        } else {
            lastChange = recording
            lastVisual = nil
        }
        // The change is complete; the next command starts its own record.
        recording = []
    }

    private mutating func repeatLast(_ buffer: inout Draft.Buffer, pasteboard: () -> String?, times: Int) -> [Effect] {
        if let visual = lastVisual, lastChange.isEmpty {
            // Reselect the same shape from the cursor and do it again.
            replaying = true
            defer { replaying = false; recording = [] }
            var effects: [Effect] = []
            for _ in 0..<times {
                mode = .visual(line: visual.line)
                visualAnchor = buffer.cursor
                if visual.line {
                    for _ in 1..<max(1, visual.length) { buffer.moveDown() }
                } else {
                    buffer.setCursor(min(max(0, buffer.count - 1), buffer.cursor + max(0, visual.length - 1)))
                }
                effects = visualCommand(visual.op, &buffer, pasteboard: pasteboard)
                if mode == .insert {
                    for k in lastVisualInsert {
                        switch k {
                        case .delete: buffer.deleteBackward()
                        case .char(let c): buffer.type(String(c))
                        default: break
                        }
                    }
                    leaveInsert(&buffer)
                }
            }
            return effects.filter { $0 != .enterInsert }
        }
        let keys = lastChange
        guard !keys.isEmpty else { return [] }
        replaying = true
        defer { replaying = false; recording = [] }
        var effects: [Effect] = []
        for _ in 0..<times {
            for k in keys {
                if mode == .insert {
                    switch k {
                    case .escape: leaveInsert(&buffer)
                    case .delete: buffer.deleteBackward()
                    case .char(let c): buffer.type(String(c))
                    default: break
                    }
                } else {
                    effects = key(k, buffer: &buffer, pasteboard: pasteboard)
                }
            }
            if mode == .insert { leaveInsert(&buffer) }
        }
        return effects.filter { $0 != .enterInsert }
    }

    // MARK: - Helpers

    private mutating func clearPending() {
        count = nil; op = nil; opCount = nil; awaiting = nil; pendingG = false; pendingObject = nil
        recording = []
    }

    /// In normal mode the cursor rests on a character, never past the
    /// last one of its line.
    private mutating func clampNormal(_ buffer: inout Draft.Buffer) {
        guard mode != .insert, buffer.count > 0 else { return }
        let end = buffer.lineEnd(from: buffer.cursor)
        let start = buffer.lineStart(from: buffer.cursor)
        if buffer.cursor >= end, end > start { buffer.setCursor(end - 1) }
    }
}

extension Draft.Buffer {
    /// The zero-based line number holding an index.
    public func lineIndex(of index: Int) -> Int {
        var line = 0
        for i in 0..<min(index, characters.count) where characters[i] == "\n" { line += 1 }
        return line
    }

    /// The start index of a zero-based line number, clamped to the last line.
    public func lineStartOfLine(_ number: Int) -> Int {
        var line = 0
        var i = 0
        while line < number, i < characters.count {
            if characters[i] == "\n" { line += 1 }
            i += 1
        }
        return lineStart(from: i)
    }

    /// True when the line holding `index` is empty or whitespace only.
    public func lineIsBlank(at index: Int) -> Bool {
        let start = lineStart(from: index), end = lineEnd(from: index)
        return characters[start..<end].allSatisfy { $0.isWhitespace }
    }
}
