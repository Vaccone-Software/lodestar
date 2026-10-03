@preconcurrency import CoreML
import Foundation
import LodestarCore

/// Parakeet TDT 0.6B on the Neural Engine, through Core ML.
///
/// Four compiled models from FluidInference's conversion (CC-BY-4.0, after
/// NVIDIA's parakeet-tdt-0.6b-v2): the mel spectrogram, the FastConformer
/// encoder (a fixed 15 s window, 128 × 1501 mel frames in, 188 frames of
/// 80 ms out), the two-layer LSTM decoder, and the joint, which already
/// picks the token, its probability and how many frames it lasts. The
/// greedy loop in between is ours. Longer audio is heard in overlapping
/// windows and joined at the seams (`ParakeetSeams`).
///
/// Measured on the maker's recordings: about 0.1 s for a phrase after its
/// audio ends, and the first load compiles for the Neural Engine (about
/// 30 s, once per OS and build; Core ML caches it).
///
/// The decode loop is derived from FluidAudio (https://github.com/FluidInference/FluidAudio,
/// commit 0b1f462: `TdtDecoderV3.swift`, `AsrManager+Pipeline.swift`,
/// `ChunkProcessor.swift`), Copyright FluidInference, licensed under the
/// Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0).
/// Rewritten for Lodestar without the streaming, language-filter and
/// vocabulary-boost paths; the decisions and constants are kept exactly.
public final class ParakeetEar: SettlingEar, @unchecked Sendable {
    /// Which Parakeet: the files differ only in the joint's name and the
    /// vocabulary's size.
    public struct Variant: Sendable, Equatable {
        public let name: String
        let joint: String
        /// The blank token: one past the last real token.
        let blank: Int
        public let manifest: EarManifest

        public static let v2 = Variant(name: "parakeet-v2", joint: "JointDecision", blank: 1024, manifest: manifestV2)
        /// v3 is multilingual. It loads and decodes with the same code, but
        /// FluidAudio joins v3's long windows differently (silence-aligned
        /// starts, an end-aligned last window, a retry for windows that
        /// decode blank), which this does not do; measured on short phrases.
        public static let v3 = Variant(name: "parakeet-v3", joint: "JointDecisionv3", blank: 8192, manifest: manifestV3)
    }

    public enum Failure: Error, CustomStringConvertible {
        case missing(String)
        case badVocabulary
        case notLoaded
        case badOutput(String)

        public var description: String {
            switch self {
            case .missing(let file): return "parakeet: no \(file)"
            case .badVocabulary: return "parakeet: the vocabulary is not a token list"
            case .notLoaded: return "parakeet: not loaded"
            case .badOutput(let what): return "parakeet: \(what)"
            }
        }
    }

    public let variant: Variant
    public let folder: URL
    public var name: String { variant.name }

    private let lock = NSLock()
    private var models: Models?

    public init(_ variant: Variant = .v2, folder: URL) {
        self.variant = variant
        self.folder = folder
    }

    public var isLoaded: Bool { lock.withLock { models != nil } }

    public func load() async throws {
        if isLoaded { return }
        let vocabularyURL = folder.appendingPathComponent("parakeet_vocab.json")
        guard let data = try? Data(contentsOf: vocabularyURL) else { throw Failure.missing(vocabularyURL.path) }
        let vocabulary = try ParakeetVocabulary(json: data)
        guard (0..<variant.blank).allSatisfy({ vocabulary[$0] != nil }) else { throw Failure.badVocabulary }

        // The mel spectrogram is all CPU work; the rest is pinned to the
        // Neural Engine. Left to `.all`, Core ML may put them on the GPU,
        // where they crawl while the editor's model is running.
        func model(_ file: String, _ units: MLComputeUnits) async throws -> MLModel {
            let url = folder.appendingPathComponent("\(file).mlmodelc")
            guard FileManager.default.fileExists(atPath: url.path) else { throw Failure.missing(url.path) }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units
            return try await MLModel.load(contentsOf: url, configuration: configuration)
        }
        let loaded = Models(
            preprocessor: try await model("Preprocessor", .cpuOnly),
            encoder: try await model("Encoder", .cpuAndNeuralEngine),
            decoder: try await model("Decoder", .cpuAndNeuralEngine),
            joint: try await model(variant.joint, .cpuAndNeuralEngine),
            vocabulary: vocabulary, blank: variant.blank)
        // One silent second through every model, so the first phrase does
        // not pay for the Neural Engine's first run.
        _ = try loaded.decode(Array(repeating: 0, count: ParakeetTiming.sampleRate), declaredLength: ParakeetTiming.sampleRate,
                              audioFrames: ParakeetTiming.sampleRate / ParakeetTiming.samplesPerFrame,
                              startFrame: 0, frameOffset: 0, isLast: true)
        lock.withLock { models = loaded }
    }

    public func unload() {
        lock.withLock { models = nil }
    }

    public func transcribe(_ samples: [Float], context: [String]) async throws -> Heard {
        // `context` is not used: Parakeet has no prompt, and names are the
        // draft's own matcher's work.
        guard let models = lock.withLock({ models }) else { throw Failure.notLoaded }
        let tokens = try await models.tokens(samples)
        return ParakeetTiming.heard(tokens, vocabulary: models.vocabulary)
    }
}

/// The loaded models, and the work done with them. Core ML's predictions
/// are safe to make from several threads at once; every buffer a decode
/// writes is its own.
private final class Models: @unchecked Sendable {
    let preprocessor: MLModel
    let encoder: MLModel
    let decoder: MLModel
    let joint: MLModel
    let vocabulary: ParakeetVocabulary
    let blank: Int
    let spliceSafe: Set<Int>
    let caseVariants: [Int: Int]

    /// TDT's duration head: bin i means advance i frames.
    static let durationBins = [0, 1, 2, 3, 4]
    /// At most this many tokens at one frame before the loop is pushed on.
    static let maxSymbolsPerStep = 10
    /// A runaway guard per window (a 15 s window holds about 60 tokens).
    static let maxTokensPerWindow = 150
    /// After the last window's frames run out, the flush stops at this
    /// many blanks in a row.
    static let flushBlankLimit = 5
    static let decoderHidden = 640
    static let encoderHidden = 1024
    static let decoderLayers = 2

    init(preprocessor: MLModel, encoder: MLModel, decoder: MLModel, joint: MLModel,
         vocabulary: ParakeetVocabulary, blank: Int) {
        self.preprocessor = preprocessor
        self.encoder = encoder
        self.decoder = decoder
        self.joint = joint
        self.vocabulary = vocabulary
        self.blank = blank
        spliceSafe = ParakeetSeams.spliceSafeIds(vocabulary)
        caseVariants = ParakeetSeams.caseVariants(vocabulary)
    }

    /// Every token in `samples`, in order, frames counted from its start.
    func tokens(_ samples: [Float]) async throws -> [ParakeetToken] {
        guard !samples.isEmpty else { return [] }
        let frame = ParakeetTiming.samplesPerFrame
        if samples.count <= ParakeetSeams.windowSamples {
            // One window: the audio padded to a whole frame (when that
            // still fits), and declared that long.
            var aligned = (samples.count + frame - 1) / frame * frame
            if aligned > ParakeetSeams.windowSamples { aligned = samples.count }
            return try decode(samples, declaredLength: aligned, audioFrames: (aligned + frame - 1) / frame,
                              startFrame: 0, frameOffset: 0, isLast: true)
        }
        // Overlapping windows, heard at once (Core ML queues them for the
        // Neural Engine), then joined in order.
        let windows = ParakeetSeams.windows(total: samples.count)
        let heard = try await withThrowingTaskGroup(of: (Int, [ParakeetToken]).self) { group in
            for (index, window) in windows.enumerated() {
                group.addTask {
                    let audio = Array(samples[window.contextStart..<window.end])
                    let tokens = try self.decode(
                        audio, declaredLength: audio.count,
                        audioFrames: (audio.count - window.context + frame - 1) / frame,
                        startFrame: window.context / frame, frameOffset: window.start / frame, isLast: window.isLast)
                    return (index, tokens)
                }
            }
            var byIndex: [Int: [ParakeetToken]] = [:]
            for try await (index, tokens) in group { byIndex[index] = tokens }
            return windows.indices.map { byIndex[$0] ?? [] }
        }
        var merged = heard[0]
        for next in heard.dropFirst() {
            merged = ParakeetSeams.merge(merged, next, spliceSafe: spliceSafe, caseVariants: caseVariants)
        }
        merged = ParakeetSeams.monotonic(merged)
        merged = ParakeetSeams.collapseCaseDuplicates(merged, vocabulary: vocabulary)
        if merged.count > 1 { merged = try repairGaps(merged, samples: samples) }
        return merged
    }

    /// Re-hear the gaps a join left where there was speech, with a fresh
    /// window placed at each, and keep only what falls inside the gap.
    private func repairGaps(_ tokens: [ParakeetToken], samples: [Float]) throws -> [ParakeetToken] {
        let threshold = ParakeetSeams.speechThreshold(samples)
        let frame = ParakeetTiming.samplesPerFrame
        var working = tokens
        var probes = 0
        var probed = Set<Int>()
        for _ in 0..<3 {
            var inserts: [ParakeetToken] = []
            for gap in ParakeetSeams.gaps(in: working, samples: samples, threshold: threshold, probed: probed) {
                guard probes < ParakeetSeams.repairMaxProbes else { break }
                guard !probed.contains(gap.startFrame) else { continue }
                probed.insert(gap.startFrame)
                probes += 1
                let lead = ParakeetSeams.neighbor(working, from: gap.after, step: -1, vocabulary: vocabulary)
                let tail = ParakeetSeams.neighbor(working, from: gap.after + 1, step: 1, vocabulary: vocabulary)
                for start in gap.placements {
                    let end = min(start + ParakeetSeams.repairWindowSamples, samples.count)
                    guard end > start else { continue }
                    let audio = Array(samples[start..<end])
                    let heard = try decode(audio, declaredLength: audio.count,
                                           audioFrames: (audio.count + frame - 1) / frame,
                                           startFrame: 0, frameOffset: start / frame, isLast: end >= samples.count)
                    let candidate = ParakeetSeams.spliceCandidate(
                        heard, gapStart: gap.startFrame, gapEnd: gap.endFrame, lead: lead, tail: tail,
                        spliceSafe: spliceSafe, vocabulary: vocabulary)
                    if !candidate.isEmpty {
                        inserts += candidate
                        break
                    }
                }
            }
            guard !inserts.isEmpty else { break }
            working += inserts
            working.sort { $0.frame < $1.frame }
        }
        return working
    }

    // MARK: - One window

    /// One window through the mel, the encoder and the greedy TDT loop.
    ///
    /// - Parameters:
    ///   - samples: the window's audio (at most 15 s), padded here to 15 s.
    ///   - declaredLength: the samples the preprocessor is told are audio.
    ///   - audioFrames: encoder frames that hold this window's own audio.
    ///   - startFrame: the first frame decoded (1 skips the left context).
    ///   - frameOffset: added to every frame, to count from the recording's start.
    ///   - isLast: the last window flushes what the decoder still holds.
    func decode(_ samples: [Float], declaredLength: Int, audioFrames: Int, startFrame: Int,
                frameOffset: Int, isLast: Bool) throws -> [ParakeetToken] {
        let (encoded, encodedLength) = try encode(samples, declaredLength: declaredLength)
        guard encodedLength > 1 else { return [] }
        let frames = try EncoderFrames(encoded, validLength: encodedLength)

        let options = MLPredictionOptions()
        let step = try Step(frames: frames)
        var state = try DecoderState()
        var tokens: [ParakeetToken] = []

        var time = startFrame
        let effectiveLength = min(encodedLength, audioFrames)
        let lastFrame = effectiveLength - 1
        guard time < effectiveLength else { return [] }
        var safeTime = min(time, lastFrame)
        var emittedAt = time

        // The decoder starts from the blank, as RNN-T does.
        try runDecoder(blank, state: &state, into: step, options: options)

        var lastEmission = -1
        var emissionsHere = 0
        var emittedCount = 0
        var active = true
        while active {
            var decision = try runJoint(step, frame: safeTime, options: options)
            var label = decision.token
            var duration = try Self.frames(forBin: decision.durationBin)
            var isBlank = label == blank
            if !isBlank, duration == 0, time == lastEmission, emissionsHere >= 1 { duration = 1 }
            if isBlank, duration == 0 { duration = 1 }
            emittedAt = time
            time += duration
            safeTime = min(time, lastFrame)
            active = time < effectiveLength
            // Blanks do not change what was said: skip through them with
            // the same decoder output.
            while active, isBlank {
                emittedAt = time
                decision = try runJoint(step, frame: safeTime, options: options)
                label = decision.token
                duration = try Self.frames(forBin: decision.durationBin)
                isBlank = label == blank
                if isBlank, duration == 0 { duration = 1 }
                time += duration
                safeTime = min(time, lastFrame)
                active = time < effectiveLength
            }
            if active, label != blank {
                emittedCount += 1
                if emittedCount > Self.maxTokensPerWindow { break }
                tokens.append(ParakeetToken(label, frame: emittedAt + frameOffset,
                                            confidence: Self.clamp(decision.probability), duration: duration))
                try runDecoder(label, state: &state, into: step, options: options)
                if emittedAt == lastEmission {
                    emissionsHere += 1
                } else {
                    lastEmission = emittedAt
                    emissionsHere = 1
                }
                if emissionsHere >= Self.maxSymbolsPerStep {
                    time = min(time + 1, lastFrame)
                    safeTime = min(time, lastFrame)
                    emissionsHere = 0
                    lastEmission = -1
                }
            }
            active = time < effectiveLength
        }

        // The last window: ask again at the final frames for anything the
        // decoder still holds, until it says blank five times running.
        if isLast {
            var steps = 0
            var blanks = 0
            var flushTime = time
            while steps < Self.maxSymbolsPerStep, blanks < Self.flushBlankLimit {
                let candidates = [min(flushTime, frames.count - 1),
                                  min(effectiveLength - 1, frames.count - 1),
                                  min(max(0, effectiveLength - 2), frames.count - 1)]
                let decision = try runJoint(step, frame: candidates[steps % candidates.count], options: options)
                let duration = try Self.frames(forBin: decision.durationBin)
                if decision.token == blank {
                    blanks += 1
                } else {
                    blanks = 0
                    tokens.append(ParakeetToken(decision.token, frame: min(flushTime, effectiveLength - 1) + frameOffset,
                                                confidence: Self.clamp(decision.probability), duration: duration))
                    try runDecoder(decision.token, state: &state, into: step, options: options)
                }
                flushTime = min(flushTime + max(1, duration), effectiveLength)
                steps += 1
            }
        }
        return tokens
    }

    static func frames(forBin bin: Int) throws -> Int {
        guard durationBins.indices.contains(bin) else { throw ParakeetEar.Failure.badOutput("duration bin \(bin)") }
        return durationBins[bin]
    }

    static func clamp(_ p: Float) -> Float { p.isFinite ? max(0, min(1, p)) : 0 }

    /// The mel spectrogram and the encoder: [1, 1024, 188] and its length.
    private func encode(_ samples: [Float], declaredLength: Int) throws -> (MLMultiArray, Int) {
        let window = ParakeetSeams.windowSamples
        let audio = try MLMultiArray(shape: [1, NSNumber(value: window)], dataType: .float32)
        let pointer = audio.dataPointer.bindMemory(to: Float.self, capacity: window)
        let count = min(samples.count, window)
        samples.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: count) }
        if count < window { (pointer + count).initialize(repeating: 0, count: window - count) }
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: declaredLength)
        let mel = try preprocessor.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": MLFeatureValue(multiArray: audio),
            "audio_length": MLFeatureValue(multiArray: length),
        ]))
        guard let melArray = mel.featureValue(for: "mel")?.multiArrayValue,
              let melLength = mel.featureValue(for: "mel_length")?.multiArrayValue
        else { throw ParakeetEar.Failure.badOutput("no mel") }
        let encoded = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "mel": MLFeatureValue(multiArray: melArray),
            "mel_length": MLFeatureValue(multiArray: melLength),
        ]))
        guard let output = encoded.featureValue(for: "encoder")?.multiArrayValue,
              let outputLength = encoded.featureValue(for: "encoder_length")?.multiArrayValue
        else { throw ParakeetEar.Failure.badOutput("no encoder output") }
        return (output, outputLength[0].intValue)
    }

    /// The decoder's output for `token` written into the joint's input, and
    /// its state advanced.
    private func runDecoder(_ token: Int, state: inout DecoderState, into step: Step,
                            options: MLPredictionOptions) throws {
        state.target[0] = NSNumber(value: token)
        options.outputBackings = ["h_out": state.hOut, "c_out": state.cOut]
        let output = try decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "targets": MLFeatureValue(multiArray: state.target),
            "target_length": MLFeatureValue(multiArray: state.targetLength),
            "h_in": MLFeatureValue(multiArray: state.h),
            "c_in": MLFeatureValue(multiArray: state.c),
        ]), options: options)
        guard let projection = output.featureValue(for: "decoder")?.multiArrayValue else {
            throw ParakeetEar.Failure.badOutput("no decoder output")
        }
        try step.setDecoder(projection)
        state.advance()
    }

    private struct Decision { let token: Int; let probability: Float; let durationBin: Int }

    private func runJoint(_ step: Step, frame: Int, options: MLPredictionOptions) throws -> Decision {
        try step.setEncoder(frame: frame)
        options.outputBackings = ["token_id": step.tokenId, "token_prob": step.tokenProb, "duration": step.duration]
        let output = try joint.prediction(from: step, options: options)
        guard let id = output.featureValue(for: "token_id")?.multiArrayValue,
              let prob = output.featureValue(for: "token_prob")?.multiArrayValue,
              let duration = output.featureValue(for: "duration")?.multiArrayValue
        else { throw ParakeetEar.Failure.badOutput("no joint output") }
        return Decision(token: id.dataPointer.load(as: Int32.self).asInt,
                        probability: prob.dataPointer.load(as: Float.self),
                        durationBin: duration.dataPointer.load(as: Int32.self).asInt)
    }
}

private extension Int32 {
    var asInt: Int { Int(self) }
}

/// The LSTM's two layers of hidden and cell state, double-buffered so a
/// prediction never writes the arrays it reads.
private struct DecoderState {
    var h: MLMultiArray
    var c: MLMultiArray
    var hOut: MLMultiArray
    var cOut: MLMultiArray
    let target: MLMultiArray
    let targetLength: MLMultiArray

    init() throws {
        let shape: [NSNumber] = [NSNumber(value: Models.decoderLayers), 1, NSNumber(value: Models.decoderHidden)]
        func zeros() throws -> MLMultiArray {
            let array = try MLMultiArray(shape: shape, dataType: .float32)
            array.dataPointer.bindMemory(to: Float.self, capacity: array.count).initialize(repeating: 0, count: array.count)
            return array
        }
        h = try zeros(); c = try zeros(); hOut = try zeros(); cOut = try zeros()
        target = try MLMultiArray(shape: [1, 1], dataType: .int32)
        targetLength = try MLMultiArray(shape: [1], dataType: .int32)
        targetLength[0] = 1
    }

    mutating func advance() {
        swap(&h, &hOut)
        swap(&c, &cOut)
    }
}

/// The joint's input, one encoder frame and the decoder's last output,
/// kept in two arrays that every step rewrites in place.
private final class Step: NSObject, MLFeatureProvider {
    let encoderStep: MLMultiArray
    let decoderStep: MLMultiArray
    let tokenId: MLMultiArray
    let tokenProb: MLMultiArray
    let duration: MLMultiArray
    private let frames: EncoderFrames

    init(frames: EncoderFrames) throws {
        self.frames = frames
        encoderStep = try MLMultiArray(shape: [1, NSNumber(value: Models.encoderHidden), 1], dataType: .float32)
        decoderStep = try MLMultiArray(shape: [1, NSNumber(value: Models.decoderHidden), 1], dataType: .float32)
        tokenId = try MLMultiArray(shape: [1, 1, 1], dataType: .int32)
        tokenProb = try MLMultiArray(shape: [1, 1, 1], dataType: .float32)
        duration = try MLMultiArray(shape: [1, 1, 1], dataType: .int32)
    }

    var featureNames: Set<String> { ["encoder_step", "decoder_step"] }

    func featureValue(for name: String) -> MLFeatureValue? {
        switch name {
        case "encoder_step": return MLFeatureValue(multiArray: encoderStep)
        case "decoder_step": return MLFeatureValue(multiArray: decoderStep)
        default: return nil
        }
    }

    func setEncoder(frame: Int) throws {
        try frames.copy(frame: frame, into: encoderStep)
    }

    /// The decoder's [1, 640, 1] (or [1, 1, 640]) projection, copied in.
    func setDecoder(_ projection: MLMultiArray) throws {
        let shape = projection.shape.map(\.intValue)
        guard shape.count == 3, projection.dataType == .float32,
              let axis = [2, 1].first(where: { shape[$0] == Models.decoderHidden })
        else { throw ParakeetEar.Failure.badOutput("decoder projection \(shape)") }
        let stride = projection.strides[axis].intValue
        let source = projection.dataPointer.bindMemory(to: Float.self, capacity: projection.count)
        let destination = decoderStep.dataPointer.bindMemory(to: Float.self, capacity: decoderStep.count)
        let destinationStride = decoderStep.strides[1].intValue
        for k in 0..<Models.decoderHidden { destination[k * destinationStride] = source[k * stride] }
    }
}

/// The encoder's output read frame by frame, whatever its layout.
private struct EncoderFrames {
    let count: Int
    private let array: MLMultiArray
    private let hiddenStride: Int
    private let timeStride: Int

    init(_ array: MLMultiArray, validLength: Int) throws {
        let shape = array.shape.map(\.intValue)
        guard shape.count == 3, shape[0] == 1, array.dataType == .float32,
              shape[1] == Models.encoderHidden || shape[2] == Models.encoderHidden
        else { throw ParakeetEar.Failure.badOutput("encoder output \(shape) \(array.dataType.rawValue)") }
        let hiddenAxis = shape[1] == Models.encoderHidden ? 1 : 2
        let timeAxis = 3 - hiddenAxis
        self.array = array
        hiddenStride = array.strides[hiddenAxis].intValue
        timeStride = array.strides[timeAxis].intValue
        count = min(validLength, shape[timeAxis])
    }

    func copy(frame: Int, into destination: MLMultiArray) throws {
        guard frame >= 0, frame < count else { throw ParakeetEar.Failure.badOutput("encoder frame \(frame) of \(count)") }
        let source = array.dataPointer.bindMemory(to: Float.self, capacity: array.count) + frame * timeStride
        let target = destination.dataPointer.bindMemory(to: Float.self, capacity: destination.count)
        let targetStride = destination.strides[1].intValue
        if hiddenStride == 1, targetStride == 1 {
            target.update(from: source, count: Models.encoderHidden)
        } else {
            for k in 0..<Models.encoderHidden { target[k * targetStride] = source[k * hiddenStride] }
        }
    }
}
