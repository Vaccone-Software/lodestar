import XCTest
import LodestarCore
@testable import LodestarEars

/// The Parakeet ear's arithmetic, without the weights: the vocabulary, the
/// text, the words and their times, the windows a long hold is cut into,
/// and how two windows are joined.
final class ParakeetEarTests: XCTestCase {
    /// A small vocabulary in Parakeet's shape: word-initial pieces carry ▁.
    private let vocabulary = ParakeetVocabulary([
        0: "▁the", 1: "▁cat", 2: "▁sat", 3: "▁on", 4: "▁mat", 5: ".", 6: "▁The",
        7: "▁ana", 8: "lyz", 9: "ing", 10: "▁dog", 11: "▁have", 12: "▁Have",
    ])

    private func text(_ tokens: [ParakeetToken]) -> String { vocabulary.text(tokens.map(\.id)) }

    // MARK: - Vocabulary and text

    func testVocabularyReadsAnObjectOrAnArray() throws {
        let object = try ParakeetVocabulary(json: Data(#"{"0": "▁hi", "2": "."}"#.utf8))
        XCTAssertEqual(object[0], "▁hi")
        XCTAssertEqual(object[2], ".")
        XCTAssertNil(object[1])
        let array = try ParakeetVocabulary(json: Data(#"["▁a", "b"]"#.utf8))
        XCTAssertEqual(array[1], "b")
        XCTAssertThrowsError(try ParakeetVocabulary(json: Data(#"{"a": 1}"#.utf8)))
        XCTAssertThrowsError(try ParakeetVocabulary(json: Data("[]".utf8)))
    }

    func testTextJoinsPiecesAtTheBoundaryMark() {
        XCTAssertEqual(vocabulary.text([0, 1, 7, 8, 9, 5]), "the cat analyzing.")
        XCTAssertEqual(vocabulary.text([]), "")
        XCTAssertEqual(vocabulary.text([99, 1]), "cat", "an unknown id is skipped")
    }

    // MARK: - Words and times

    func testATokenStartsAFrameEarlyAndEndsByItsDurationOrTheNext() {
        let tokens = [ParakeetToken(0, frame: 1, confidence: 0.9, duration: 2),
                      ParakeetToken(1, frame: 3, confidence: 0.5, duration: 0),
                      ParakeetToken(5, frame: 4, confidence: 1, duration: 0)]
        let times = ParakeetTiming.times(tokens)
        XCTAssertEqual(times[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(times[0].end, 0.16, accuracy: 1e-9, "two frames long")
        XCTAssertEqual(times[1].start, 0.16, accuracy: 1e-9)
        XCTAssertEqual(times[1].end, 0.24, accuracy: 1e-9, "no duration: it lasts until the next")
        XCTAssertEqual(times[2].end, 0.32, accuracy: 1e-9, "the last lasts one frame")
        XCTAssertEqual(ParakeetTiming.times([ParakeetToken(0, frame: 0)])[0].start, 0, "never before the start")
    }

    func testPiecesMergeIntoWordsWithTheirMeanConfidence() {
        let tokens = [ParakeetToken(0, frame: 1, confidence: 0.9, duration: 2),
                      ParakeetToken(7, frame: 3, confidence: 0.6, duration: 1),
                      ParakeetToken(8, frame: 4, confidence: 0.8, duration: 1),
                      ParakeetToken(9, frame: 5, confidence: 1.0, duration: 1),
                      ParakeetToken(5, frame: 6, confidence: 1.0, duration: 0)]
        let heard = ParakeetTiming.heard(tokens, vocabulary: vocabulary)
        XCTAssertEqual(heard.text, "the analyzing.")
        XCTAssertEqual(heard.words.map(\.text), ["the", "analyzing."], "punctuation stays on its word")
        XCTAssertEqual(heard.words[1].start!, 0.16, accuracy: 1e-9)
        XCTAssertEqual(heard.words[1].end!, 0.48, accuracy: 1e-9)
        XCTAssertEqual(heard.words[1].confidence!, 0.85, accuracy: 1e-6)
        XCTAssertEqual(heard.words.map(\.text).joined(separator: " "), heard.text,
                       "the words read back as the text, as the draft's matcher needs")
    }

    func testATranscriptThatOpensMidWordStillMakesAWord() {
        let heard = ParakeetTiming.heard([ParakeetToken(8, frame: 2), ParakeetToken(9, frame: 3)],
                                         vocabulary: vocabulary)
        XCTAssertEqual(heard.words.map(\.text), ["lyzing"])
        XCTAssertEqual(ParakeetTiming.heard([], vocabulary: vocabulary), Heard(""))
    }

    // MARK: - Windows

    func testTheWindowLayoutIsFluidAudiosV2Layout() {
        XCTAssertEqual(ParakeetSeams.chunkSamples, 238_080)
        XCTAssertEqual(ParakeetSeams.overlapSamples, 32_000)
        XCTAssertEqual(ParakeetSeams.strideSamples, 206_080)
        XCTAssertEqual(ParakeetSeams.repairWindowSamples, 239_360)
    }

    func testThirtySecondsIsThreeOverlappingWindows() {
        let windows = ParakeetSeams.windows(total: 480_000)
        XCTAssertEqual(windows, [
            .init(contextStart: 0, start: 0, end: 238_080, isLast: false),
            .init(contextStart: 204_800, start: 206_080, end: 444_160, isLast: false),
            .init(contextStart: 410_880, start: 412_160, end: 480_000, isLast: true),
        ])
        XCTAssertEqual(windows[1].context, 1280, "every window after the first sees one frame before it")
        let justOver = ParakeetSeams.windows(total: 240_001)
        XCTAssertEqual(justOver.count, 2)
        XCTAssertEqual(justOver.last?.end, 240_001)
        for window in windows + justOver {
            XCTAssertLessThanOrEqual(window.end - window.contextStart, ParakeetSeams.windowSamples)
        }
    }

    // MARK: - Joining two windows

    func testTheOverlapIsHeardOnce() {
        let left = [0, 1, 2, 3, 0, 4].enumerated().map { ParakeetToken($1, frame: 100 + 2 * $0) }
        let right = [2, 3, 0, 4, 10].enumerated().map { ParakeetToken($1, frame: 104 + 2 * $0) }
        let merged = ParakeetSeams.merge(left, right, spliceSafe: ParakeetSeams.spliceSafeIds(vocabulary),
                                         caseVariants: ParakeetSeams.caseVariants(vocabulary))
        XCTAssertEqual(text(merged), "the cat sat on the mat dog")
    }

    func testWindowsThatDoNotTouchAreJoinedWhole() {
        let left = [ParakeetToken(0, frame: 1), ParakeetToken(1, frame: 3)]
        let right = [ParakeetToken(2, frame: 40)]
        XCTAssertEqual(ParakeetSeams.merge(left, right, spliceSafe: [], caseVariants: [:]), left + right)
        XCTAssertEqual(ParakeetSeams.merge([], right, spliceSafe: [], caseVariants: [:]), right)
        XCTAssertEqual(ParakeetSeams.merge(left, [], spliceSafe: [], caseVariants: [:]), left)
    }

    func testAWordCutByTheLeftWindowsEdgeIsTakenWholeFromTheRight() {
        // The left window heard "ana" at its edge; the right heard "analyzing".
        let left = [ParakeetToken(0, frame: 100), ParakeetToken(1, frame: 102), ParakeetToken(2, frame: 104),
                    ParakeetToken(7, frame: 106)]
        let right = [ParakeetToken(1, frame: 102), ParakeetToken(2, frame: 104), ParakeetToken(7, frame: 106),
                     ParakeetToken(8, frame: 107), ParakeetToken(9, frame: 108), ParakeetToken(10, frame: 110)]
        let merged = ParakeetSeams.merge(left, right, spliceSafe: ParakeetSeams.spliceSafeIds(vocabulary),
                                         caseVariants: ParakeetSeams.caseVariants(vocabulary))
        XCTAssertEqual(text(merged), "the cat sat analyzing dog")
    }

    func testCaseTwinsAnchorTheJoin() {
        XCTAssertEqual(ParakeetSeams.caseVariants(vocabulary)[6], 0, "▁The joins ▁the")
        XCTAssertEqual(ParakeetSeams.caseVariants(vocabulary)[12], 11)
        XCTAssertNil(ParakeetSeams.caseVariants(vocabulary)[1])
        // One window began a sentence where the other did not.
        let left = [1, 2, 3, 0, 4].enumerated().map { ParakeetToken($1, frame: 100 + 2 * $0) }
        let right = [2, 3, 6, 4, 10].enumerated().map { ParakeetToken($1, frame: 102 + 2 * $0) }
        let merged = ParakeetSeams.merge(left, right, spliceSafe: ParakeetSeams.spliceSafeIds(vocabulary),
                                         caseVariants: ParakeetSeams.caseVariants(vocabulary))
        XCTAssertEqual(text(merged), "cat sat on the mat dog")
    }

    func testFramesAreClampedForwardWithoutReordering() {
        let tokens = [ParakeetToken(0, frame: 10), ParakeetToken(1, frame: 9), ParakeetToken(2, frame: 12)]
        XCTAssertEqual(ParakeetSeams.monotonic(tokens).map(\.frame), [10, 10, 12])
        XCTAssertEqual(ParakeetSeams.monotonic(tokens).map(\.id), [0, 1, 2])
    }

    func testACaseOnlyDuplicateAtASeamGoes() {
        let doubled = [ParakeetToken(11, frame: 10), ParakeetToken(12, frame: 12), ParakeetToken(10, frame: 14)]
        XCTAssertEqual(text(ParakeetSeams.collapseCaseDuplicates(doubled, vocabulary: vocabulary)), "have dog")
        // After a sentence end the capital is real.
        let sentence = [ParakeetToken(11, frame: 10), ParakeetToken(5, frame: 11), ParakeetToken(12, frame: 12)]
        XCTAssertEqual(text(ParakeetSeams.collapseCaseDuplicates(sentence, vocabulary: vocabulary)), "have. Have")
        // Seconds apart it is said twice.
        let apart = [ParakeetToken(11, frame: 10), ParakeetToken(12, frame: 80)]
        XCTAssertEqual(text(ParakeetSeams.collapseCaseDuplicates(apart, vocabulary: vocabulary)), "have Have")
    }

    // MARK: - Gaps

    func testAGapWithSpeechInItIsProbedAndASilentOneIsNot() {
        let frame = ParakeetTiming.samplesPerFrame
        var samples = [Float](repeating: 0, count: 60 * frame)
        // Speech-like sound from frame 2 to frame 38.
        for i in (2 * frame)..<(38 * frame) { samples[i] = 0.1 * sin(Float(i) * 0.05) }
        let tokens = [ParakeetToken(0, frame: 0, duration: 1), ParakeetToken(1, frame: 40)]
        let threshold = ParakeetSeams.speechThreshold(samples)
        let gaps = ParakeetSeams.gaps(in: tokens, samples: samples, threshold: threshold, probed: [])
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.startFrame, 1)
        XCTAssertEqual(gaps.first?.endFrame, 40)
        XCTAssertEqual(gaps.first?.placements, [0, 0], "a short recording is probed from its start")
        XCTAssertTrue(ParakeetSeams.gaps(in: tokens, samples: samples, threshold: threshold, probed: [1]).isEmpty)
        let silence = [Float](repeating: 0, count: 60 * frame)
        XCTAssertTrue(ParakeetSeams.gaps(in: tokens, samples: silence, threshold: 0.0005, probed: []).isEmpty)
        XCTAssertEqual(ParakeetSeams.speechThreshold(silence), ParakeetSeams.speechRmsCeiling)
    }

    func testAProbeKeepsOnlyWhatIsInsideTheGap() {
        let heard = [ParakeetToken(1, frame: 5), ParakeetToken(2, frame: 10), ParakeetToken(3, frame: 12),
                     ParakeetToken(4, frame: 20), ParakeetToken(10, frame: 30)]
        let candidate = ParakeetSeams.spliceCandidate(
            heard, gapStart: 4, gapEnd: 25, lead: ParakeetToken(1, frame: 5), tail: ParakeetToken(4, frame: 21),
            spliceSafe: ParakeetSeams.spliceSafeIds(vocabulary), vocabulary: vocabulary)
        XCTAssertEqual(text(candidate), "sat on", "the re-heard neighbours and the audio past the gap go")
        let midWord = ParakeetSeams.spliceCandidate(
            [ParakeetToken(8, frame: 6), ParakeetToken(10, frame: 8)], gapStart: 4, gapEnd: 25,
            lead: ParakeetToken(1, frame: 0), tail: ParakeetToken(4, frame: 40),
            spliceSafe: ParakeetSeams.spliceSafeIds(vocabulary), vocabulary: vocabulary)
        XCTAssertEqual(text(midWord), "dog", "a splice starts on a word")
    }

    // MARK: - The ear and its files

    func testTheFactoryNamesBothParakeets() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let v2 = try XCTUnwrap(EarFactory.make("parakeet-v2", folder: folder) as? ParakeetEar)
        XCTAssertEqual(v2.name, "parakeet-v2")
        XCTAssertEqual(v2.variant.blank, 1024)
        XCTAssertEqual((EarFactory.make("parakeet-v3", folder: folder) as? ParakeetEar)?.variant.blank, 8192)
        XCTAssertNil(EarFactory.make("parakeet-v9", folder: folder))
        XCTAssertFalse(v2.isLoaded)
        do {
            _ = try await v2.transcribe([0, 0, 0], context: [])
            XCTFail("an unloaded ear hears nothing")
        } catch ParakeetEar.Failure.notLoaded {}
        do {
            try await v2.load()
            XCTFail("an empty folder is no model")
        } catch ParakeetEar.Failure.missing {}
    }

    func testTheManifestsPinEveryFileTheEarLoads() {
        for variant in [ParakeetEar.Variant.v2, .v3] {
            let manifest = variant.manifest
            XCTAssertEqual(manifest.revision.count, 40)
            XCTAssertEqual(Set(manifest.files.map(\.path)).count, manifest.files.count)
            for file in manifest.files {
                XCTAssertEqual(file.sha256.count, 64, file.path)
                XCTAssertTrue(file.sha256.allSatisfy(\.isHexDigit), file.path)
                XCTAssertGreaterThan(file.size, 0)
            }
            let paths = Set(manifest.files.map(\.path))
            XCTAssertTrue(paths.contains("parakeet_vocab.json"))
            for model in ["Preprocessor", "Encoder", "Decoder", variant.joint] {
                XCTAssertTrue(paths.contains("\(model).mlmodelc/weights/weight.bin"), model)
                XCTAssertTrue(paths.contains("\(model).mlmodelc/coremldata.bin"), model)
            }
            XCTAssertTrue(manifest.license.hasPrefix("CC-BY-4.0"))
        }
        XCTAssertEqual(ParakeetEar.manifestV2.total, 464_413_247)
        XCTAssertEqual(ParakeetEar.manifestV2.folder, "parakeet-tdt-0.6b-v2-coreml")
        XCTAssertEqual(ParakeetEar.manifestV2.url(for: ParakeetEar.manifestV2.files.last!).absoluteString,
                       "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml/resolve/"
                           + "ee09c569f73759e6d44c9bd16766f477b2b36d39/parakeet_vocab.json")
    }
}
