import Foundation
import LodestarCore

// Nemotron's tokens, made into text and words.
//
// Derived from FluidAudio (https://github.com/FluidInference/FluidAudio,
// commit 16780f0: `ASR/Parakeet/Streaming/Tokenizer.swift` and the token
// timings of `StreamingNemotronAsrManager+Pipeline.swift`), Copyright
// FluidInference, licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0). Rewritten for Lodestar; the
// text is joined exactly as FluidAudio joins it.

extension NemotronStream {
    /// One SentencePiece piece the decoder emitted, and when.
    public struct Token: Equatable, Sendable {
        /// The piece as the vocabulary writes it: `▁` (U+2581) marks the
        /// start of a word, punctuation is a piece of its own ("▁else", ".").
        public let text: String
        /// Seconds from the start of the session: the encoder frame (80 ms)
        /// the token was emitted at.
        public let start: Double
        /// One frame after `start`: a greedy RNN-T token has no duration.
        public let end: Double

        public init(_ text: String, start: Double, end: Double) {
            self.text = text; self.start = start; self.end = end
        }
    }

    /// SentencePiece's word-boundary mark.
    static let boundary = "\u{2581}"

    /// The tokens' text as FluidAudio's tokenizer decodes it: the pieces
    /// joined, each boundary mark a space, the ends trimmed.
    public static func text(_ tokens: [Token]) -> String {
        tokens.map(\.text).joined()
            .replacingOccurrences(of: boundary, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The tokens as words: the text split at its spaces, so punctuation
    /// stays on the word it follows and the words read back as `text(_:)`.
    /// A word starts when its first letter's piece starts and ends when its
    /// last piece ends.
    public static func words(_ tokens: [Token]) -> [Heard.Word] {
        var words: [Heard.Word] = []
        var current = ""
        var start = 0.0, end = 0.0
        func flush() {
            if !current.isEmpty { words.append(Heard.Word(current, start: start, end: end)) }
            current = ""
        }
        for token in tokens {
            let parts = token.text.replacingOccurrences(of: boundary, with: " ")
                .split(separator: " ", omittingEmptySubsequences: false)
            for (n, part) in parts.enumerated() {
                if n > 0 { flush() }
                guard !part.isEmpty else { continue }
                if current.isEmpty { start = token.start }
                current += part
                end = token.end
            }
        }
        flush()
        return words
    }

    /// The tokens as a result for the draft: the text and its words.
    public static func heard(_ tokens: [Token]) -> Heard {
        Heard(text(tokens), words: words(tokens))
    }
}

/// `tokenizer.json`: an object of id → piece.
struct NemotronVocabulary: Sendable {
    let pieces: [Int: String]

    init(_ pieces: [Int: String]) { self.pieces = pieces }

    init(json data: Data) throws {
        guard let map = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw NemotronStream.Failure.badVocabulary
        }
        var pieces: [Int: String] = [:]
        for (key, piece) in map { if let id = Int(key) { pieces[id] = piece } }
        guard !pieces.isEmpty else { throw NemotronStream.Failure.badVocabulary }
        self.pieces = pieces
    }

    subscript(id: Int) -> String? { pieces[id] }
}
