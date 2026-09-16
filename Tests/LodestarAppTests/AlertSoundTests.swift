import XCTest
@testable import lodestar

/// The alert strike lives where Sound settings looks, kept current by
/// the app and taken away with it; naming it as the alert stays the
/// person's choice.
final class AlertSoundTests: XCTestCase {
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-sounds-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func source(_ bytes: String) throws -> URL {
        let folder = scratch.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Lodestar.aiff")
        try bytes.data(using: .utf8)!.write(to: url)
        return url
    }

    func testMissingIsPlacedCurrentIsLeftAndChangedIsReplaced() throws {
        let sounds = scratch.appendingPathComponent("Sounds", isDirectory: true)
        let first = try source("strike v1")
        XCTAssertEqual(AlertSound.install(from: first, into: sounds), "installed",
                       "the Sounds folder is created on the way")
        XCTAssertEqual(AlertSound.install(from: first, into: sounds), "current")
        let second = try source("strike v2")
        XCTAssertEqual(AlertSound.install(from: second, into: sounds), "replaced")
        let installed = sounds.appendingPathComponent("Lodestar.aiff")
        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "strike v2")
    }

    func testTheBundledStrikeIsTheOneInstalled() {
        XCTAssertEqual(AlertSound.bundled?.lastPathComponent, "Lodestar.aiff")
        XCTAssertEqual(AlertSound.installed.lastPathComponent, "Lodestar.aiff")
        XCTAssertTrue(AlertSound.installed.path.hasSuffix("/Library/Sounds/Lodestar.aiff"))
    }

    func testSelectionIsReadByPathAndNothingElse() {
        let file = URL(fileURLWithPath: "/Users/someone/Library/Sounds/Lodestar.aiff")
        XCTAssertTrue(AlertSound.isSelected(file, selection: "/Users/someone/Library/Sounds/Lodestar.aiff"))
        XCTAssertFalse(AlertSound.isSelected(file, selection: "/System/Library/Sounds/Boop.aiff"))
        XCTAssertFalse(AlertSound.isSelected(file, selection: nil), "the Mac's default names no path")
    }
}
