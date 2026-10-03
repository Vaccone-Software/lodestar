import Foundation
import LodestarCore
import MLX
import Tokenizers

/// Qwen3-ASR on MLX, the full tier's settling ear: a Whisper-style audio
/// encoder in front of a Qwen3 decoder, prompted with the speaker's names.
///
/// Measured on the maker's sixty recordings with the 29-term framed prompt
/// (`probe dictation ear`, M1 Max, release build): 1.7B 8-bit, 5.9% word
/// error and 86% of names exact, 0.48 s a phrase (median), 3.8 GB at its
/// peak; 0.6B 8-bit, 8.0% and 78%, 0.22 s, 2.2 GB. The same as the Python
/// probe (mlx-audio) on the same weights, within a word or two.
///
/// Everything MLX touches runs on one serial queue, so a load, the
/// phrases, and an unload never overlap.
public final class QwenEar: SettlingEar, @unchecked Sendable {
    public let name: String
    public let folder: URL

    private let queue = DispatchQueue(label: "com.vaccone.lodestar.ear.qwen", qos: .userInitiated)
    // Touched only on `queue`.
    private var model: QwenASRModel?
    private var tokenizer: Tokenizer?
    // Read from any thread.
    private let lock = NSLock()
    private var loaded = false

    public init(name: String, folder: URL) {
        self.name = name
        self.folder = folder
    }

    public var isLoaded: Bool { lock.withLock { loaded } }

    public func load() async throws {
        try await onQueue {
            guard self.model == nil else { return }
            let tokenizer = try QwenTokenizer.load(self.folder)
            try QwenPrompt.check(tokenizer)
            let model = try QwenASRModel.load(self.folder)
            // One phrase of silence builds the GPU kernels, so the first
            // phrase the speaker says is not the one that pays for them.
            _ = try Self.hear([Float](repeating: 0, count: QwenMel.sampleRate), context: ["Lodestar"],
                              model: model, tokenizer: tokenizer, cap: 4)
            self.model = model
            self.tokenizer = tokenizer
            self.lock.withLock { self.loaded = true }
        }
    }

    public func transcribe(_ samples: [Float], context: [String]) async throws -> Heard {
        try await onQueue {
            guard let model = self.model, let tokenizer = self.tokenizer else { throw QwenEarError.notLoaded }
            return Heard(try Self.hear(samples, context: context, model: model, tokenizer: tokenizer))
        }
    }

    /// Not loaded from now on; the memory goes once a phrase in flight is
    /// done. A load already queued ahead of this still finishes first, so
    /// the flag is cleared again behind it.
    public func unload() {
        lock.withLock { loaded = false }
        queue.async {
            self.model = nil
            self.tokenizer = nil
            self.lock.withLock { self.loaded = false }
            Memory.clearCache()
        }
    }

    private func onQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// One phrase, greedily: encode the audio, splice it into the prompt
    /// where the pads stand, and decode to the end of the turn.
    static func hear(_ samples: [Float], context: [String], model: QwenASRModel, tokenizer: Tokenizer,
                     cap: Int? = nil) throws -> String {
        // The processor pads anything under a second to one, with silence.
        var audio = samples
        if audio.count < QwenMel.sampleRate { audio += [Float](repeating: 0, count: QwenMel.sampleRate - audio.count) }
        let mel = QwenMel.features(audio)
        let count = qwenAudioTokens(frames: mel.dim(1))
        let heard = model.audioTower(mel)

        let ids = QwenPrompt.ids(audioTokens: count, system: QwenPrompt.system(context)) {
            tokenizer.encode(text: $0, addSpecialTokens: false)
        }
        let decoder = model.model
        let embedded = decoder.embedTokens(MLXArray(ids.map(Int32.init)))
        guard let first = ids.firstIndex(of: QwenPrompt.audioPad) else { throw QwenEarError.badPrompt }
        let input = concatenated([embedded[..<first], heard.asType(embedded.dtype), embedded[(first + count)...]], axis: 0)
            .expandedDimensions(axis: 0)

        let cache = decoder.makeCache()
        var token = argMax(decoder.lastLogits(input, cache: cache), axis: -1)
        asyncEval(token)
        var out: [Int] = []
        for _ in 0 ..< (cap ?? QwenPrompt.tokenCap(seconds: Double(samples.count) / Double(QwenMel.sampleRate))) {
            // Queue the next step before reading this one, so the GPU
            // works while the CPU waits on the value.
            let next = argMax(decoder.lastLogits(decoder.embedTokens(token.reshaped(1, 1)), cache: cache), axis: -1)
            asyncEval(next)
            let id = token.item(Int.self)
            if QwenPrompt.endOfTurn.contains(id) { break }
            out.append(id)
            token = next
        }
        let text = tokenizer.decode(tokens: out, skipSpecialTokens: true).trimmingCharacters(in: .whitespacesAndNewlines)
        // Every phrase has its own lengths, so MLX's buffer cache would keep
        // a new set each time (20 GB over sixty phrases, measured). The
        // weights stay; the scratch goes, as mlx-audio lets it go.
        Memory.clearCache()
        return text
    }
}

/// The chat prompt Qwen3-ASR was trained on, with the speaker's names in
/// the system turn and the language fixed, so the answer is plain text.
public enum QwenPrompt {
    static let endOfText = 151_643
    static let imStart = 151_644
    static let imEnd = 151_645
    static let audioStart = 151_669
    static let audioEnd = 151_670
    static let audioPad = 151_676
    static let asrText = 151_704
    static let endOfTurn: Set<Int> = [endOfText, imEnd]

    /// The system turn for these terms: the probe's framed sentence, which
    /// beat a bare list on names and on reciting the list over silence.
    /// Nil for no terms (an empty system turn).
    public static func system(_ context: [String]) -> String? {
        let terms = context.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return nil }
        return "Dictation by a software developer. Names and terms that may come up: "
            + terms.joined(separator: ", ") + ". Transcribe only what is said."
    }

    /// The prompt's ids:
    ///
    ///     <|im_start|>system\n{system}\n<|im_end|>\n
    ///     <|im_start|>user\n<|audio_start|>{pad × n}<|audio_end|><|im_end|>\n
    ///     <|im_start|>assistant\nlanguage English<asr_text>
    ///
    /// Special tokens are written as ids, never tokenized from text, so a
    /// term that looks like one stays text.
    static func ids(audioTokens: Int, system: String?, encode: (String) -> [Int]) -> [Int] {
        var ids = [imStart]
        ids += encode("system\n" + (system.map { $0 + "\n" } ?? ""))
        ids += [imEnd] + encode("\n") + [imStart] + encode("user\n") + [audioStart]
        ids += [Int](repeating: audioPad, count: audioTokens)
        ids += [audioEnd, imEnd] + encode("\n") + [imStart] + encode("assistant\nlanguage English") + [asrText]
        return ids
    }

    /// The most tokens a phrase this long may take. The densest of the
    /// maker's sixty recordings ran 3.5 a second (spelled letters, code
    /// names); twelve a second plus a margin ends only a runaway loop.
    public static func tokenCap(seconds: Double) -> Int {
        32 + Int((max(seconds, 0) * 12).rounded(.up))
    }

    /// The ids above are the tokenizer's own.
    static func check(_ tokenizer: Tokenizer) throws {
        let expected: [String: Int] = [
            "<|endoftext|>": endOfText, "<|im_start|>": imStart, "<|im_end|>": imEnd,
            "<|audio_start|>": audioStart, "<|audio_end|>": audioEnd, "<|audio_pad|>": audioPad,
            "<asr_text>": asrText,
        ]
        for (token, id) in expected where tokenizer.convertTokenToId(token) != id {
            throw QwenEarError.tokenizer(token)
        }
    }
}

enum QwenEarError: Error, CustomStringConvertible {
    case missing(String)
    case badConfig(String)
    case tokenizer(String)
    case badPrompt
    case notLoaded

    var description: String {
        switch self {
        case .missing(let file): return "qwen ear: \(file) missing or unreadable"
        case .badConfig(let key): return "qwen ear: config has no usable \(key)"
        case .tokenizer(let token): return "qwen ear: tokenizer disagrees on \(token)"
        case .badPrompt: return "qwen ear: prompt has no audio"
        case .notLoaded: return "qwen ear: not loaded"
        }
    }
}
