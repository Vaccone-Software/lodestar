import AVFoundation
import XCTest
import LodestarCore
@testable import LodestarEars

/// The Nemotron stream's arithmetic, without the weights: the mel against
/// values FluidAudio computed, the encoder's input and its mel cache, the
/// chunks audio is cut into, and tokens into words.
final class NemotronStreamTests: XCTestCase {
    // MARK: - Mel

    /// Two tones and a little repeating noise, as FluidAudio's
    /// `AudioMelSpectrogram` was given it for the values below.
    private func signal(_ count: Int) -> [Float] {
        (0..<count).map { i in
            let t = Float(i) / 16000
            return 0.3 * sin(2 * Float.pi * 440 * t) + 0.1 * sin(2 * Float.pi * 1234 * t + 0.5)
                + 0.05 * Float((i * 7919) % 13) / 13 - 0.025
        }
    }

    /// Captured from FluidAudio 16780f0 (`AudioMelSpectrogram` as
    /// `NemotronMelExtractor` makes it, `computeFlatTransposed`, center
    /// padding): frame, mel bin, the value's bits.
    private let fluidAudio8960: [(t: Int, m: Int, bits: UInt32)] = [
        (0, 0, 3_239_280_115), (0, 127, 3_240_630_759), (1, 5, 3_242_313_914), (3, 64, 3_246_648_055),
        (10, 20, 3_225_604_371), (28, 100, 3_246_715_392), (56, 0, 3_234_347_282), (56, 127, 3_239_808_696),
    ]

    func testTheMelIsFluidAudiosToTheBit() {
        let mel = NemotronMel()
        let flat = mel.timeMajor(signal(8960))
        XCTAssertEqual(flat.frames, 57, "a 560 ms chunk is 57 frames with center padding")
        for (t, m, bits) in fluidAudio8960 {
            XCTAssertEqual(flat.values[t * 128 + m].bitPattern, bits, "frame \(t), bin \(m)")
        }
        XCTAssertEqual(flat.values.reduce(0.0) { $0 + Double($1) }, -88834.505975, accuracy: 1e-3)

        let short = mel.timeMajor(signal(1000))
        XCTAssertEqual(short.frames, 7)
        XCTAssertEqual(short.values.reduce(0.0) { $0 + Double($1) }, -9475.977186, accuracy: 1e-3)
        XCTAssertEqual(short.values[3 * 128 + 64].bitPattern, 3_246_648_055, "a frame does not depend on the chunk's length")
    }

    func testTheMelIsLaidOutBinMajorForTheEncoder() {
        let mel = NemotronMel()
        let samples = signal(8960)
        let flat = mel.timeMajor(samples)
        let laid = mel.logMel(samples)
        XCTAssertEqual(laid.frames, flat.frames)
        for (t, m, _) in fluidAudio8960 {
            XCTAssertEqual(laid.values[m * laid.frames + t], flat.values[t * 128 + m])
        }
        XCTAssertEqual(NemotronMel.frames(for: 8960), 57)
    }

    func testTheWindowAndFilterbankAreFluidAudios() {
        let hann = NemotronMel.hannWindow(length: 400)
        XCTAssertEqual(hann[1], 6.198883e-05, accuracy: 1e-10)
        XCTAssertEqual(hann[199], 0.9999845, accuracy: 1e-7)
        XCTAssertEqual(hann[0], 0, "symmetric: it starts and ends at zero")
        XCTAssertEqual(hann[399], 0, accuracy: 1e-7)
        let bank = NemotronMel.slaneyFilterbank(mels: 128)
        let bins = 257
        let low = (0..<bins).filter { bank[10 * bins + $0] > 0 }
        XCTAssertEqual(low, [8])
        XCTAssertEqual(bank[10 * bins + 8], 0.029578952, accuracy: 1e-9)
        let high = (0..<bins).filter { bank[127 * bins + $0] > 0 }
        XCTAssertEqual(high, Array(244...256))
        XCTAssertEqual(bank[127 * bins + 250], 0.0052231806, accuracy: 1e-10)
    }

    // MARK: - The encoder's input

    private var small: NemotronStream.Config {
        var config = NemotronStream.Config()
        config.melFeatures = 2
        config.totalMelFrames = 5
        config.preEncodeCache = 2
        return config
    }

    func testTheFirstChunkHasSilenceWhereTheCacheWillBe() {
        // Two bins, four frames: bin 0 is 1...4, bin 1 is 11...14.
        let chunk: (values: [Float], frames: Int) = ([1, 2, 3, 4, 11, 12, 13, 14], 4)
        let values = NemotronStream.encoderInputValues(chunk, cache: nil, config: small)
        XCTAssertEqual(values, [0, 0, 1, 2, 3, 0, 0, 11, 12, 13],
                       "the cache's two frames are zeros, then as many of the chunk's as fit")
    }

    func testTheCacheIsThePreviousChunksLastFrames() {
        let chunk: (values: [Float], frames: Int) = ([1, 2, 3, 4, 11, 12, 13, 14], 4)
        let cache = NemotronStream.melCache(chunk, config: small)
        XCTAssertEqual(cache, [3, 4, 13, 14], "the last two frames, the one not fed to the encoder among them")
        let next: (values: [Float], frames: Int) = ([5, 6, 7, 8, 15, 16, 17, 18], 4)
        XCTAssertEqual(NemotronStream.encoderInputValues(next, cache: cache, config: small),
                       [3, 4, 5, 6, 7, 13, 14, 15, 16, 17])
    }

    func testTheEncoderInputIsShapedForTheModel() throws {
        var config = small
        config.melFeatures = 2
        let chunk: (values: [Float], frames: Int) = ([1, 2, 3, 4, 11, 12, 13, 14], 4)
        let array = try NemotronStream.encoderInput(chunk, cache: [9, 9, 19, 19], config: config)
        XCTAssertEqual(array.shape, [1, 2, 5])
        XCTAssertEqual(array[[0, 1, 0] as [NSNumber]].floatValue, 19)
        XCTAssertEqual(array[[0, 1, 4] as [NSNumber]].floatValue, 13)
    }

    // MARK: - Chunks

    func testAudioIsHeardAWholeChunkAtATime() {
        var audio = NemotronStream.Chunker(size: 4)
        audio.append([1, 2, 3])
        XCTAssertNil(audio.next, "not yet a chunk")
        audio.append([4, 5])
        XCTAssertEqual(audio.next, [1, 2, 3, 4])
        XCTAssertEqual(audio.next, [1, 2, 3, 4], "held until it is heard")
        audio.drop()
        XCTAssertNil(audio.next)
        XCTAssertEqual(audio.pending, [5])
        audio.append([6, 7, 8, 9, 10, 11, 12])
        var heard: [[Float]] = []
        while let chunk = audio.next { heard.append(chunk); audio.drop() }
        XCTAssertEqual(heard, [[5, 6, 7, 8], [9, 10, 11, 12]])
        XCTAssertNil(audio.tail, "nothing left over")
        audio.append([13])
        XCTAssertEqual(audio.tail, [13, 0, 0, 0], "the end is padded with silence")
    }

    func testTheStreamsChunkIs560Milliseconds() throws {
        let metadata = Data("""
        {"sample_rate": 16000, "mel_features": 128, "chunk_mel_frames": 56, "pre_encode_cache": 9,
         "total_mel_frames": 65, "vocab_size": 1024, "blank_idx": 1024, "cache_channel_shape": [1, 24, 70, 1024],
         "cache_time_shape": [1, 24, 1024, 8], "decoder_hidden": 640, "decoder_layers": 2, "encoder_dim": 1024,
         "chunk_ms": 560}
        """.utf8)
        let config = try NemotronStream.Config(json: metadata)
        XCTAssertEqual(config.chunkSamples, 8960)
        XCTAssertEqual(config.chunkMs, 560)
        XCTAssertEqual(config.totalMelFrames, 65)
        XCTAssertEqual(NemotronStream.Config().chunkMelFrames, 112, "a missing key takes FluidAudio's default")
        XCTAssertThrowsError(try NemotronStream.Config(json: Data("[]".utf8)))
    }

    func testAStreamWithoutModelsSaysSo() async {
        let stream = NemotronStream(folder: URL(fileURLWithPath: "/nonexistent"))
        let loaded = await stream.isLoaded
        XCTAssertFalse(loaded)
        do {
            _ = try await stream.feed([0])
            XCTFail("fed without models")
        } catch {
            XCTAssertEqual("\(error)", "nemotron: not loaded")
        }
        do {
            try await stream.load()
            XCTFail("loaded from nothing")
        } catch {
            XCTAssertTrue("\(error)".hasPrefix("nemotron: no "), "\(error)")
        }
    }

    // MARK: - Words

    private func token(_ text: String, _ frame: Int) -> NemotronStream.Token {
        NemotronStream.Token(text, start: Double(frame) * 0.08, end: Double(frame + 1) * 0.08)
    }

    func testTheTextIsFluidAudiosDecode() {
        let tokens = [token("▁O", 7), token("p", 7), token("en", 8), token("▁the", 9), token("▁file", 10), token(".", 11)]
        XCTAssertEqual(NemotronStream.text(tokens), "Open the file.")
        XCTAssertEqual(NemotronStream.text([]), "")
    }

    func testPiecesMakeWordsWithPunctuationOnThem() {
        let tokens = [token("▁O", 7), token("p", 7), token("en", 8), token("▁the", 9), token("▁file", 10),
                      token(",", 11), token("▁then", 13), token("▁go", 14), token(".", 16)]
        let words = NemotronStream.words(tokens)
        XCTAssertEqual(words.map(\.text), ["Open", "the", "file,", "then", "go."])
        XCTAssertEqual(words[0].start!, 0.56, accuracy: 1e-9)
        XCTAssertEqual(words[0].end!, 0.72, accuracy: 1e-9, "the end of its last piece's frame")
        XCTAssertEqual(words[2].end!, 0.96, accuracy: 1e-9, "the comma's frame ends the word")
        XCTAssertEqual(words[4].end!, 1.36, accuracy: 1e-9)
        XCTAssertEqual(words.map(\.text).joined(separator: " "), NemotronStream.text(tokens),
                       "the words read back as the text")
        let heard = NemotronStream.heard(tokens)
        XCTAssertEqual(heard.text, "Open the file, then go.")
        XCTAssertEqual(heard.words, words)
    }

    func testABareBoundaryAndAMidWordStartStillReadBack() {
        let tokens = [token("ing", 1), token("▁", 2), token(".", 3), token("▁ok", 4)]
        let words = NemotronStream.words(tokens)
        XCTAssertEqual(words.map(\.text), ["ing", ".", "ok"])
        XCTAssertEqual(words.map(\.text).joined(separator: " "), NemotronStream.text(tokens))
        XCTAssertEqual(words[1].start!, 0.24, accuracy: 1e-9, "a word starts at its first letter")
        XCTAssertEqual(NemotronStream.words([]), [])
    }

    func testTheVocabularyIsAnObjectOfPieces() throws {
        let vocabulary = try NemotronVocabulary(json: Data(#"{"0": "<unk>", "5": "▁the"}"#.utf8))
        XCTAssertEqual(vocabulary[5], "▁the")
        XCTAssertNil(vocabulary[1])
        XCTAssertThrowsError(try NemotronVocabulary(json: Data(#"["▁a"]"#.utf8)))
        XCTAssertThrowsError(try NemotronVocabulary(json: Data("{}".utf8)))
    }
}

/// The stream on the real model: set NEMOTRON_FOLDER to the 560 ms
/// variant's folder (`nemotron_coreml_560ms`). A sentence is spoken by the
/// system's own voice into a temporary file, never a person's recording.
final class NemotronStreamLiveTests: XCTestCase {
    private func spoken(_ sentence: String) throws -> [Float] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nemotron-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let aiff = directory.appendingPathComponent("s.aiff"), wav = directory.appendingPathComponent("s.wav")
        for (tool, arguments) in [("/usr/bin/say", ["-o", aiff.path, sentence]),
                                  ("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEF32@16000", "-c", "1", aiff.path, wav.path])] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, tool)
        }
        let file = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    private func words(_ text: String) -> [String] {
        text.lowercased().split(separator: " ").map { $0.filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }
    }

    func testASpokenSentenceIsHeardAsItIsFed() async throws {
        guard let path = ProcessInfo.processInfo.environment["NEMOTRON_FOLDER"] else {
            throw XCTSkip("set NEMOTRON_FOLDER to the nemotron_coreml_560ms folder")
        }
        let sentence = "The quick brown fox jumps over the lazy dog, and then it runs back home."
        // Silence either side: say starts its first word at the file's first sample.
        let audio = try spoken("[[slnc 600]] \(sentence) [[slnc 600]]")
        let stream = NemotronStream(folder: URL(fileURLWithPath: path))
        try await stream.load()
        try await stream.warm()

        // 80 ms at a time, as the microphone gives it.
        var fed: [NemotronStream.Token] = []
        var calls = 0, withTokens = 0
        var i = 0
        while i < audio.count {
            let new = try await stream.feed(Array(audio[i..<min(audio.count, i + 1280)]))
            calls += 1
            if !new.isEmpty { withTokens += 1 }
            fed += new
            i += 1280
        }
        fed += try await stream.finish()
        XCTAssertEqual(words(NemotronStream.text(fed)), words(sentence))
        XCTAssertLessThan(withTokens, calls / 4, "tokens come only when a chunk is whole")

        // All at once: the same tokens, so no feed returned one twice.
        try await stream.reset()
        var whole = try await stream.feed(audio)
        whole += try await stream.finish()
        XCTAssertEqual(whole, fed)
        XCTAssertEqual(NemotronStream.heard(fed).words.count, words(sentence).count)
        let times = fed.map(\.start)
        XCTAssertEqual(times, times.sorted(), "times run forward")
        XCTAssertLessThanOrEqual(times.last ?? 0, Double(audio.count) / 16_000 + 0.56)

        await stream.unload()
        let loaded = await stream.isLoaded
        XCTAssertFalse(loaded)
    }
}
