import XCTest
@testable import lodestar
@testable import LodestarCore

/// The PNGs an image going into a terminal is handed as are full-size copies
/// of what was copied: they live in a private folder, each file the owner's
/// alone, at most eight of them, and the folder is emptied at launch and at
/// quit.
final class HandoverFolderTests: XCTestCase {
    private var parent: URL!
    private var folder: HandoverFolder!

    override func setUp() {
        parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-handover-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        folder = HandoverFolder(parent: parent)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: parent)
    }

    private func mode(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int) ?? -1
    }

    private func names(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    private func controller() -> ClipboardController {
        let controller = ClipboardController(
            store: ClipboardStore(root: parent.appendingPathComponent("clipboard")))
        controller.handover = folder
        return controller
    }

    private func image(_ id: String) -> (Clipboard.Clip, [(type: String, data: Data)]) {
        let png = Stage.pngData(width: 12, height: 8)
        let clip = Clipboard.Clip(id: id, kind: .image, created: Date(), sourceBundleID: nil,
                                  sourceAppName: nil, preview: "image 12×8", bytes: png.count)
        return (clip, [(NSPasteboard.PasteboardType.png.rawValue, png)])
    }

    func testTheFolderIsMadePrivateAndLoosenessIsTightened() throws {
        let made = try XCTUnwrap(folder.prepared())
        XCTAssertEqual(made.deletingLastPathComponent().standardizedFileURL, parent.standardizedFileURL)
        XCTAssertEqual(mode(made), 0o700)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: made.path)
        XCTAssertEqual(folder.prepared(), made)
        XCTAssertEqual(mode(made), 0o700, "a loose folder is tightened")
    }

    func testSomethingElseWhereTheFolderShouldBeIsNotUsed() throws {
        let elsewhere = parent.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.url, withDestinationURL: elsewhere)
        XCTAssertNil(folder.prepared(), "a link in its place: nothing is written through it")
        try Data("keep".utf8).write(to: elsewhere.appendingPathComponent("precious"))
        folder.sweep()
        XCTAssertEqual(names(elsewhere), ["precious"], "and nothing is swept through it")
        try FileManager.default.removeItem(at: folder.url)
        try Data("a file".utf8).write(to: folder.url)
        XCTAssertNil(folder.prepared(), "a file in its place")
    }

    func testAnImageForATerminalIsAPrivateFileInThePrivateFolder() throws {
        let controller = controller()
        let (clip, natives) = image("abc")
        let file = try XCTUnwrap(controller.imageFileForPasting(clip, natives: natives))
        XCTAssertEqual(file.deletingLastPathComponent().lastPathComponent, "lodestar-handover")
        XCTAssertEqual(file.lastPathComponent, "lodestar-abc.png")
        XCTAssertEqual(mode(file), 0o600)
        XCTAssertEqual(mode(file.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try Data(contentsOf: file), natives[0].data)
        // The same clip again is the same file, written once.
        let before = (try FileManager.default.attributesOfItem(atPath: file.path))[.modificationDate] as? Date
        XCTAssertEqual(controller.imageFileForPasting(clip, natives: natives), file)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path))[.modificationDate] as? Date, before)
    }

    func testAtMostEightFilesAreKept() throws {
        let controller = controller()
        var written: [URL] = []
        for n in 0..<11 {
            let (clip, natives) = image("clip\(n)")
            written.append(try XCTUnwrap(controller.imageFileForPasting(clip, natives: natives)))
        }
        XCTAssertEqual(names(folder.url), written.suffix(8).map(\.lastPathComponent).sorted(), "the newest eight")
    }

    func testOurOwnHandoverFileIsStillRecognisedWhenItComesBackAroundTheBoard() throws {
        let controller = controller()
        let (clip, natives) = image("abc")
        let file = try XCTUnwrap(controller.imageFileForPasting(clip, natives: natives))
        XCTAssertTrue(Clipboard.isOwnHandoverPath(file.path, temporaryDirectory: parent.path))
    }

    func testSweepingEmptiesTheFolderAndTheLooseFilesEarlierBuildsLeft() throws {
        let controller = controller()
        for n in 0..<3 {
            let (clip, natives) = image("clip\(n)")
            _ = controller.imageFileForPasting(clip, natives: natives)
        }
        // What an earlier build wrote straight into the temporary directory,
        // beside things that are not ours.
        try Data("old".utf8).write(to: parent.appendingPathComponent("lodestar-old.png"))
        try Data("n".utf8).write(to: parent.appendingPathComponent("lodestar-notes.txt"))
        try Data("p".utf8).write(to: parent.appendingPathComponent("other.png"))
        controller.sweepHandover()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.url.path))
        XCTAssertEqual(names(parent), ["clipboard", "lodestar-notes.txt", "other.png"])
    }

    func testQuitSweepsTheFolderToo() throws {
        let controller = controller()
        let (clip, natives) = image("abc")
        let file = try XCTUnwrap(controller.imageFileForPasting(clip, natives: natives))
        controller.flushForQuit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        // And a later paste starts over, in a folder made again.
        let again = try XCTUnwrap(controller.imageFileForPasting(clip, natives: natives))
        XCTAssertTrue(FileManager.default.fileExists(atPath: again.path))
    }
}
