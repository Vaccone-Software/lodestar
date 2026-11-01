import Foundation

extension Draft {
    /// What the pointer means to the text: the units a click, a double
    /// click and a triple click select, and the selection a press and a
    /// drag make between them. Pure arithmetic over the buffer; the panel
    /// turns a point on the glass into a `Hit`, and the controller decides
    /// what each style does with what comes back.
    ///
    /// Two kinds of index meet here and are kept apart on purpose. An
    /// *insertion point* lies between characters, and a caret or a Mac
    /// selection's ends are insertion points. The *character under the
    /// pointer* is one the pointer is over, and a word or a line is the
    /// one that character belongs to. A click on the right half of a
    /// letter puts the caret after it, and double-clicking the same spot
    /// still selects the word the letter is in.
    public enum Pointer {
        /// How much a press selects: a point, a word, a line. Double and
        /// triple click choose the second and third; a drag keeps its
        /// grain, so a drag begun on a word grows by whole words.
        public enum Grain: Equatable, Sendable {
            case character, word, line

            /// What the click count of a press chooses: one is a point, two
            /// a word, three and beyond a line.
            public init(clicks: Int) {
                self = clicks >= 3 ? .line : clicks == 2 ? .word : .character
            }
        }

        /// Where a point on the text landed.
        public struct Hit: Equatable, Sendable {
            /// The insertion point nearest the pointer, between characters.
            public var insertion: Int
            /// The character the pointer is over. The text's end, or the
            /// newline a line's end stands on, when it is over neither.
            public var character: Int

            public init(insertion: Int, character: Int) {
                self.insertion = insertion
                self.character = character
            }

            /// A hit with the two together, for a place already known as
            /// an index (a keyboard move, an autoscroll step).
            public init(at index: Int) {
                self.init(insertion: index, character: index)
            }
        }

        // MARK: Units

        /// The word the character at `index` belongs to, as the half-open
        /// range a double click selects. Letters, digits and underscores
        /// make a word, and an apostrophe between two letters stays in it
        /// (`don't`, `Rocco's`); a run of spaces or tabs is a unit of its
        /// own, which a Mac selects as well; any other character is a unit
        /// alone. The text's end, or a newline, has no unit of its own and
        /// takes the character before it, so a double click past the last
        /// word of a line selects that word; after a newline, or at the
        /// start, there is nothing to take and the range is empty.
        public static func wordRange(at index: Int, in buffer: Buffer) -> Range<Int> {
            let text = buffer.characters
            var i = min(max(index, 0), text.count)
            if i == text.count || text[i] == "\n" {
                guard i > 0, text[i - 1] != "\n" else { return i..<i }
                i -= 1
            }
            let wordy = { (j: Int) -> Bool in isWordCharacter(text, at: j) }
            let spacey = { (j: Int) -> Bool in text[j] == " " || text[j] == "\t" }
            let member: (Int) -> Bool
            if wordy(i) { member = wordy } else if spacey(i) { member = spacey } else { return i..<i + 1 }
            var lower = i, upper = i + 1
            while lower > 0, member(lower - 1) { lower -= 1 }
            while upper < text.count, member(upper) { upper += 1 }
            return lower..<upper
        }

        /// Whether the character at `j` is part of a word: a letter, a
        /// digit or an underscore, or an apostrophe with a letter on each
        /// side.
        private static func isWordCharacter(_ text: [Character], at j: Int) -> Bool {
            let c = text[j]
            if c.isLetter || c.isNumber || c == "_" { return true }
            guard c == "'" || c == "\u{2019}", j > 0, j + 1 < text.count else { return false }
            return text[j - 1].isLetter && text[j + 1].isLetter
        }

        /// The logical line holding the character at `index`, with its
        /// newline: what a triple click selects, and what a Mac calls a
        /// paragraph. The last line has no newline to take. An index past
        /// the end is the last line, and the empty line after a final
        /// newline is the empty range at the end.
        public static func lineRange(at index: Int, in buffer: Buffer) -> Range<Int> {
            let i = min(max(index, 0), buffer.count)
            let start = buffer.lineStart(from: i)
            let end = buffer.lineEnd(from: i)
            return start..<(end < buffer.count ? end + 1 : end)
        }

        /// The unit a press selects at a hit: the insertion point itself
        /// (an empty range) for a character, else the word or the line
        /// under the pointer.
        public static func range(at hit: Hit, grain: Grain, in buffer: Buffer) -> Range<Int> {
            switch grain {
            case .character: return hit.insertion..<hit.insertion
            case .word: return wordRange(at: hit.character, in: buffer)
            case .line: return lineRange(at: hit.character, in: buffer)
            }
        }

        // MARK: Selecting

        /// The selection a press and a pointer's current place make, as
        /// the Mac makes it: the end of the pressed unit that is farther
        /// from the pointer stays put (the anchor), and the other end goes
        /// to the edge of the unit the pointer is in, on its side. So a
        /// drag away from a double-clicked word keeps that word whole in
        /// whichever direction it goes, and the head, where the caret
        /// stands, is always the end that moves. The pointer inside the
        /// pressed unit selects the unit, head at its end, as the press
        /// alone does. The same anchor and head with a character grain is
        /// the plain drag from the press point to the pointer.
        public static func selection(press: Range<Int>, to hit: Hit, grain: Grain,
                                     in buffer: Buffer) -> (anchor: Int, head: Int) {
            let unit = range(at: hit, grain: grain, in: buffer)
            if grain == .character { return (press.lowerBound, unit.lowerBound) }
            if unit.lowerBound < press.lowerBound { return (press.upperBound, unit.lowerBound) }
            if unit.upperBound > press.upperBound { return (press.lowerBound, unit.upperBound) }
            return (press.lowerBound, press.upperBound)
        }

        /// A Mac selection's ends as the editor's visual selection, which
        /// is inclusive of the character the cursor is on: forwards, the
        /// anchor stays and the cursor is the last character taken;
        /// backwards, the anchor is the last character taken and the
        /// cursor is the first. nil when the ends meet and nothing is
        /// taken.
        public static func visualSpan(anchor: Int, head: Int) -> (anchor: Int, cursor: Int)? {
            if head > anchor { return (anchor, head - 1) }
            if head < anchor { return (anchor - 1, head) }
            return nil
        }
    }
}
