import Accelerate
import CoreML
import Foundation
import LodestarCore

/// NVIDIA's Nemotron Speech Streaming 0.6B, heard as it is spoken: a
/// cache-aware streaming FastConformer encoder and a greedy RNN-T decoder,
/// through FluidInference's Core ML conversion (the 560 ms variant).
///
/// Audio is heard in chunks of 560 ms; the encoder carries its context from
/// one chunk to the next in three caches, so a word, once written, is never
/// rewritten. Measured on this Mac: words about 0.37 s behind the voice.
///
/// Everything runs on the GPU (`.cpuAndGPU`). On the Neural Engine the int8
/// encoder compiled for six minutes the first time and half a minute every
/// later load, held 2.4 GB, took 148 ms a chunk and lost the punctuation; on
/// the GPU it loads in a fraction of a second, takes about 50 ms a chunk and
/// 280 MB, but the first prediction in each process compiles its Metal
/// kernels (about 4.4 s): `warm()` pays that before anyone speaks.
///
/// One session at a time: `reset()`, `feed(_:)` as the microphone gives
/// audio, `finish()` at the end. Each returns only the tokens it found.
///
/// The pipeline is derived from FluidAudio (https://github.com/FluidInference/FluidAudio,
/// commit 16780f0: `StreamingNemotronAsrManager.swift`,
/// `StreamingNemotronAsrManager+Pipeline.swift`, `NemotronStreamingConfig.swift`,
/// `EncoderCacheManager.swift`), Copyright FluidInference, licensed under the
/// Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0).
/// Rewritten for Lodestar with the English model only (no multilingual,
/// vocabulary-bias, split-encoder or diarization paths) and the fused
/// decoder-and-joint model only; the decisions and constants are kept
/// exactly, so its text is FluidAudio's on the same audio.
public actor NemotronStream {
    public enum Failure: Error, CustomStringConvertible {
        case missing(String)
        case badVocabulary
        case badMetadata
        case notLoaded
        case badOutput(String)
        /// The encoder gave only zeros for a non-zero input: its program
        /// did not instantiate (FluidAudio's issue #739).
        case deadEncoder

        public var description: String {
            switch self {
            case .missing(let file): return "nemotron: no \(file)"
            case .badVocabulary: return "nemotron: the vocabulary is not a token list"
            case .badMetadata: return "nemotron: metadata.json is not an object"
            case .notLoaded: return "nemotron: not loaded"
            case .badOutput(let what): return "nemotron: \(what)"
            case .deadEncoder: return "nemotron: the encoder answers only zeros"
            }
        }
    }

    /// The variant's shapes, from its `metadata.json`; a key it lacks takes
    /// FluidAudio's default.
    public struct Config: Equatable, Sendable {
        public var sampleRate = 16_000
        public var melFeatures = 128
        public var chunkMelFrames = 112
        public var chunkMs = 1120
        /// Mel frames of the previous chunk put before this one's.
        public var preEncodeCache = 9
        /// The encoder's mel input: the cache and the chunk.
        public var totalMelFrames = 121
        public var vocabSize = 1024
        /// The blank token, one past the last real one.
        public var blankIdx = 1024
        public var encoderDim = 1024
        public var decoderHidden = 640
        public var decoderLayers = 2
        public var cacheChannelShape = [1, 24, 70, 1024]
        public var cacheTimeShape = [1, 24, 1024, 8]

        /// Audio samples in a chunk: one mel frame per 10 ms.
        public var chunkSamples: Int { chunkMelFrames * 160 }

        public init() {}

        public init(json data: Data) throws {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.badMetadata
            }
            func int(_ key: String, _ fallback: Int) -> Int { json[key] as? Int ?? fallback }
            sampleRate = int("sample_rate", sampleRate)
            melFeatures = int("mel_features", melFeatures)
            chunkMelFrames = int("chunk_mel_frames", chunkMelFrames)
            chunkMs = int("chunk_ms", chunkMs)
            preEncodeCache = int("pre_encode_cache", preEncodeCache)
            totalMelFrames = int("total_mel_frames", totalMelFrames)
            vocabSize = int("vocab_size", vocabSize)
            blankIdx = int("blank_idx", blankIdx)
            encoderDim = int("encoder_dim", encoderDim)
            decoderHidden = int("decoder_hidden", decoderHidden)
            decoderLayers = int("decoder_layers", decoderLayers)
            cacheChannelShape = json["cache_channel_shape"] as? [Int] ?? cacheChannelShape
            cacheTimeShape = json["cache_time_shape"] as? [Int] ?? cacheTimeShape
        }
    }

    /// One encoder frame: 10 ms mel hop × 8 subsampling.
    public static let secondsPerFrame = 0.08
    /// The most tokens the decoder may write at one encoder frame.
    static let maxSymbolsPerFrame = 10

    /// Where each file lives in the variant's folder.
    enum File {
        static let encoder = "encoder/encoder_int8.mlmodelc"
        static let decoderJoint = "decoder_joint.mlmodelc"
        static let metadata = "metadata.json"
        static let tokenizer = "tokenizer.json"
    }

    private struct Models {
        let encoder: MLModel
        let decoderJoint: MLModel
        let vocabulary: NemotronVocabulary
        let config: Config
    }

    /// The session: the encoder's caches, the decoder's state, the audio
    /// not yet a whole chunk, and where the next chunk starts.
    private struct Session {
        var cacheChannel: MLMultiArray
        var cacheTime: MLMultiArray
        var cacheLen: MLMultiArray
        /// The last `preEncodeCache` mel frames of the previous chunk,
        /// `[mels, frames]` row-major; nil before the first chunk.
        var melCache: [Float]?
        var h: MLMultiArray
        var c: MLMultiArray
        var lastToken: Int32
        var audio: Chunker
        var frameBase = 0
    }

    /// The audio not yet heard, given out a whole chunk at a time.
    struct Chunker: Equatable, Sendable {
        let size: Int
        private(set) var pending: [Float] = []

        init(size: Int) { self.size = size }

        mutating func append(_ samples: [Float]) { pending.append(contentsOf: samples) }

        /// The oldest whole chunk, still held until `drop()`.
        var next: [Float]? { pending.count >= size ? Array(pending.prefix(size)) : nil }

        mutating func drop() { pending.removeFirst(min(size, pending.count)) }

        /// What is left, padded with silence to a whole chunk; nil when
        /// nothing is.
        var tail: [Float]? {
            if pending.isEmpty { return nil }
            let left = Array(pending.prefix(size))
            return left + [Float](repeating: 0, count: size - left.count)
        }
    }

    public let folder: URL
    private var models: Models?
    private var session: Session?
    private var mel: NemotronMel?
    /// Chunks heard since the stream was made, for measuring.
    public private(set) var chunks = 0

    /// `folder` is the variant's own folder (`nemotron_coreml_560ms`), with
    /// `encoder/`, `decoder_joint.mlmodelc`, `metadata.json` and
    /// `tokenizer.json` in it.
    public init(folder: URL) {
        self.folder = folder
    }

    public var isLoaded: Bool { models != nil }

    /// The loaded variant's shapes; nil before `load()`.
    public var config: Config? { models?.config }

    /// Load the models. Quick on the GPU; the first prediction afterwards is
    /// not (see `warm()`).
    public func load() async throws {
        if models != nil { return }
        let metadataURL = folder.appendingPathComponent(File.metadata)
        let config: Config
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            config = try Config(json: Data(contentsOf: metadataURL))
        } else {
            config = Config()
        }
        let tokenizerURL = folder.appendingPathComponent(File.tokenizer)
        guard FileManager.default.fileExists(atPath: tokenizerURL.path) else { throw Failure.missing(tokenizerURL.path) }
        let vocabulary = try NemotronVocabulary(json: Data(contentsOf: tokenizerURL))

        func model(_ path: String) async throws -> MLModel {
            let url = folder.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.missing(url.path) }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndGPU
            return try await MLModel.load(contentsOf: url, configuration: configuration)
        }
        let loaded = Models(encoder: try await model(File.encoder), decoderJoint: try await model(File.decoderJoint),
                            vocabulary: vocabulary, config: config)
        models = loaded
        mel = NemotronMel(mels: config.melFeatures)
        session = try Self.freshSession(config)
    }

    /// One throwaway prediction through each model, so the first chunk
    /// spoken does not wait for the GPU's kernels to compile. Also a health
    /// check: an encoder that answers a non-zero input with only zeros
    /// throws `Failure.deadEncoder`. The session is untouched.
    public func warm() async throws {
        guard let models else { throw Failure.notLoaded }
        let config = models.config
        let fresh = try Self.freshSession(config)
        let input = try MLMultiArray(shape: [1, NSNumber(value: config.melFeatures), NSNumber(value: config.totalMelFrames)],
                                     dataType: .float32)
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, _ in
            for i in 0..<pointer.count { pointer[i] = Float(i % 17) * 0.01 + 0.1 }
        }
        let output = try encode(input, session: fresh, models: models)
        guard let encoded = output.featureValue(for: "encoded")?.multiArrayValue else {
            throw Failure.badOutput("the encoder gave no `encoded`")
        }
        let values = encoded.dataPointer.bindMemory(to: Float.self, capacity: encoded.count)
        let alive = (0..<encoded.count).contains { values[$0] != 0 }
        guard alive else { throw Failure.deadEncoder }
        let step = try Self.encoderStep(encoded, at: 0)
        _ = try decode(token: fresh.lastToken, h: fresh.h, c: fresh.c, step: step, models: models)
    }

    /// Forget the models; `load()` again to hear.
    public func unload() {
        models = nil
        session = nil
        mel = nil
    }

    /// Start a new session: the caches cleared, the buffered audio dropped,
    /// times counted from zero again.
    public func reset() throws {
        guard let models else { throw Failure.notLoaded }
        session = try Self.freshSession(models.config)
    }

    /// Hear more audio, 16 kHz mono, any length. Whole chunks are heard as
    /// they fill; the rest waits for the next call. Returns the tokens the
    /// new chunks wrote, none of them returned before.
    public func feed(_ samples: [Float]) async throws -> [Token] {
        guard let models, var session else { throw Failure.notLoaded }
        session.audio.append(samples)
        var tokens: [Token] = []
        defer { self.session = session }
        while let chunk = session.audio.next {
            try Task.checkCancellation()
            tokens += try hear(chunk, session: &session, models: models)
            session.audio.drop()
        }
        return tokens
    }

    /// The end of the session: what is left of the audio, padded with
    /// silence to a whole chunk, and heard. Returns its tokens, then starts
    /// a new session.
    public func finish() async throws -> [Token] {
        guard let models, var session else { throw Failure.notLoaded }
        try Task.checkCancellation()
        var tokens: [Token] = []
        if let tail = session.audio.tail { tokens = try hear(tail, session: &session, models: models) }
        self.session = try Self.freshSession(models.config)
        return tokens
    }

    // MARK: - One chunk

    /// A chunk through the mel, the encoder and the greedy decoder. The
    /// session is changed only when the whole chunk is heard.
    private func hear(_ samples: [Float], session: inout Session, models: Models) throws -> [Token] {
        guard let mel else { throw Failure.notLoaded }
        let config = models.config
        let chunkMel = mel.logMel(samples)
        let input = try Self.encoderInput(chunkMel, cache: session.melCache, config: config)
        let output = try encode(input, session: session, models: models)
        guard let encoded = output.featureValue(for: "encoded")?.multiArrayValue else {
            throw Failure.badOutput("the encoder gave no `encoded`")
        }
        var next = session
        if let channel = output.featureValue(for: "cache_channel_out")?.multiArrayValue { next.cacheChannel = channel }
        if let time = output.featureValue(for: "cache_time_out")?.multiArrayValue { next.cacheTime = time }
        if let length = output.featureValue(for: "cache_len_out")?.multiArrayValue { next.cacheLen = length }
        next.melCache = Self.melCache(chunkMel, config: config)

        var tokens: [Token] = []
        let frames = encoded.shape[2].intValue
        for t in 0..<frames {
            let step = try Self.encoderStep(encoded, at: t)
            for _ in 0..<Self.maxSymbolsPerFrame {
                let (token, h, c) = try decode(token: next.lastToken, h: next.h, c: next.c, step: step, models: models)
                if token == config.blankIdx { break }
                let start = Double(next.frameBase + t) * Self.secondsPerFrame
                tokens.append(Token(models.vocabulary[token] ?? "", start: start, end: start + Self.secondsPerFrame))
                next.lastToken = Int32(token)
                next.h = h
                next.c = c
            }
        }
        next.frameBase += frames
        session = next
        chunks += 1
        return tokens
    }

    private func encode(_ input: MLMultiArray, session: Session, models: Models) throws -> MLFeatureProvider {
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: models.config.totalMelFrames)
        return try models.encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "mel": MLFeatureValue(multiArray: input),
            "mel_length": MLFeatureValue(multiArray: length),
            "cache_channel": MLFeatureValue(multiArray: session.cacheChannel),
            "cache_time": MLFeatureValue(multiArray: session.cacheTime),
            "cache_len": MLFeatureValue(multiArray: session.cacheLen),
        ]))
    }

    /// One step of the fused decoder and joint: the most likely next token,
    /// and the decoder's state had it been written.
    private func decode(token: Int32, h: MLMultiArray, c: MLMultiArray, step: MLMultiArray,
                        models: Models) throws -> (Int, MLMultiArray, MLMultiArray) {
        let tokenInput = try MLMultiArray(shape: [1, 1], dataType: .int32)
        tokenInput[0] = NSNumber(value: token)
        let tokenLength = try MLMultiArray(shape: [1], dataType: .int32)
        tokenLength[0] = 1
        let output = try models.decoderJoint.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "token": MLFeatureValue(multiArray: tokenInput),
            "token_length": MLFeatureValue(multiArray: tokenLength),
            "h_in": MLFeatureValue(multiArray: h),
            "c_in": MLFeatureValue(multiArray: c),
            "encoder": MLFeatureValue(multiArray: step),
        ]))
        guard let logits = output.featureValue(for: "logits")?.multiArrayValue,
              let hOut = output.featureValue(for: "h_out")?.multiArrayValue,
              let cOut = output.featureValue(for: "c_out")?.multiArrayValue
        else { throw Failure.badOutput("the decoder gave no logits or state") }
        return (Self.argmax(logits), hOut, cOut)
    }

    // MARK: - Tensors

    private static func freshSession(_ config: Config) throws -> Session {
        func zeros(_ shape: [Int], _ type: MLMultiArrayDataType = .float32) throws -> MLMultiArray {
            let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: type)
            array.withUnsafeMutableBytes { bytes, _ in _ = memset(bytes.baseAddress!, 0, bytes.count) }
            return array
        }
        let length = try zeros([1], .int32)
        // 1, not 0: a zero-length slice fails the encoder's shape inference
        // (FluidAudio's issue #607). The caches are zero, so it is one frame
        // of silence before the voice.
        length[0] = 1
        return Session(cacheChannel: try zeros(config.cacheChannelShape), cacheTime: try zeros(config.cacheTimeShape),
                       cacheLen: length, melCache: nil,
                       h: try zeros([config.decoderLayers, 1, config.decoderHidden]),
                       c: try zeros([config.decoderLayers, 1, config.decoderHidden]),
                       lastToken: Int32(config.blankIdx), audio: Chunker(size: config.chunkSamples))
    }

    /// The encoder's `mel`, `[1, mels, totalMelFrames]`: the previous chunk's
    /// last frames (zeros before the first), then as many of this chunk's
    /// as fit; the rest zeros.
    static func encoderInput(_ chunk: (values: [Float], frames: Int), cache: [Float]?,
                             config: Config) throws -> MLMultiArray {
        let total = config.totalMelFrames, mels = config.melFeatures
        let result = try MLMultiArray(shape: [1, NSNumber(value: mels), NSNumber(value: total)], dataType: .float32)
        let values = encoderInputValues(chunk, cache: cache, config: config)
        result.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, strides in
            let s1 = strides[1], s2 = strides[2]
            for m in 0..<mels { for t in 0..<total { pointer[m * s1 + t * s2] = values[m * total + t] } }
        }
        return result
    }

    /// `encoderInput`'s values, `[mels, totalMelFrames]` row-major.
    static func encoderInputValues(_ chunk: (values: [Float], frames: Int), cache: [Float]?,
                                   config: Config) -> [Float] {
        let total = config.totalMelFrames, mels = config.melFeatures
        var values = [Float](repeating: 0, count: mels * total)
        if let cache {
            let cached = cache.count / mels
            for m in 0..<mels { for t in 0..<cached { values[m * total + t] = cache[m * cached + t] } }
        }
        let copied = min(chunk.frames, total - config.preEncodeCache)
        for m in 0..<mels {
            for t in 0..<copied { values[m * total + config.preEncodeCache + t] = chunk.values[m * chunk.frames + t] }
        }
        return values
    }

    /// The chunk's last `preEncodeCache` mel frames, for the next chunk.
    static func melCache(_ chunk: (values: [Float], frames: Int), config: Config) -> [Float] {
        let mels = config.melFeatures
        let kept = min(config.preEncodeCache, chunk.frames)
        let first = chunk.frames - kept
        var cache = [Float](repeating: 0, count: mels * kept)
        for m in 0..<mels { for t in 0..<kept { cache[m * kept + t] = chunk.values[m * chunk.frames + first + t] } }
        return cache
    }

    /// Frame `t` of the encoder's output `[1, dim, T]`, as `[1, dim, 1]`.
    static func encoderStep(_ encoded: MLMultiArray, at t: Int) throws -> MLMultiArray {
        let dim = encoded.shape[1].intValue
        let s1 = encoded.strides[1].intValue, s2 = encoded.strides[2].intValue
        let step = try MLMultiArray(shape: [1, NSNumber(value: dim), 1], dataType: .float32)
        // Read through the strides: a GPU output may be laid out padded.
        let source = encoded.dataPointer.bindMemory(to: Float.self, capacity: encoded.count)
        step.withUnsafeMutableBufferPointer(ofType: Float.self) { destination, _ in
            for d in 0..<dim { destination[d] = source[d * s1 + t * s2] }
        }
        return step
    }

    /// The index of the largest logit (the first, on a tie).
    static func argmax(_ logits: MLMultiArray) -> Int {
        let pointer = logits.dataPointer.bindMemory(to: Float.self, capacity: logits.count)
        var value: Float = -.infinity
        var index: vDSP_Length = 0
        vDSP_maxvi(pointer, 1, &value, &index, vDSP_Length(logits.count))
        return Int(index)
    }
}
