import Foundation
import LodestarCore

// Parakeet's tokens, made into words: the vocabulary, the text, the times.
//
// Derived in part from FluidAudio (https://github.com/FluidInference/FluidAudio,
// commit 0b1f462), Copyright FluidInference, licensed under the Apache License,
// Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0): the timing rules of
// `AsrManager+TokenProcessing.swift` (createTokenTimings) and the vocabulary
// format of `AsrModels.swift`. Rewritten for Lodestar; the arithmetic is kept
// exactly so the words come out where FluidAudio's do.

/// One token the decoder emitted.
struct ParakeetToken: Equatable, Sendable {
    /// The vocabulary id.
    var id: Int
    /// The encoder frame (80 ms each) it was emitted at, counted from the
    /// start of the whole recording.
    var frame: Int
    /// The joint's probability for it, 0 to 1.
    var confidence: Float
    /// How many frames the joint said it lasts (TDT's duration head).
    var duration: Int

    init(_ id: Int, frame: Int, confidence: Float = 1, duration: Int = 0) {
        self.id = id
        self.frame = frame
        self.confidence = confidence
        self.duration = duration
    }
}

/// The token vocabulary and the arithmetic from frames to seconds.
struct ParakeetVocabulary: Sendable {
    /// SentencePiece's word-boundary mark (U+2581).
    static let boundary = "\u{2581}"

    let pieces: [Int: String]

    init(_ pieces: [Int: String]) { self.pieces = pieces }

    /// `parakeet_vocab.json`: an object of id → piece (0.6B v2, v3), or an
    /// array whose index is the id.
    init(json data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        var pieces: [Int: String] = [:]
        if let array = object as? [String] {
            for (id, piece) in array.enumerated() { pieces[id] = piece }
        } else if let map = object as? [String: String] {
            for (key, piece) in map { if let id = Int(key) { pieces[id] = piece } }
        } else {
            throw ParakeetEar.Failure.badVocabulary
        }
        guard !pieces.isEmpty else { throw ParakeetEar.Failure.badVocabulary }
        self.pieces = pieces
    }

    subscript(id: Int) -> String? { pieces[id] }

    /// The text of a token sequence: pieces joined, the boundary mark a
    /// space, the ends trimmed.
    func text(_ ids: [Int]) -> String {
        ids.compactMap { pieces[$0] }.filter { !$0.isEmpty }.joined()
            .replacingOccurrences(of: Self.boundary, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Whether a piece begins a word (carries the boundary, or the space it
    /// is sometimes normalized to).
    static func startsWord(_ piece: String) -> Bool {
        piece.hasPrefix(boundary) || piece.hasPrefix(" ")
    }

    /// A piece that is only punctuation or symbols ("." in "else.").
    static func isPunctuation(_ piece: String) -> Bool {
        !piece.isEmpty && piece.unicodeScalars.allSatisfy {
            CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
        }
    }
}

/// Frames to seconds, and tokens to words.
enum ParakeetTiming {
    static let sampleRate = 16_000
    /// 10 ms mel hop × 8 subsampling: one encoder frame is 1280 samples, 80 ms.
    static let samplesPerFrame = 1280
    static let secondsPerFrame = Double(samplesPerFrame) / Double(sampleRate)
    /// TDT emits a token about one frame after the sound that made it
    /// (FluidAudio measured a median of +1 frame on v2 and v3), so a
    /// token's time is its frame minus one.
    static let emissionDelayFrames = 1

    /// Each token's start and end, seconds into the recording.
    static func times(_ tokens: [ParakeetToken]) -> [(start: Double, end: Double)] {
        var result: [(start: Double, end: Double)] = []
        result.reserveCapacity(tokens.count)
        for (i, token) in tokens.enumerated() {
            let frame = max(0, token.frame - emissionDelayFrames)
            let start = Double(frame) * secondsPerFrame
            let end: Double
            if token.duration > 0 {
                end = start + max(Double(token.duration) * secondsPerFrame, secondsPerFrame)
            } else if i + 1 < tokens.count {
                let next = Double(max(0, tokens[i + 1].frame - emissionDelayFrames)) * secondsPerFrame
                end = max(next, start + secondsPerFrame)
            } else {
                end = start + secondsPerFrame
            }
            result.append((start, max(end, start + 0.001)))
        }
        return result
    }

    /// The tokens as a result: the text, and one word per run of pieces
    /// from a word-initial piece to the next (punctuation stays on the word
    /// it follows). A word starts when its first piece starts and ends when
    /// its last ends; its confidence is the mean of its pieces'.
    static func heard(_ tokens: [ParakeetToken], vocabulary: ParakeetVocabulary) -> Heard {
        let text = vocabulary.text(tokens.map(\.id))
        let times = times(tokens)
        var words: [Heard.Word] = []
        var current = ""
        var start = 0.0, end = 0.0
        var confidences: [Float] = []
        func flush() {
            let word = current.trimmingCharacters(in: .whitespaces)
            if !word.isEmpty {
                let mean = confidences.isEmpty ? nil : Double(confidences.reduce(0, +) / Float(confidences.count))
                words.append(Heard.Word(word, start: start, end: end, confidence: mean))
            }
            current = ""
            confidences = []
        }
        for (token, time) in zip(tokens, times) {
            guard let piece = vocabulary[token.id], !piece.isEmpty else { continue }
            if ParakeetVocabulary.startsWord(piece) || current.isEmpty {
                flush()
                current = piece.replacingOccurrences(of: ParakeetVocabulary.boundary, with: "")
                    .trimmingCharacters(in: .whitespaces)
                start = time.start
            } else {
                current += piece
            }
            end = time.end
            confidences.append(token.confidence)
        }
        flush()
        return Heard(text, words: words)
    }
}
