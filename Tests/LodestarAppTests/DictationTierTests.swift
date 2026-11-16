import Foundation
import XCTest
@testable import lodestar
@testable import LodestarEars
import LodestarCore

/// Each dictation setup is the ears and the model for what was meant
/// together, sized by the Mac's memory alone: nobody picks one, and Write's
/// choice never decides it.
final class DictationTierTests: XCTestCase {
    func testAutomaticFollowsTheMemory() {
        let all: (EarTier) -> Bool = { _ in true }
        XCTAssertEqual(EarTier.resolved("", memoryGB: 8, hasModel: all), .small, "8 GB has room for Parakeet")
        XCTAssertEqual(EarTier.resolved("", memoryGB: 4, hasModel: all), .apple)
        XCTAssertEqual(EarTier.resolved("", memoryGB: 16, hasModel: all), .standard)
        XCTAssertEqual(EarTier.resolved("", memoryGB: 24, hasModel: all), .full)
        XCTAssertEqual(EarTier.resolved("", memoryGB: 48, hasModel: all), .full)
        XCTAssertEqual(EarTier.resolved("", memoryGB: 64, hasModel: all), .max)
        XCTAssertEqual(EarTier.resolved("max", memoryGB: 32, hasModel: all), .full, "a tier too big falls to the next")
        XCTAssertEqual(EarTier.resolved("standard", memoryGB: 8, hasModel: all), .small)
        XCTAssertEqual(EarTier.resolved("", memoryGB: 64, hasModel: { $0 != .max && $0 != .full }), .standard,
                       "meanwhile the best one here")
        XCTAssertEqual(EarTier.resolved("", memoryGB: 64, hasModel: { $0 == .small }), .small,
                       "Parakeet alone while the ear behind it is on its way")
    }

    func testEachTierNamesItsModels() {
        XCTAssertNil(EarTier.apple.cleanup)
        XCTAssertNil(EarTier.small.cleanup)
        XCTAssertEqual(EarTier.standard.cleanup, .gemma)
        XCTAssertEqual(EarTier.full.cleanup, .gemma)
        XCTAssertEqual(EarTier.max.cleanup, .qwen36)
        // Parakeet in front of every setup but Apple's, Qwen3-ASR behind the larger.
        XCTAssertEqual(EarTier.apple.engines, [])
        XCTAssertEqual(EarTier.small.engines, ["parakeet-v2"])
        XCTAssertEqual(EarTier.standard.engines, ["parakeet-v2", "qwen3-asr-0.6b"])
        XCTAssertEqual(EarTier.full.engines, ["parakeet-v2", "qwen3-asr-1.7b"])
        XCTAssertEqual(EarTier.max.engines, ["parakeet-v2", "qwen3-asr-1.7b"])
        // The same weights as the editor's, so one copy serves both.
        XCTAssertEqual(CleanupModel.gemma.manifest, EditorManifest.forEngine(.standard))
        XCTAssertEqual(CleanupModel.qwen36.manifest, EditorManifest.forEngine(.full))
    }

    func testFullAndMaxShareOneEarOnDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-ears-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ear = root.appendingPathComponent(EditorManifest(try XCTUnwrap(EarEngines.manifest("qwen3-asr-1.7b"))).folder)
        try FileManager.default.createDirectory(at: ear, withIntermediateDirectories: true)
        EarHost.removeAll(except: .max, root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ear.path), "Max hears with Full's ear")
    }

    func testTheEditorNeverRemovesWhatSpeakUses() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-models-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["gemma-4-e2b-it-4bit", "Qwen3.6-35B-A3B-4bit"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        EditorModels.removeAll(except: .spelling, alsoKeeping: [CleanupModel.gemma.manifest.folder], root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("gemma-4-e2b-it-4bit").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Qwen3.6-35B-A3B-4bit").path))
    }

    private struct Echo: EditorBackend {
        func respond(to sentence: String, instructions: String) async throws -> String { sentence }
        func rewrite(_ text: String, prompt: IntentPass.Prompt) async throws -> String { "meant: " + text }
    }

    func testTheDraftsOwnModelAnswersOnlyOnceLoaded() async {
        let model = DraftModel(model: .gemma, loader: { _ in Echo() }, clearCache: {})
        let prompt = IntentPass.prompt(names: [])
        let early = await model.rewrite("Um, hi.", prompt: prompt)
        XCTAssertNil(early, "never a load of its own")
        await model.load()
        let answer = await model.rewrite("Um, hi.", prompt: prompt)
        XCTAssertEqual(answer, "meant: Um, hi.")
        await model.release()
        let after = await model.rewrite("Um, hi.", prompt: prompt)
        XCTAssertNil(after)
    }
}
