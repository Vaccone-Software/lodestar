import AppKit
import Foundation
import Stoic
import StoicTesting
import StoicXPC
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The clipboard reads through an XPC service. Here the service's own
/// object (`PasteboardReaderService`) runs on a real `XPCHost` behind
/// StoicXPC's simulated service, and the app's reader (`XPCPasteboardReader`,
/// on a real `XPCPeer`) reads through it on a virtual clock: every request
/// and answer crosses the wire's encoding, and only the launch by name is
/// left to the signed app's self-test (`SelfTest.clipboardReader`).
///
/// What the library decides is tested in Stoic (design/25's failure-mode
/// table). What is tested here is what Lodestar says to it (the method's
/// declaration), where the board is read, and what the reader makes of the
/// answers: a copy never lost, and the reads handed back to the main thread
/// when the service keeps failing.
final class PasteboardReaderTests: XCTestCase {
    /// A service of this process's own, on a test clock, and the readers made
    /// over it.
    private struct Rig {
        let clock: TestClock
        let events: RecordingInstrumentation
        let service: XPCSimulatedService
        let peer: XPCPeer
        let readers: ReaderBox

        func reader() -> XPCPasteboardReader {
            let reader = XPCPasteboardReader(boardName: SystemEvents.pasteboard.name.rawValue, peer: peer)
            readers.add(reader)
            return reader
        }

        /// Moves the clock once a timer is asleep (work woken by the test's
        /// last step goes to sleep on a task of its own).
        func advance(by duration: Duration, file: StaticString = #filePath, line: UInt = #line) async {
            let asleep = await PasteboardReaderTests.eventually("no timer went to sleep for \(duration)", file: file, line: line) {
                !clock.pendingDeadlines.isEmpty
            }
            if asleep { await clock.advance(by: duration) }
        }
    }

    private final class ReaderBox: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [XPCPasteboardReader] = []
        func add(_ reader: XPCPasteboardReader) { lock.withLock { all.append(reader) } }
        func stopAll() async {
            let readers = lock.withLock { all }
            await MainActor.run { readers.forEach { $0.stop() } }
        }
    }

    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        func set(_ value: Value) { lock.withLock { stored = value } }
        var value: Value? { lock.withLock { stored } }
    }

    /// The service's default host: the reader's own service object on a
    /// host of this build. `makeHost` is given the run's number (from 1).
    private func withRig(
        host makeHost: (@Sendable (Int) -> XPCHost)? = nil,
        build: String = Build.id,
        _ body: (Rig) async throws -> Void
    ) async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        try await withTestAmbient(clock: clock, seed: 7, events: events) { () async throws in
            let runs = Counter()
            let service = XPCSimulatedService {
                if let makeHost { return makeHost(runs.next()) }
                let host = XPCHost(build: Build.id)
                _ = PasteboardReaderService(host: host)
                return host
            }
            let peer = XPCPeer(service: PasteboardRead.serviceName, build: build, transport: service)
            let readers = ReaderBox()
            defer { peer.shutdown() }
            do {
                try await body(Rig(clock: clock, events: events, service: service, peer: peer, readers: readers))
            } catch {
                await readers.stopAll()
                throw error
            }
            await readers.stopAll()
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
    }

    /// A host whose reads never answer and ignore cancellation: a read stuck
    /// in the board.
    private static func silentHost(_ parked: ReadsParked) -> XPCHost {
        let host = XPCHost(build: Build.id)
        host.handle(PasteboardReaderAPI.read) { _, _ in
            parked.note()
            await parked.park()
            return PasteboardSnapshot(changeCount: 0, items: [])
        }
        return host
    }

    private final class ReadsParked: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var parked: [CheckedContinuation<Void, Never>] = []
        func note() { lock.withLock { count += 1 } }
        var started: Int { lock.withLock { count } }
        func park() async { await withCheckedContinuation { c in lock.withLock { parked.append(c) } } }
        func unpark() {
            let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in defer { parked = [] }; return parked }
            all.forEach { $0.resume() }
        }
    }

    @discardableResult
    static func eventually(_ what: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        let held = condition()
        XCTAssertTrue(held, what, file: file, line: line)
        return held
    }

    /// One read, asked on main as the capture asks it, answered on main.
    private func read(_ reader: XPCPasteboardReader, source: String? = nil, excluded: Set<String> = [],
                      during: (() async -> Void)? = nil) async -> PasteboardSnapshot?? {
        let answer = Box<PasteboardSnapshot?>()
        await MainActor.run {
            reader.read(sourceBundleID: source, excludedApps: excluded) { answer.set($0) }
        }
        if let during { await during() }
        await Self.eventually("the read answered") { answer.value != nil }
        return answer.value
    }

    /// One read that must have been answered with a snapshot.
    private func snapshot(_ reader: XPCPasteboardReader, source: String? = nil, excluded: Set<String> = [],
                          during: (() async -> Void)? = nil) async throws -> PasteboardSnapshot {
        let answer = await read(reader, source: source, excluded: excluded, during: during)
        return try XCTUnwrap(try XCTUnwrap(answer, "answered"), "and read")
    }

    /// Spins the main run loop until `condition`, for the sync tests that
    /// need no clock.
    private func wait(_ what: String, timeout: TimeInterval = 10, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), what)
    }

    // MARK: - What crosses

    /// Two items, rich forms, raw bytes and a browser's page: the answer
    /// that crossed XPC is the read main would have made, byte for byte,
    /// and it was made on the main queue, where the board is read.
    func testTheServiceReadsWhatMainWould() async throws {
        let board = SystemEvents.pasteboard
        await MainActor.run {
            board.clearContents()
            let first = NSPasteboardItem()
            first.setString("the first item", forType: .string)
            first.setString("<b>the first item</b>", forType: .html)
            first.setString("https://github.com/x/y", forType: NSPasteboard.PasteboardType(Clipboard.sourceURLType))
            let second = NSPasteboardItem()
            second.setString("the second", forType: .string)
            second.setData(Data((0..<200_000).map { UInt8($0 & 0xff) }), forType: NSPasteboard.PasteboardType("com.example.raw"))
            XCTAssertTrue(board.writeObjects([first, second]))
        }
        let ranOnMain = Box<Bool>()
        try await withRig(host: { _ in
            let host = XPCHost(build: Build.id)
            _ = PasteboardReaderService(host: host) { request in
                ranOnMain.set(Thread.isMainThread)
                return PasteboardReaderService.systemRead(request)
            }
            return host
        }) { rig in
            let snapshot = try await snapshot(rig.reader())
            XCTAssertEqual(rig.service.runs, 1, "through the service")
            XCTAssertEqual(ranOnMain.value, true, "on the queue the board is read on")
            let direct = await MainActor.run { PasteboardRead.snapshot(of: board, sourceBundleID: nil, excludedApps: []) }
            XCTAssertEqual(snapshot, direct)
            XCTAssertEqual(snapshot.items.count, 2)
            XCTAssertEqual(snapshot.items[1].natives.first { $0.type == "com.example.raw" }?.data.count, 200_000)
            XCTAssertEqual(snapshot.sourceURL, "https://github.com/x/y")
            XCTAssertEqual(snapshot.changeCount, board.changeCount)
        }
    }

    /// A concealed copy is refused from its types, before a byte is read,
    /// and so is one from an app that is never read.
    func testARefusedCopyIsNeverRead() async throws {
        let board = SystemEvents.pasteboard
        await MainActor.run {
            board.clearContents()
            let item = NSPasteboardItem()
            item.setString("hunter2", forType: .string)
            item.setData(Data(), forType: NSPasteboard.PasteboardType(ClipboardController.concealed))
            board.writeObjects([item])
        }
        try await withRig { rig in
            let reader = rig.reader()
            let concealed = try await snapshot(reader)
            XCTAssertNotNil(concealed.refusal)
            XCTAssertTrue(concealed.items.allSatisfy { $0.plain == nil && $0.natives.isEmpty }, "nothing read")

            await MainActor.run {
                board.clearContents()
                board.setString("from an excluded app", forType: .string)
            }
            let excluded = try await snapshot(reader, source: "com.example.Private", excluded: ["com.example.private"])
            XCTAssertNotNil(excluded.refusal)
            XCTAssertNil(excluded.items.first?.plain)
        }
    }

    /// A copy an app marked transient says which app it was, in the
    /// writer's own words, though not a byte of it is read.
    func testARefusedCopySaysWhoWroteIt() async throws {
        let board = SystemEvents.pasteboard
        await MainActor.run {
            board.clearContents()
            let item = NSPasteboardItem()
            item.setString("put back in a moment", forType: .string)
            item.setString("com.example.writer", forType: NSPasteboard.PasteboardType(PasteboardSnapshot.declaredSourceType))
            item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            board.writeObjects([item])
        }
        try await withRig { rig in
            let snapshot = try await snapshot(rig.reader())
            XCTAssertNotNil(snapshot.refusal)
            XCTAssertEqual(snapshot.declaredSource, "com.example.writer")
            XCTAssertTrue(snapshot.items.allSatisfy { $0.plain == nil && $0.natives.isEmpty }, "nothing of it read")
        }
    }

    // MARK: - The capture around it

    /// With the service in place a copy is noticed on main and filed when
    /// the answer lands; the poll itself never waits for the read.
    func testACaptureDoesNotWaitForTheRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reader-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withRig { rig in
            let reader = rig.reader()
            let (controller, store) = await MainActor.run { () -> (ClipboardController, ClipboardStore) in
                let store = SealedFixture.clipboardStore(directory)
                let controller = ClipboardController(store: store)
                controller.reader = reader
                SystemEvents.pasteboard.clearContents()
                SystemEvents.pasteboard.setString("read by the service", forType: .string)
                controller.capture()
                XCTAssertTrue(store.clips.isEmpty, "the poll returned before the read answered")
                XCTAssertTrue(controller.reader.busy)
                return (controller, store)
            }
            await Self.eventually("the copy is filed when the answer lands") {
                DispatchQueue.main.sync { store.clips.first?.preview == "read by the service" }
            }
            XCTAssertEqual(DispatchQueue.main.sync { store.clips.count }, 1)
            await MainActor.run { store.close() }
            withExtendedLifetime(controller) {}
        }
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

    /// A service that ends mid-read: the read is declared read-only, so it
    /// is made again by the next run, and answered, with the failure count
    /// untouched: a copy read late rather than lost.
    func testAReadLostWithItsServiceIsReadAgainByTheNext() async throws {
        await MainActor.run {
            SystemEvents.pasteboard.clearContents()
            SystemEvents.pasteboard.setString("one", forType: .string)
        }
        let box = Box<XPCSimulatedService>()
        try await withRig(host: { run in
            let host = XPCHost(build: Build.id)
            if run == 1 {
                // The first process ends while it reads, as a crash would.
                host.handle(PasteboardReaderAPI.read) { _, _ in
                    Task { await box.value?.crash() }
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                    return PasteboardSnapshot(changeCount: 0, items: [])
                }
            } else {
                _ = PasteboardReaderService(host: host)
            }
            return host
        }) { rig in
            box.set(rig.service)
            let reader = rig.reader()
            let answer = try await snapshot(reader, during: { await self.eventuallyRetrying(rig) })
            XCTAssertEqual(answer.items.first?.plain, "one", "the next run read it")
            XCTAssertEqual(rig.service.runs, 2)
            XCTAssertFalse(reader.fellBack, "one end is not a reader that keeps failing")
            XCTAssertEqual(rig.events.count("xpc.run_lost"), 1)
        }
    }

    /// Passes the backoff between a lost attempt and the next.
    private func eventuallyRetrying(_ rig: Rig) async {
        await Self.eventually("the first attempt was lost") { rig.events.count("retry.attempt_failed") >= 1 }
        await rig.advance(by: .seconds(3))
    }

    /// A service that never answers is given up on at the deadline the
    /// method carries (fifteen seconds), is ended when its caller leaves
    /// without an answer, and one that keeps failing hands the reads back to
    /// main rather than leave the clipboard recording nothing.
    func testAServiceThatNeverAnswersIsGivenUpOnThenEndedThenSetAside() async throws {
        await MainActor.run {
            SystemEvents.pasteboard.clearContents()
            SystemEvents.pasteboard.setString("still recorded", forType: .string)
        }
        let parked = ReadsParked()
        defer { parked.unpark() }
        try await withRig(host: { _ in Self.silentHost(parked) }) { rig in
            let reader = rig.reader()
            for attempt in 1...XPCPasteboardReader.failuresBeforeFallingBack {
                let box = Box<PasteboardSnapshot?>()
                await MainActor.run { reader.read(sourceBundleID: nil, excludedApps: []) { box.set($0) } }
                await Self.eventually("attempt \(attempt) reached the service") { parked.started == attempt }
                await rig.advance(by: .seconds(14))
                XCTAssertNil(box.value, "not yet: the deadline is fifteen seconds")
                await rig.advance(by: .seconds(1))
                await Self.eventually("attempt \(attempt) ended") { box.value != nil }
                XCTAssertEqual(box.value.flatMap { $0 }?.items.count, nil, "nothing came back from a service that never answers")
                await Self.eventually("and the service was ended, stuck as it was") { rig.service.exits.count == attempt }
                XCTAssertFalse(DispatchQueue.main.sync { reader.busy }, "the read is over")
            }
            XCTAssertTrue(reader.fellBack)
            let main = try await snapshot(reader)
            XCTAssertEqual(main.items.first?.plain, "still recorded", "read on main from here on")
            XCTAssertEqual(rig.service.runs, 3, "and the service is not asked again")
        }
    }

    /// A service the bundle does not carry, or of another build, fails each
    /// read at once, and three of them set it aside too.
    func testAServiceThatIsNotThereIsSetAsideAfterThreeFailures() async throws {
        await MainActor.run {
            SystemEvents.pasteboard.clearContents()
            SystemEvents.pasteboard.setString("still recorded", forType: .string)
        }
        try await withRig { rig in
            rig.service.refusesConnections = "no such service"
            let reader = rig.reader()
            for attempt in 1...XPCPasteboardReader.failuresBeforeFallingBack {
                let answer = await read(reader)
                XCTAssertNotNil(answer, "attempt \(attempt) ended")
                XCTAssertNil(answer ?? nil, "with nothing")
            }
            XCTAssertTrue(reader.fellBack)
            XCTAssertEqual(rig.service.runs, 0)
        }
    }

    /// The method says what the library is to do with a read: it is
    /// repeatable, its deadline is the fifteen seconds the reader always
    /// waited, and a read its caller left unanswered ends the service.
    func testTheReadsDeclarationSaysWhatTheLibraryDecides() {
        let read = PasteboardReaderAPI.read
        XCTAssertEqual(read.operation.safety, .readOnly)
        XCTAssertEqual(read.operation.length, .long)
        XCTAssertEqual(read.operation.policy(at: .interactive).deadline, .seconds(15))
        XCTAssertNil(read.operation.policy(at: .interactive).attemptTimeout, "a copy from another device may take seconds")
        XCTAssertEqual(read.ifStuck, .endService(after: .zero))
    }

    // MARK: - The bundle

    /// The service ships in the bundle under the name the app asks for, as
    /// an application-type service that joins the user's session (the
    /// pasteboard is a per-session resource), and it is signed before the
    /// app that holds it.
    func testTheServiceIsPackagedUnderTheNameTheAppAsksFor() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(NSDictionary(contentsOf: root.appendingPathComponent("packaging/ClipboardReader-Info.plist")))
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, PasteboardRead.serviceName)
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "LodestarClipboardReader")
        XCTAssertEqual(plist["CFBundlePackageType"] as? String, "XPC!")
        let service = try XCTUnwrap(plist["XPCService"] as? [String: Any])
        XCTAssertEqual(service["ServiceType"] as? String, "Application")
        XCTAssertNil(service["RunLoopType"], "StoicXPC's host parks the main thread in dispatchMain itself")
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

private extension RecordingInstrumentation {
    func count(_ name: EventName) -> Int { events(named: name).count }
}
