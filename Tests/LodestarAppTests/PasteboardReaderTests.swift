import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The clipboard's reads happen in `lodestar __clipboard-reader`, the built
/// binary run against this test run's own board, so the main thread never
/// waits on a copy. What it reads must be exactly what a read on main would.
final class PasteboardReaderTests: XCTestCase {
    private var readers: [ProcessPasteboardReader] = []

    override func tearDown() {
        readers.forEach { $0.stop() }
        readers = []
    }

    /// The `lodestar` the test bundle was built beside.
    private var binary: URL {
        get throws {
            let url = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("lodestar")
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw XCTSkip("unreachable: the lodestar binary is built with the tests (\(url.path))")
            }
            return url
        }
    }

    private func reader(_ executable: URL? = nil, deadline: TimeInterval = 15) throws -> ProcessPasteboardReader {
        let reader = ProcessPasteboardReader(executable: try executable ?? binary,
                                             boardName: SystemEvents.pasteboard.name.rawValue,
                                             deadline: deadline)
        readers.append(reader)
        return reader
    }

    private func read(_ reader: ProcessPasteboardReader, source: String? = nil,
                      excluded: Set<String> = [], timeout: TimeInterval = 20) -> PasteboardSnapshot?? {
        var answer: PasteboardSnapshot??
        reader.read(sourceBundleID: source, excludedApps: excluded) { answer = .some($0) }
        let deadline = Date().addingTimeInterval(timeout)
        while answer == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        return answer
    }

    private func wait(_ what: String, timeout: TimeInterval = 10, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), what)
    }

    /// Two items, rich forms, raw bytes and a browser's page: the reader's
    /// answer is the read main would have made, byte for byte.
    func testTheReaderReadsWhatMainWould() throws {
        let board = SystemEvents.pasteboard
        board.clearContents()
        let first = NSPasteboardItem()
        first.setString("the first item", forType: .string)
        first.setString("<b>the first item</b>", forType: .html)
        first.setString("https://github.com/x/y", forType: NSPasteboard.PasteboardType(Clipboard.sourceURLType))
        let second = NSPasteboardItem()
        second.setString("the second", forType: .string)
        second.setData(Data((0..<200_000).map { UInt8($0 & 0xff) }), forType: NSPasteboard.PasteboardType("com.example.raw"))
        XCTAssertTrue(board.writeObjects([first, second]))

        let reader = try reader()
        let answer = try XCTUnwrap(read(reader), "answered")
        let snapshot = try XCTUnwrap(answer, "and read")
        XCTAssertNotNil(reader.pid, "by a reader process")
        XCTAssertNotEqual(reader.pid, getpid())
        XCTAssertEqual(snapshot, PasteboardRead.snapshot(of: board, sourceBundleID: nil, excludedApps: []))
        XCTAssertEqual(snapshot.items.count, 2)
        XCTAssertEqual(snapshot.items[1].natives.first { $0.type == "com.example.raw" }?.data.count, 200_000)
        XCTAssertEqual(snapshot.sourceURL, "https://github.com/x/y")
        XCTAssertEqual(snapshot.changeCount, board.changeCount)
    }

    /// A concealed copy is refused from its types, before a byte is read,
    /// and so is one from an app that is never read.
    func testARefusedCopyIsNeverRead() throws {
        let board = SystemEvents.pasteboard
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString("hunter2", forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType(ClipboardController.concealed))
        board.writeObjects([item])
        let reader = try reader()
        let concealed = try XCTUnwrap(try XCTUnwrap(read(reader)))
        XCTAssertNotNil(concealed.refusal)
        XCTAssertTrue(concealed.items.allSatisfy { $0.plain == nil && $0.natives.isEmpty }, "nothing read")

        board.clearContents()
        board.setString("from an excluded app", forType: .string)
        let excluded = try XCTUnwrap(try XCTUnwrap(read(reader, source: "com.example.Private",
                                                        excluded: ["com.example.private"])))
        XCTAssertNotNil(excluded.refusal)
        XCTAssertNil(excluded.items.first?.plain)
    }

    /// With the reader in place a copy is noticed on main and filed when
    /// the answer lands; the poll itself never waits for the read.
    func testACaptureDoesNotWaitForTheRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reader-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SealedFixture.clipboardStore(directory)
        defer { store.close() }
        let controller = ClipboardController(store: store)
        controller.reader = try reader()
        SystemEvents.pasteboard.clearContents()
        SystemEvents.pasteboard.setString("read in another process", forType: .string)

        controller.capture()
        XCTAssertTrue(store.clips.isEmpty, "the poll returned before the read answered")
        XCTAssertTrue(controller.reader.busy)
        wait("the copy is filed when the answer lands") { store.clips.first?.preview == "read in another process" }
        XCTAssertEqual(store.clips.count, 1)
    }

    /// A reader that answers when the test says, with what the board held
    /// when it was asked, and refuses a second read while one is under way,
    /// as the process reader does.
    private final class HeldReader: PasteboardReading {
        var asked: [(snapshot: PasteboardSnapshot, done: (PasteboardSnapshot?) -> Void)] = []
        var busy: Bool { !asked.isEmpty }
        func read(sourceBundleID: String?, excludedApps: Set<String>, done: @escaping (PasteboardSnapshot?) -> Void) {
            guard asked.isEmpty else { return done(nil) }
            asked.append((PasteboardRead.snapshot(of: SystemEvents.pasteboard, sourceBundleID: sourceBundleID,
                                                  excludedApps: excludedApps), done))
        }
        func answer(file: StaticString = #filePath, line: UInt = #line) {
            guard !asked.isEmpty else { return XCTFail("no read was asked", file: file, line: line) }
            let (snapshot, done) = asked.removeFirst()
            done(snapshot)
        }
        func stop() {}
    }

    /// A copy made while the last one is still being read is not lost: the
    /// tick that sees it leaves it unseen, and a later tick reads it.
    func testACopyMadeDuringAReadIsReadNext() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reader-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SealedFixture.clipboardStore(directory)
        defer { store.close() }
        let controller = ClipboardController(store: store)
        let held = HeldReader()
        controller.reader = held
        let board = SystemEvents.pasteboard
        board.clearContents()
        board.setString("the first copy", forType: .string)
        controller.capture()
        board.clearContents()
        board.setString("the second copy", forType: .string)
        controller.capture()
        held.answer()
        XCTAssertEqual(store.clips.map(\.preview), ["the first copy"])
        controller.capture()
        XCTAssertTrue(held.busy, "the next tick reads the copy made during the read")
        held.answer()
        XCTAssertEqual(store.clips.map(\.preview), ["the second copy", "the first copy"])
    }

    /// The reader goes when Lodestar lets it go, and a reader that died is
    /// replaced by the next read.
    func testTheReaderEndsWithItsAppAndComesBackAfterDying() throws {
        SystemEvents.pasteboard.clearContents()
        SystemEvents.pasteboard.setString("one", forType: .string)
        let reader = try reader()
        XCTAssertNotNil(try XCTUnwrap(read(reader)))
        let first = try XCTUnwrap(reader.pid)
        kill(first, SIGKILL)
        wait("the death is noticed") { reader.pid == nil }
        let again = try XCTUnwrap(read(reader))
        XCTAssertEqual(again?.items.first?.plain, "one", "a fresh reader read the next copy")
        let second = try XCTUnwrap(reader.pid)
        XCTAssertNotEqual(first, second)
        reader.stop()
        wait("stopped, the reader is gone") { kill(second, 0) != 0 }
        XCTAssertFalse(reader.fellBack, "one death is not a reader that keeps failing")
    }

    /// A reader that never answers is given up on at its deadline, and one
    /// that keeps failing hands the reads back to main rather than leave
    /// the clipboard recording nothing.
    func testAReaderThatNeverAnswersIsGivenUpOnThenSetAside() throws {
        let silent = FileManager.default.temporaryDirectory.appendingPathComponent("silent-\(UUID().uuidString).sh")
        try "#!/bin/bash\nexec cat >/dev/null\n".write(to: silent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: silent.path)
        defer { try? FileManager.default.removeItem(at: silent) }
        SystemEvents.pasteboard.clearContents()
        SystemEvents.pasteboard.setString("still recorded", forType: .string)
        let reader = try reader(silent, deadline: 0.3)
        for attempt in 1..<ProcessPasteboardReader.failuresBeforeFallingBack + 1 {
            let answer = try XCTUnwrap(read(reader, timeout: 5), "attempt \(attempt) ended")
            XCTAssertNil(answer, "nothing came back from a reader that never answers")
            XCTAssertFalse(reader.busy, "and the read is over")
        }
        XCTAssertTrue(reader.fellBack)
        let main = try XCTUnwrap(read(reader))
        XCTAssertEqual(main?.items.first?.plain, "still recorded", "read on main from here on")
    }
}
