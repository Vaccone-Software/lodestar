import Foundation
import XCTest
@testable import lodestar
@testable import LodestarEars
import LodestarCore

/// Each dictation tier is one setup, the ear and the model for what was
/// meant together, chosen in Speak alone; the Mac's memory decides what
/// Automatic picks, and Write's choice never does.
final class DictationTierTests: XCTestCase {
    func testAutomaticFollowsTheMemory() {
        let all: (EarTier) -> Bool = { _ in true }
        XCTAssertEqual(EarTier.resolved("", memoryGB: 8, hasModel: all), .apple, "8 GB dictates with Apple's recognizer")
        XCTAssertEqual(EarTier.resolved("", memoryGB: 16, hasModel: all), .standard)
        XCTAssertEqual(EarTier.resolved("", memoryGB: 24, hasModel: all), .full)
        XCTAssertEqual(EarTier.resolved("", memoryGB: 48, hasModel: all), .full)
        XCTAssertEqual(EarTier.resolved("", memoryGB: 64, hasModel: all), .max)
        XCTAssertEqual(EarTier.resolved("max", memoryGB: 32, hasModel: all), .full, "a tier too big falls to the next")
        XCTAssertEqual(EarTier.resolved("standard", memoryGB: 8, hasModel: all), .apple)
        XCTAssertEqual(EarTier.resolved("", memoryGB: 64, hasModel: { $0 != .max && $0 != .full }), .standard,
                       "meanwhile the best one here")
    }

    func testEachTierNamesItsModels() {
        XCTAssertNil(EarTier.apple.cleanup)
        XCTAssertEqual(EarTier.standard.cleanup, .gemma)
        XCTAssertEqual(EarTier.full.cleanup, .gemma)
        XCTAssertEqual(EarTier.max.cleanup, .qwen36)
        XCTAssertEqual(EarTier.standard.label(memoryGB: 32), "Standard · Parakeet and Gemma 4 E2B")
        XCTAssertEqual(EarTier.full.label(memoryGB: 32), "Full · Qwen3-ASR and Gemma 4 E2B")
        XCTAssertEqual(EarTier.max.label(memoryGB: 32), "Max · needs 64 GB")
        XCTAssertEqual(EarTier.apple.label(memoryGB: 8), "Apple only")
        // The same weights as the editor's, so one copy serves both.
        XCTAssertEqual(CleanupModel.gemma.manifest, EditorManifest.forEngine(.standard))
        XCTAssertEqual(CleanupModel.qwen36.manifest, EditorManifest.forEngine(.full))
    }

    func testFullAndMaxShareOneEarOnDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-ears-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ear = root.appendingPathComponent(EditorManifest(try XCTUnwrap(EarTier.full.manifest)).folder)
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
