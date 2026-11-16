import Foundation

/// A streaming recognizer's pieces made into what the draft reads: the
/// words of the phrase still open, as they grow, and each phrase settled
/// at a pause, with when each word was said.
///
/// A cache-aware streaming model (Nemotron) never takes back a piece it
/// wrote, so there is nothing to revise, only where a phrase ends. Apple's
/// recognizer ends one wherever the speaker pauses, and the draft's
/// settler, seams and ears are built on that, so a phrase ends here the
/// same way: at a chunk that added nothing after one that ended a
/// sentence, or at the second such chunk in a row whatever the last word
/// was. At 560 ms a chunk, a sentence settles about half a second after
/// the voice stops, and a pause mid-sentence after a second.
public struct LivePhrases: Sendable {
    /// One piece of the model's vocabulary: SentencePiece writes "▁" where
    /// a word begins. Times in seconds of the session's audio.
    public struct Piece: Equatable, Sendable {
        public let text: String
        public let start: Double
        public let end: Double
        public init(_ text: String, start: Double, end: Double) {
            self.text = text
            self.start = start
            self.end = end
        }
    }

    public enum Event: Equatable, Sendable {
        /// The open phrase so far, which only grows.
        case volatile(String)
        /// A phrase closed at a pause.
        case settled(Heard)
    }

    /// Quiet chunks after a sentence's end, and after any other word,
    /// before the phrase settles.
    public static let quietAfterSentence = 1
    public static let quietAfterWord = 2

    private var open: [Piece] = []
    private var quiet = 0

    public init() {}

    /// One chunk's new pieces: what the draft shows now.
    public mutating func take(_ pieces: [Piece]) -> [Event] {
        guard pieces.isEmpty else {
            open += pieces
            quiet = 0
            let text = Self.heard(open).text
            return text.isEmpty ? [] : [.volatile(text)]
        }
        guard !open.isEmpty else { return [] }
        quiet += 1
        let heard = Self.heard(open)
        let ended = heard.text.last.map { ".?!".contains($0) } ?? false
        guard quiet >= (ended ? Self.quietAfterSentence : Self.quietAfterWord) else { return [] }
        open = []
        quiet = 0
        return heard.text.isEmpty ? [] : [.settled(heard)]
    }

    /// The session ends: what is open settles as it stands.
    public mutating func finish(_ pieces: [Piece] = []) -> [Event] {
        open += pieces
        defer { open = []; quiet = 0 }
        let heard = Self.heard(open)
        return heard.text.isEmpty ? [] : [.settled(heard)]
    }

    /// Pieces joined into words: a word begins at "▁", and every word but
    /// the first carries the space before it, so the words joined are the
    /// text (as Apple's runs are).
    public static func heard(_ pieces: [Piece]) -> Heard {
        var words: [(text: String, start: Double, end: Double)] = []
        for piece in pieces {
            let starts = piece.text.hasPrefix("▁")
            let body = starts ? String(piece.text.dropFirst()) : piece.text
            if starts || words.isEmpty {
                guard !body.isEmpty || !words.isEmpty || starts else { continue }
                words.append((body, piece.start, piece.end))
            } else {
                words[words.count - 1].text += body
                words[words.count - 1].end = piece.end
            }
        }
        words = words.filter { !$0.text.isEmpty }
        let made = words.enumerated().map { i, word in
            Heard.Word(i == 0 ? word.text : " " + word.text, start: word.start, end: word.end)
        }
        return Heard(made.map(\.text).joined(), words: made)
    }
}
