import Foundation
import XCTest
@testable import lodestar
@testable import LodestarEars

/// One dictation model on disk at a time, as the editor keeps its own.
final class EarPruneTests: XCTestCase {
    func testOnlyTheKeptTiersDownloadStays() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-ears-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        func folder(_ tier: EarTier, partial: Bool = false) throws -> URL {
            let name = EditorManifest(try XCTUnwrap(tier.manifest)).folder
            return root.appendingPathComponent(partial ? ".\(name).partial" : name, isDirectory: true)
        }
        for url in [try folder(.standard), try folder(.standard, partial: true), try folder(.full)] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        let byHand = root.appendingPathComponent("my-own-model", isDirectory: true)
        try fm.createDirectory(at: byHand, withIntermediateDirectories: true)

        let removed = EarHost.removeAll(except: .full, root: root)

        XCTAssertEqual(removed, [.standard])
        XCTAssertFalse(fm.fileExists(atPath: try folder(.standard).path))
        XCTAssertFalse(fm.fileExists(atPath: try folder(.standard, partial: true).path))
        XCTAssertTrue(fm.fileExists(atPath: try folder(.full).path))
        XCTAssertTrue(fm.fileExists(atPath: byHand.path), "a model put there by hand stays")
    }
}
