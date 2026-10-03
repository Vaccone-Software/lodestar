import Metal
import MLX
import MLXNN
import XCTest
@testable import LodestarEars

/// The Qwen3-ASR ear's parts that need no weights: the front end's shape
/// and numbers, the encoder's chunking, the prompt, and the token cap.
/// The model itself is measured by `probe dictation ear`.
final class QwenEarTests: XCTestCase {
    private func requireGPU() throws {
        // MLX runs on the GPU, and a hosted runner's virtual machine has
        // none: the first evaluation would take the whole shard down.
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil || ProcessInfo.processInfo.environment["CI"] != nil,
                      "needs a GPU, which a hosted runner does not have")
    }

    // MARK: - Front end

    func testFramesAndAudioTokensMatchTheProcessor() {
        // Measured from transformers' WhisperFeatureExtractor and mlx-audio.
        XCTAssertEqual(QwenMel.frames(samples: 16_000), 100)
        XCTAssertEqual(QwenMel.frames(samples: 16_159), 100)
        XCTAssertEqual(QwenMel.frames(samples: 16_160), 101)
        XCTAssertEqual(QwenMel.frames(samples: 293_429), 1833)
        let tokens: [Int: Int] = [100: 13, 101: 14, 146: 19, 137: 18, 50: 7, 1833: 239, 200: 26, 1: 1]
        for (frames, expected) in tokens {
            XCTAssertEqual(qwenAudioTokens(frames: frames), expected, "\(frames) frames")
        }
    }

    func testFloorDivisionRoundsDownLikePython() {
        XCTAssertEqual(floorDiv(-1, 2), -1)
        XCTAssertEqual(floorDiv(-2, 2), -1)
        XCTAssertEqual(floorDiv(3, 2), 1)
        XCTAssertEqual(floorDiv(0, 2), 0)
    }

    func testMelFiltersAreWhispersSlaneyTriangles() {
        // transformers' mel_filter_bank(201, 128, 0, 8000, 16000, "slaney", "slaney").
        let f = QwenMel.filterValues
        XCTAssertEqual(f.count, 201 * 128)
        func at(_ bin: Int, _ mel: Int) -> Float { f[bin * 128 + mel] }
        XCTAssertEqual(at(1, 0), 0.012373986, accuracy: 1e-7)
        XCTAssertEqual(at(6, 10), 0.011289184, accuracy: 1e-7)
        XCTAssertEqual(at(43, 64), 0.018091517, accuracy: 1e-7)
        XCTAssertEqual(at(195, 127), 0.005041602, accuracy: 1e-7)
        XCTAssertEqual(f.reduce(0, +), 3.1909855, accuracy: 1e-4)
        XCTAssertEqual(QwenMel.hann[0], 0)
        XCTAssertEqual(QwenMel.hann[200], 1, accuracy: 1e-6)   // periodic: the peak is at N/2
    }

    func testFeaturesHaveTheProcessorsShapeAndScale() throws {
        try requireGPU()
        // Silence: every bin floors at log10(1e-10), so (−10 + 4) / 4.
        let silence = QwenMel.features([Float](repeating: 0, count: 16_000))
        XCTAssertEqual(silence.shape, [128, 100])
        XCTAssertEqual(silence.min().item(Float.self), -1.5, accuracy: 1e-5)
        XCTAssertEqual(silence.max().item(Float.self), -1.5, accuracy: 1e-5)
        // A 1 kHz tone peaks in mel bin 42 at 1.125, and the floor sits 8 below (2 scaled).
        let tone = (0 ..< 16_000).map { Float(0.1 * sin(2 * Double.pi * 1000 * Double($0) / 16_000)) }
        let features = QwenMel.features(tone)
        XCTAssertEqual(features.shape, [128, 100])
        XCTAssertEqual(features[0..., 50].argMax().item(Int.self), 42)
        XCTAssertEqual(features.max().item(Float.self), 1.125, accuracy: 2e-3)
        XCTAssertEqual(features.min().item(Float.self), -0.875, accuracy: 2e-3)
    }

    func testEncoderEmitsOneVectorPerAudioTokenAcrossWindows() throws {
        try requireGPU()
        // A tiny tower with random weights: 1000 frames are ten chunks,
        // 130 tokens, two attention windows (104 + 26).
        var config = QwenAudioConfig(width: 8, layers: 1, heads: 2, ffn: 16, outputWidth: 6)
        config.downsampleWidth = 4
        let encoder = QwenAudioEncoder(config)
        for frames in [1000, 100, 57] {
            let out = encoder(MLXRandom.normal([128, frames]))
            XCTAssertEqual(out.shape, [qwenAudioTokens(frames: frames), 6], "\(frames) frames")
        }
    }

    // MARK: - Prompt

    func testSystemTurnFramesTheTerms() {
        XCTAssertNil(QwenPrompt.system([]))
        XCTAssertNil(QwenPrompt.system(["  ", ""]))
        XCTAssertEqual(QwenPrompt.system(["Lodestar", " Proton Pass "]),
                       "Dictation by a software developer. Names and terms that may come up: "
                           + "Lodestar, Proton Pass. Transcribe only what is said.")
    }

    func testPromptPutsSpecialTokensAroundTheTextAndTheAudio() {
        var asked: [String] = []
        // Each text piece becomes one fake id, so the layout is visible.
        let ids = QwenPrompt.ids(audioTokens: 3, system: "Names") { text in
            asked.append(text)
            return [-asked.count]
        }
        XCTAssertEqual(asked, ["system\nNames\n", "\n", "user\n", "\n", "assistant\nlanguage English"])
        XCTAssertEqual(ids, [151_644, -1, 151_645, -2, 151_644, -3, 151_669,
                             151_676, 151_676, 151_676,
                             151_670, 151_645, -4, 151_644, -5, 151_704])
        asked = []
        _ = QwenPrompt.ids(audioTokens: 1, system: nil) { asked.append($0); return [] }
        XCTAssertEqual(asked.first, "system\n", "no terms: an empty system turn")
    }

    /// With a model folder named in QWEN_ASR_FOLDER (skipped otherwise):
    /// the tokenizer built from vocab.json and merges.txt writes the ids
    /// transformers wrote for the probe's framed 29-term prompt.
    func testTokenizerFromTheFolderMatchesTransformers() throws {
        guard let path = ProcessInfo.processInfo.environment["QWEN_ASR_FOLDER"] else {
            throw XCTSkip("set QWEN_ASR_FOLDER to a Qwen3-ASR model folder")
        }
        let tokenizer = try QwenTokenizer.load(URL(fileURLWithPath: path))
        try QwenPrompt.check(tokenizer)
        let terms = ["Lodestar", "Ghostty", "Xonar", "Kindora", "Vaccone", "Supabase", "Asana", "MongoDB", "Compass",
                     "UAT", "Proton Pass", "Claude Code", "SwiftUI", "MLX", "Brex", "Kagi", "Raycast", "AeroSpace",
                     "ZMK", "Kinesis", "Convex", "Expo", "Telegram", "DraftController.swift", "settleGhostAsSeen",
                     "markGhostSeen", "ModelStore.swift", "local/dev", "lodestar.log"]
        let ids = QwenPrompt.ids(audioTokens: 239, system: QwenPrompt.system(terms)) {
            tokenizer.encode(text: $0, addSpecialTokens: false)
        }
        // transformers' Qwen2TokenizerFast on the same prompt (n01, 18.3 s).
        let head = [151644, 8948, 198, 13448, 367, 553, 264, 3162, 15754, 13, 34875, 323, 3793, 429, 1231, 2525, 705,
                    25, 87940, 89327, 11, 25044, 1881, 11, 1599, 263, 277, 11, 16840, 6215, 11, 30526, 58082, 11, 6299,
                    370, 519, 11, 1634, 3362, 11, 45328, 11, 59580, 11, 547, 828, 11, 1298, 777, 9970, 11, 74330, 6119,
                    11, 74881, 11, 19614, 55, 11, 11427, 87, 11, 730, 36035, 11, 13255, 3829, 11, 88423, 9914, 11,
                    1863, 44140, 11, 730, 82789, 11, 28988, 327, 11, 51323, 11, 42963, 11, 28564, 2051, 13290, 11,
                    24729, 64686, 2121, 85675, 11, 1868, 64686, 85675, 11, 4903, 6093, 13290, 11, 2205, 35061, 11,
                    35032, 89327, 1665, 13, 4058, 3114, 1172, 1128, 374, 1053, 624, 151645, 198, 151644, 872, 198,
                    151669]
        let tail = [151670, 151645, 198, 151644, 77091, 198, 11528, 6364, 151704]
        XCTAssertEqual(ids.count, 370)
        XCTAssertEqual(Array(ids.prefix(head.count)), head)
        XCTAssertEqual(Array(ids.suffix(tail.count)), tail)
        XCTAssertEqual(tokenizer.decode(tokens: Array(head[3 ..< 10]), skipSpecialTokens: true),
                       "Dictation by a software developer.")
    }

    func testTokenCapGrowsWithTheAudioAndLeavesRoomForFastSpeech() {
        XCTAssertEqual(QwenPrompt.tokenCap(seconds: 0), 32)
        XCTAssertEqual(QwenPrompt.tokenCap(seconds: 10), 152)
        XCTAssertEqual(QwenPrompt.tokenCap(seconds: -1), 32)
        // The densest phrase in the maker's recordings: 38 tokens in 10.7 s.
        XCTAssertGreaterThan(QwenPrompt.tokenCap(seconds: 10.7), 38 * 3)
        // A 30 s phrase cannot run away for long.
        XCTAssertLessThan(QwenPrompt.tokenCap(seconds: 30), 400)
    }

    // MARK: - Files and names

    func testFactoryMakesBothSizes() {
        let folder = URL(fileURLWithPath: "/nonexistent")
        for name in ["qwen3-asr-1.7b", "qwen3-asr-0.6b"] {
            let ear = EarFactory.make(name, folder: folder)
            XCTAssertEqual(ear?.name, name)
            XCTAssertEqual(ear?.isLoaded, false)
        }
        XCTAssertNil(EarFactory.make("qwen3-asr-9b", folder: folder))
    }

    func testLoadingAnEmptyFolderThrowsInsteadOfCrashing() async {
        let ear = QwenEar(name: "qwen3-asr-0.6b", folder: FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-ear-\(UUID().uuidString)"))
        do {
            try await ear.load()
            XCTFail("loaded from nothing")
        } catch {
            XCTAssertFalse(ear.isLoaded)
        }
        do {
            _ = try await ear.transcribe([0], context: [])
            XCTFail("heard without a model")
        } catch {}
    }
}
