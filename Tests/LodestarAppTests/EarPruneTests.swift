import Foundation
import XCTest
@testable import lodestar
@testable import LodestarEars

/// Only the ears the Mac's setup runs stay on disk, as the editor keeps its
/// own model.
final class EarPruneTests: XCTestCase {
    func testOnlyTheKeptSetupsEarsStay() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-ears-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        func folder(_ engine: String, partial: Bool = false) throws -> URL {
            let name = EditorManifest(try XCTUnwrap(EarEngines.manifest(engine))).folder
            return root.appendingPathComponent(partial ? ".\(name).partial" : name, isDirectory: true)
        }
        let (parakeet, small, large) = ("parakeet-v2", "qwen3-asr-0.6b", "qwen3-asr-1.7b")
        for url in [try folder(parakeet), try folder(small), try folder(small, partial: true), try folder(large)] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let byHand = root.appendingPathComponent("my-own-model", isDirectory: true)
        try fm.createDirectory(at: byHand, withIntermediateDirectories: true)

        let removed = EarHost.removeAll(except: .full, root: root)

        XCTAssertEqual(removed, [small])
        XCTAssertFalse(fm.fileExists(atPath: try folder(small).path))
        XCTAssertFalse(fm.fileExists(atPath: try folder(small, partial: true).path))
        XCTAssertTrue(fm.fileExists(atPath: try folder(large).path), "the ear behind stays")
        XCTAssertTrue(fm.fileExists(atPath: try folder(parakeet).path), "the quick ear stays")
        XCTAssertTrue(fm.fileExists(atPath: byHand.path), "a model put there by hand stays")
    }
}
