import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The clipboard reads through an XPC service. Here the service's own
/// object is hosted behind an anonymous listener, the way XPC services are
/// tested: every request and answer crosses real XPC, with its error and
/// interruption handling, and only the launch by name is left to the
/// signed app's self-test (`SelfTest.clipboardReader`).
final class PasteboardReaderTests: XCTestCase {
    /// Hosts whatever the test exports, a fresh object per connection.
    private final class Host: NSObject, NSXPCListenerDelegate {
        let listener = NSXPCListener.anonymous()
        var exported: (Int) -> NSObject
        private(set) var connections = 0
        init(_ exported: @escaping (Int) -> NSObject) {
            self.exported = exported
            super.init()
            listener.delegate = self
            listener.resume()
        }
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connections += 1
            connection.exportedInterface = NSXPCInterface(with: PasteboardReaderXPC.self)
            connection.exportedObject = exported(connections)
            connection.resume()
            return true
        }
    }

    /// Never answers.
    private final class Silent: NSObject, PasteboardReaderXPC {
        func read(_ request: Data, reply: @escaping @Sendable (Data?) -> Void) {}
    }

    /// Ends its connection mid-read, as a service that crashed would.
    private final class Ending: NSObject, PasteboardReaderXPC {
        func read(_ request: Data, reply: @escaping @Sendable (Data?) -> Void) {
            NSXPCConnection.current()?.invalidate()
        }
    }

    private var hosts: [Host] = []
    private var readers: [XPCPasteboardReader] = []

    override func tearDown() {
        readers.forEach { $0.stop() }
        hosts.forEach { $0.listener.invalidate() }
        readers = []
        hosts = []
    }

    private func reader(deadline: TimeInterval = 15,
                        exporting exported: @escaping (Int) -> NSObject = { _ in
                            PasteboardReaderService(wedgedAfter: nil) }) -> (XPCPasteboardReader, Host) {
        let host = Host(exported)
        let reader = XPCPasteboardReader(boardName: SystemEvents.pasteboard.name.rawValue, deadline: deadline) {
            NSXPCConnection(listenerEndpoint: host.listener.endpoint)
        }
        hosts.append(host)
        readers.append(reader)
        return (reader, host)
    }

    private func read(_ reader: XPCPasteboardReader, source: String? = nil,
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

    // MARK: - What crosses

    /// Two items, rich forms, raw bytes and a browser's page: the answer
    /// that crossed XPC is the read main would have made, byte for byte.
    func testTheServiceReadsWhatMainWould() throws {
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

        let (reader, host) = reader()
        let snapshot = try XCTUnwrap(try XCTUnwrap(read(reader), "answered"), "and read")
        XCTAssertEqual(host.connections, 1, "through the service")
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
        let (reader, _) = reader()
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

    /// A copy an app marked transient says which app it was, in the
    /// writer's own words, though not a byte of it is read.
    func testARefusedCopySaysWhoWroteIt() throws {
        let board = SystemEvents.pasteboard
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString("put back in a moment", forType: .string)
        item.setString("com.example.writer", forType: NSPasteboard.PasteboardType(PasteboardSnapshot.declaredSourceType))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        board.writeObjects([item])
        let (reader, _) = reader()
        let snapshot = try XCTUnwrap(try XCTUnwrap(read(reader)))
        XCTAssertNotNil(snapshot.refusal)
        XCTAssertEqual(snapshot.declaredSource, "com.example.writer")
        XCTAssertTrue(snapshot.items.allSatisfy { $0.plain == nil && $0.natives.isEmpty }, "nothing of it read")
    }

    // MARK: - The capture around it

    /// With the service in place a copy is noticed on main and filed when
    /// the answer lands; the poll itself never waits for the read.
    func testACaptureDoesNotWaitForTheRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reader-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SealedFixture.clipboardStore(directory)
        defer { store.close() }
        let controller = ClipboardController(store: store)
        controller.reader = reader().0
        SystemEvents.pasteboard.clearContents()
        SystemEvents.pasteboard.setString("read by the service", forType: .string)

        controller.capture()
        XCTAssertTrue(store.clips.isEmpty, "the poll returned before the read answered")
        XCTAssertTrue(controller.reader.busy)
        wait("the copy is filed when the answer lands") { store.clips.first?.preview == "read by the service" }
        XCTAssertEqual(store.clips.count, 1)
    }

    /// A reader that answers when the test says, with what the board held
    /// when it was asked, and refuses a second read while one is under way,
    /// as the service reader does.
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

    // MARK: - When the service fails

    /// A service that ends mid-read is heard at once through the error
    /// handler, well inside the deadline, and the connection, only
    /// interrupted, reaches a fresh service with the next read.
    func testAServiceThatEndsMidReadIsHeardAtOnceAndReplaced() throws {
        SystemEvents.pasteboard.clearContents()
        SystemEvents.pasteboard.setString("one", forType: .string)
        let (reader, host) = reader(deadline: 60) { connection in
            connection == 1 ? Ending() : PasteboardReaderService(wedgedAfter: nil)
        }
        let lost = try XCTUnwrap(read(reader, timeout: 5), "the ended read answered before the deadline")
        XCTAssertNil(lost, "with nothing")
        XCTAssertFalse(reader.busy)
        let again = try XCTUnwrap(read(reader, timeout: 5))
        XCTAssertEqual(again?.items.first?.plain, "one", "the next read reached a fresh service")
        XCTAssertEqual(host.connections, 2)
        XCTAssertFalse(reader.fellBack, "one end is not a reader that keeps failing")
    }

    /// A connection that cannot reach its service is invalidated, and the
    /// reader lets it go: the next read makes a new one.
    func testAnInvalidatedConnectionIsReplacedByTheNextRead() throws {
        SystemEvents.pasteboard.clearContents()
        SystemEvents.pasteboard.setString("two", forType: .string)
        let gone = Host { _ in PasteboardReaderService(wedgedAfter: nil) }
        gone.listener.invalidate()
        let working = Host { _ in PasteboardReaderService(wedgedAfter: nil) }
        hosts += [gone, working]
        var made = 0
        let reader = XPCPasteboardReader(boardName: SystemEvents.pasteboard.name.rawValue, deadline: 60) {
            made += 1
            return NSXPCConnection(listenerEndpoint: (made == 1 ? gone : working).listener.endpoint)
        }
        readers.append(reader)
        let lost = try XCTUnwrap(read(reader, timeout: 5), "a service that cannot be reached answers at once")
        XCTAssertNil(lost)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1)) // the invalidation handler's hop to main
        let again = try XCTUnwrap(read(reader, timeout: 5))
        XCTAssertEqual(again?.items.first?.plain, "two", "read through a new connection")
        XCTAssertEqual(made, 2)
    }

    /// A service that never answers is given up on at the deadline, and
    /// one that keeps failing hands the reads back to main rather than
    /// leave the clipboard recording nothing.
    func testAServiceThatNeverAnswersIsGivenUpOnThenSetAside() throws {
        SystemEvents.pasteboard.clearContents()
        SystemEvents.pasteboard.setString("still recorded", forType: .string)
        let (reader, _) = reader(deadline: 0.3) { _ in Silent() }
        for attempt in 1...XPCPasteboardReader.failuresBeforeFallingBack {
            let answer = try XCTUnwrap(read(reader, timeout: 5), "attempt \(attempt) ended")
            XCTAssertNil(answer, "nothing came back from a service that never answers")
            XCTAssertFalse(reader.busy, "and the read is over")
        }
        XCTAssertTrue(reader.fellBack)
        let main = try XCTUnwrap(read(reader))
        XCTAssertEqual(main?.items.first?.plain, "still recorded", "read on main from here on")
    }

    /// The service ends itself when a read wedges its main thread, since
    /// no client can end it; a read that answers in time ends nothing.
    func testTheServiceEndsItselfWhenAReadWedgesItsMainThread() throws {
        SystemEvents.pasteboard.clearContents()
        SystemEvents.pasteboard.setString("slow", forType: .string)
        let body = try PropertyListEncoder().encode(
            PasteboardReadRequest(boardName: SystemEvents.pasteboard.name.rawValue, sourceBundleID: nil, excludedApps: []))
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var raised = 0
            func raise() { lock.withLock { raised += 1 } }
            var count: Int { lock.withLock { raised } }
        }

        let quick = Flag(), quickReplies = Flag()
        PasteboardReaderService(wedgedAfter: 0.3, onWedged: { quick.raise() }).read(body) { _ in quickReplies.raise() }
        wait("a quick read answers") { quickReplies.count == 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(quick.count, 0, "and ends nothing")

        let wedged = Flag(), wedgedReplies = Flag()
        PasteboardReaderService(wedgedAfter: 0.2, onWedged: { wedged.raise() }).read(body) { _ in wedgedReplies.raise() }
        Thread.sleep(forTimeInterval: 0.6) // the service's main thread, stuck
        XCTAssertEqual(wedged.count, 1, "a read stuck past its limit ends the service")
    }

    // MARK: - The bundle

    /// The service ships in the bundle under the name the app asks for, as
    /// an application-type service with a run loop on its main thread, and
    /// it is signed before the app that holds it.
    func testTheServiceIsPackagedUnderTheNameTheAppAsksFor() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(NSDictionary(contentsOf: root.appendingPathComponent("packaging/ClipboardReader-Info.plist")))
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, PasteboardRead.serviceName)
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "LodestarClipboardReader")
        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "XPC!")
        let service = try XCTUnwrap(plist["XPCService"] as? [String: Any])
        XCTAssertEqual(service["ServiceType"] as? String, "Application")
        XCTAssertEqual(service["RunLoopType"] as? String, "NSRunLoop")
        XCTAssertEqual(service["JoinExistingSession"] as? Bool, true, "the pasteboard is a per-session service")

        let makeApp = try String(contentsOf: root.appendingPathComponent("scripts/make-app.sh"), encoding: .utf8)
        XCTAssertTrue(makeApp.contains("Contents/XPCServices/LodestarClipboardReader.xpc"))
        for script in ["scripts/make-app.sh", "scripts/release.sh"] {
            let lines = try String(contentsOf: root.appendingPathComponent(script), encoding: .utf8)
                .split(separator: "\n").map(String.init)
            let signsService = lines.firstIndex { $0.contains("--sign") && ($0.contains("\"$XPC\"") || $0.contains("LodestarClipboardReader.xpc\"")) }
            let signsApp = lines.firstIndex { $0.contains("--sign") && $0.hasSuffix("\"$APP\"") }
            let service = try XCTUnwrap(signsService, "\(script) signs the service")
            let app = try XCTUnwrap(signsApp, "\(script) signs the app")
            XCTAssertLessThan(service, app, "\(script): inside out, the service before the app")
        }
    }
}
