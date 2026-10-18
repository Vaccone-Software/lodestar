import CryptoKit
import Darwin
import Stoic
import StoicDownloads
import StoicHTTP
import StoicStore
import StoicTesting
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The real file system with a disk that can be small, and fail at the
/// swap that places a model: a bundle is placed by swapping directories,
/// which the simulated file system does not model, so the real one is used
/// and made to misbehave.
struct TestDisk: FileSystem {
    final class Script: @unchecked Sendable {
        // stoic:allow(unchecked-sendable): a lock guards every field; tests set it before the run and read it after
        private let lock = NSLock()
        private var _free: UInt64?
        private var _failExchange: Int32?
        private var _failSyncAfterExchange: Int32?
        private var _exchanged = false
        private var _failWrite: Int32?
        var free: UInt64? { get { lock.withLock { _free } } set { lock.withLock { _free = newValue } } }
        var failExchange: Int32? { get { lock.withLock { _failExchange } } set { lock.withLock { _failExchange = newValue } } }
        var failSyncAfterExchange: Int32? {
            get { lock.withLock { _failSyncAfterExchange } } set { lock.withLock { _failSyncAfterExchange = newValue } }
        }
        var failWrite: Int32? { get { lock.withLock { _failWrite } } set { lock.withLock { _failWrite = newValue } } }
        var exchanged: Bool { get { lock.withLock { _exchanged } } set { lock.withLock { _exchanged = newValue } } }
    }

    let script = Script()
    let base: PosixFileSystem

    init(newFileMode: UInt16 = 0o644) { base = PosixFileSystem(newFileMode: newFileMode, newDirectoryMode: 0o755) }

    var newFileMode: UInt16 { base.newFileMode }
    func open(_ path: String, mode: OpenMode) throws(StoreError) -> OpenFile { try base.open(path, mode: mode) }
    func read(_ file: OpenFile, at offset: Int, count: Int) throws(StoreError) -> [UInt8] { try base.read(file, at: offset, count: count) }
    func write(_ file: OpenFile, _ bytes: [UInt8], at offset: Int) throws(StoreError) {
        if let code = script.failWrite { throw StoreError(errno: code, operation: "write") }
        try base.write(file, bytes, at: offset)
    }
    func size(of file: OpenFile) throws(StoreError) -> Int { try base.size(of: file) }
    func truncate(_ file: OpenFile, to size: Int) throws(StoreError) { try base.truncate(file, to: size) }
    func fullSync(_ file: OpenFile) throws(StoreError) { try base.fullSync(file) }
    func close(_ file: OpenFile) throws(StoreError) { try base.close(file) }
    func syncDirectory(_ directory: String) throws(StoreError) {
        if script.exchanged, let code = script.failSyncAfterExchange {
            throw StoreError(errno: code, operation: "fsync", path: directory)
        }
        try base.syncDirectory(directory)
    }
    func rename(from source: String, to destination: String) throws(StoreError) { try base.rename(from: source, to: destination) }
    func remove(_ path: String) throws(StoreError) { try base.remove(path) }
    func list(directory: String) throws(StoreError) -> [String] { try base.list(directory: directory) }
    func exists(_ path: String) throws(StoreError) -> Bool { try base.exists(path) }
    func freeSpace(at directory: String) throws(StoreError) -> UInt64 {
        if let free = script.free { return free }
        return try base.freeSpace(at: directory)
    }
    func createDirectory(_ path: String) throws(StoreError) { try base.createDirectory(path) }
    func permissions(of path: String) throws(StoreError) -> UInt16? { try base.permissions(of: path) }
    func setPermissions(_ file: OpenFile, to permissions: UInt16) throws(StoreError) { try base.setPermissions(file, to: permissions) }
    func readLink(_ path: String) throws(StoreError) -> String? { try base.readLink(path) }
    func exchange(_ first: String, _ second: String) throws(StoreError) {
        if let code = script.failExchange { throw StoreError(errno: code, operation: "exchange", path: first) }
        try base.exchange(first, second)
        script.exchanged = true
    }
    func removeTree(_ path: String) throws(StoreError) { try base.removeTree(path) }
    func tryLock(_ file: OpenFile) throws(StoreError) -> Bool { try base.tryLock(file) }
    func unlock(_ file: OpenFile) throws(StoreError) { try base.unlock(file) }
}

/// A Hugging Face that lives in the test: Stoic's scripted transport serving
/// each file of a tiny model, the network on a script and time on a
/// `TestClock`.
@MainActor
final class EditorDownloadTests: XCTestCase {
    private var root: URL!
    /// The events the download under test records, for `settle` to read.
    private var events = RecordingInstrumentation()
    private let weights = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    private let config = Data(#"{"model_type":"test"}"#.utf8)
    private let weightsRoute = HTTPRequest.get(URL(string: "https://huggingface.co/test/tiny-model/resolve/abc123/model.safetensors")!)
    private let configRoute = HTTPRequest.get(URL(string: "https://huggingface.co/test/tiny-model/resolve/abc123/config.json")!)

    private var manifest: EditorManifest {
        EditorManifest(repo: "test/tiny-model", revision: "abc123", files: [
            .init(path: "config.json", size: Int64(config.count), gitSHA1: Self.gitSHA1(config)),
            .init(path: "model.safetensors", size: Int64(weights.count),
                  sha256: SHA256.hash(data: weights).map { String(format: "%02x", $0) }.joined()),
        ])
    }

    static func gitSHA1(_ data: Data) -> String {
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(data.count)\u{0}".utf8))
        hash.update(data: data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private var weightsResource: ScriptedTransport.Resource { .init([UInt8](weights), etag: "\"w1\"") }

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// A transport serving the model: every file, whole, and as many
    /// scripted steps for the weights as the test gives.
    private func transport(weights steps: [ScriptedTransport.Step]? = nil) -> ScriptedTransport {
        let transport = ScriptedTransport()
        transport.on(configRoute, respond: [.serving(.init([UInt8](config), etag: "\"c1\""))])
        transport.on(weightsRoute, respond: steps ?? [.serving(weightsResource)])
        return transport
    }

    private func download(_ transport: ScriptedTransport, disk: any FileSystem = TestDisk(),
                          grace: Duration = .zero) -> EditorDownload {
        let manifest = self.manifest
        return EditorDownload(root: root, transport: transport, fileSystem: disk,
                              manifests: { $0 == .editor(.standard) ? manifest : nil }, waitingGrace: grace)
    }

    private func isFailed(_ state: EditorDownload.State) -> Bool { if case .failed = state { return true } else { return false } }

    /// What moves the virtual clock while a download is settled.
    private enum Drive {
        /// Each backoff, once the download has said it is waiting one out:
        /// a request's own timeout sleeps too, and must not be skipped past.
        case retries
        /// Nothing: the test moves the clock itself.
        case never
        /// Every sleeper, by `step`: a body that arrives a chunk at a time.
        case always(step: Duration)
    }

    /// Lets the download run until `done`, moving the virtual clock as `drive`
    /// says. Real time only bounds a test that never gets there.
    private func settle(_ download: EditorDownload, _ clock: TestClock, _ drive: Drive? = nil,
                        until done: (EditorDownload.State) -> Bool,
                        file: StaticString = #filePath, line: UInt = #line) async {
        let limit = ContinuousClock.now.advanced(by: .seconds(30))
        var handled = 0
        while !done(download.state), ContinuousClock.now < limit {
            switch drive ?? .retries {
            case .retries:
                let retries = events.events(named: "download.retry").count
                if retries > handled, clock.sleeperCount > 0 {
                    handled = retries
                    await clock.advance(by: .seconds(300))
                }
            case .always(let step):
                if clock.sleeperCount > 0 { await clock.advance(by: step) }
            case .never:
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(done(download.state), "stuck at \(download.state)", file: file, line: line)
    }

    /// Runs `body` on a test clock, with the events a download records.
    private func run(_ body: (TestClock, RecordingInstrumentation) async throws -> Void) async throws {
        let clock = TestClock()
        events = RecordingInstrumentation()
        try await withTestAmbient(clock: clock, events: events) { try await body(clock, events) }
    }

    /// Waits until the download has recorded `count` retries: it is then
    /// asleep on its backoff, and nothing else is (its request is over).
    private func waitForRetries(_ count: Int, _ events: RecordingInstrumentation, _ clock: TestClock) async {
        let limit = ContinuousClock.now.advanced(by: .seconds(30))
        while events.events(named: "download.retry").count < count, ContinuousClock.now < limit {
            await Task.yield()
        }
        await clock.waitForSleepers()
    }

    private var finalFolder: URL { root.appendingPathComponent("tiny-model", isDirectory: true) }
    private var staging: URL { root.appendingPathComponent(".tiny-model.partial", isDirectory: true) }
    private func requests(_ transport: ScriptedTransport, _ route: HTTPRequest) -> [HTTPRequest] { transport.requests(to: route) }

    // MARK: - Arriving

    func testAModelArrivesWholeAndChecked() async throws {
        try await run { clock, _ in
            let transport = transport()
            let download = download(transport)
            var finished: [EditorEngine] = []
            var states: [EditorDownload.State] = []
            download.finished = { finished.append($0) }
            download.changed = { states.append(download.state) }
            download.fetch(.standard)
            await settle(download, clock) { $0 == .ready }
            XCTAssertEqual(finished, [.standard])
            XCTAssertEqual(try Data(contentsOf: finalFolder.appendingPathComponent("model.safetensors")), weights)
            XCTAssertTrue(EditorModels.isComplete(finalFolder, manifest))
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "the staging folder became the model")
            let excluded = try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            XCTAssertEqual(excluded, true, "gigabytes that download again are not backed up")
            for name in ["config.json", "model.safetensors"] {
                let mode = try FileManager.default.attributesOfItem(atPath: finalFolder.appendingPathComponent(name).path)[.posixPermissions] as? Int
                XCTAssertEqual(mode, 0o644, "model files are readable by every user: \(name)")
            }
            XCTAssertTrue(states.contains(.verifying), "the check is said: \(states)")
            XCTAssertEqual(requests(transport, weightsRoute).count, 1)
        }
    }

    func testACutDownloadResumesWhereItStopped() async throws {
        try await run { clock, events in
            let transport = transport(weights: [.serving(weightsResource, fault: .cut(after: 120_000)), .serving(weightsResource)])
            let download = download(transport)
            download.fetch(.standard)
            await settle(download, clock) { $0 == .ready }
            let ranges = requests(transport, weightsRoute).map { $0.headers["Range"] }
            XCTAssertEqual(ranges.first ?? "x", nil, "the first request asks for everything")
            XCTAssertEqual(ranges.last ?? nil, "bytes=120000-", "the retry asks only for the rest")
            XCTAssertEqual(requests(transport, weightsRoute).last?.headers["If-Range"], "\"w1\"", "and only if it is still that file")
            XCTAssertEqual(try Data(contentsOf: finalFolder.appendingPathComponent("model.safetensors")), weights)
            XCTAssertEqual(events.events(named: "download.retry").count, 1)
        }
    }

    func testAServerThatIgnoresTheRangeStartsTheFileOver() async throws {
        try await run { clock, _ in
            var resource = weightsResource
            resource.honoursRange = false
            let transport = transport(weights: [.serving(resource, fault: .cut(after: 50_000)), .serving(resource)])
            let download = download(transport)
            download.fetch(.standard)
            await settle(download, clock) { $0 == .ready }
            XCTAssertEqual(try Data(contentsOf: finalFolder.appendingPathComponent("model.safetensors")), weights,
                           "a whole file after a 200, not the rest appended to the start")
        }
    }

    func testACorruptFileIsFetchedAgainOnceThenSaid() async throws {
        try await run { clock, _ in
            var corrupt = [UInt8](weights)
            corrupt[0] ^= 0xFF
            let wrong = ScriptedTransport.Resource(corrupt, etag: "\"w1\"")
            let healing = transport(weights: [.serving(wrong), .serving(weightsResource)])
            let healed = download(healing)
            healed.fetch(.standard)
            await settle(healed, clock) { $0 == .ready }
            XCTAssertEqual(requests(healing, weightsRoute).count, 2, "once more, from the start")
            XCTAssertNil(requests(healing, weightsRoute).last?.headers["Range"])

            try? FileManager.default.removeItem(at: root)
            let broken = transport(weights: [.serving(wrong)])
            let never = download(broken)
            never.fetch(.standard)
            await settle(never, clock) { self.isFailed($0) }
            XCTAssertEqual(never.state, .failed("the download did not match, try again later"))
            XCTAssertEqual(requests(broken, weightsRoute).count, 2, "twice, and no more")
            XCTAssertFalse(FileManager.default.fileExists(atPath: finalFolder.path), "never a model that did not match")
        }
    }

    func testAFullDiskIsSaidBeforeAByteIsFetched() async throws {
        try await run { clock, _ in
            let disk = TestDisk()
            disk.script.free = 1_000_000
            let transport = transport()
            let download = download(transport, disk: disk)
            download.fetch(.standard)
            await settle(download, clock) { self.isFailed($0) }
            XCTAssertEqual(download.status, "Standard · needs 3 GB free")
            XCTAssertEqual(transport.requestCount, 0)
        }
    }

    func testTheRoomItNeedsIsWhatIsLeftPlusTwoGigabytes() async throws {
        try await run { clock, _ in
            // Exactly enough for the whole and the margin: enough. One byte
            // less: not, and it says so.
            let total = UInt64(manifest.total)
            let disk = TestDisk()
            disk.script.free = total + 2_000_000_000 - 1
            let short = download(transport(), disk: disk)
            short.fetch(.standard)
            await settle(short, clock) { self.isFailed($0) }
            XCTAssertEqual(short.status, "Standard · needs 3 GB free")
            disk.script.free = total + 2_000_000_000
            short.fetch(.standard)
            await settle(short, clock) { $0 == .ready }
        }
    }

    func testADiskThatFillsPartWayIsSaidAndNotWaitedOut() async throws {
        try await run { clock, events in
            let disk = TestDisk()
            disk.script.failWrite = ENOSPC
            let transport = transport()
            let download = download(transport, disk: disk)
            download.fetch(.standard)
            await settle(download, clock) { self.isFailed($0) }
            XCTAssertEqual(download.state, .failed("ran out of disk space"))
            XCTAssertEqual(events.events(named: "download.retry").count, 0, "a full disk is not waited out")
            XCTAssertFalse(FileManager.default.fileExists(atPath: finalFolder.path))
        }
    }

    // MARK: - Failures

    func testAServerErrorIsRetriedAfterAWait() async throws {
        try await run { clock, events in
            let transport = transport(weights: [.status(503), .status(503), .serving(weightsResource)])
            let download = download(transport)
            download.fetch(.standard)
            await waitForRetries(1, events, clock)
            await settle(download, clock, .never) { $0 == .failed("could not be downloaded (503)") }
            XCTAssertEqual(download.status, "Standard · could not be downloaded (503)", "what Settings says while it waits")
            XCTAssertEqual(requests(transport, weightsRoute).count, 1)
            await settle(download, clock) { $0 == .ready }
            XCTAssertEqual(requests(transport, weightsRoute).count, 3)
        }
    }

    /// A 4xx is the server saying the request is wrong; asking again every
    /// five minutes for ever fixes nothing. It is said, once, as a failure
    /// the person can ask to retry from Settings.
    func testAClientErrorIsSaidAndNotRetried() async throws {
        for status in [400, 401, 403, 404, 410] {
            try await run { clock, _ in
                try? FileManager.default.removeItem(at: root)
                let transport = transport(weights: [.status(status)])
                let download = download(transport)
                download.fetch(.standard)
                await settle(download, clock) { self.isFailed($0) }
                XCTAssertEqual(download.state, .failed("could not be downloaded (\(status))"))
                await clock.advance(by: .seconds(3600))
                for _ in 0..<20 { await Task.yield() }
                XCTAssertEqual(requests(transport, weightsRoute).count, 1, "asked once: \(status)")
                XCTAssertEqual(clock.sleeperCount, 0, "nothing waits to ask again: \(status)")
            }
        }
    }

    func testAnUnpinnedFileIsAClientErrorToo() async throws {
        try await run { clock, _ in
            let transport = ScriptedTransport(unscripted: .status(404))
            let download = download(transport)
            download.fetch(.standard)
            await settle(download, clock) { self.isFailed($0) }
            XCTAssertEqual(download.state, .failed("could not be downloaded (404)"), "nothing is scripted: 404")
            XCTAssertEqual(transport.requestCount, 1, "and the first file's is the only ask")
        }
    }

    func testARateLimitAndATimeoutAreRetried() async throws {
        for status in [429, 408, 500, 502, 504] {
            try await run { clock, _ in
                try? FileManager.default.removeItem(at: root)
                let transport = transport(weights: [.status(status), .serving(weightsResource)])
                let download = download(transport)
                download.fetch(.standard)
                await settle(download, clock) { $0 == .ready }
                XCTAssertEqual(requests(transport, weightsRoute).count, 2, "\(status)")
            }
        }
    }

    func testALostConnectionIsPausedAndRetried() async throws {
        try await run { clock, events in
            let transport = transport(weights: [.failure(.networkConnectionLost), .serving(weightsResource)])
            let download = download(transport)
            download.fetch(.standard)
            await waitForRetries(1, events, clock)
            await settle(download, clock, .never) { $0 == .failed("download paused, retrying") }
            XCTAssertEqual(download.status, "Standard · download paused, retrying")
            await settle(download, clock) { $0 == .ready }
        }
    }

    /// The waits climb from ten seconds to the five-minute ceiling, jittered
    /// (half to all of each), for as long as nothing arrives.
    func testTheRetryWaitsClimbToFiveMinutesAndAreJittered() async throws {
        let schedule = EditorDownload.defaultRetrySchedule
        XCTAssertEqual(schedule.maximalDelays(limit: 5), [.seconds(10), .seconds(60), .seconds(300), .seconds(300), .seconds(300)])
        try await run { clock, events in
            let transport = transport(weights: [.status(503)] + Array(repeating: .status(503), count: 5) + [.serving(weightsResource)])
            let download = download(transport)
            download.fetch(.standard)
            var drawn: [Duration] = []
            for (index, ceiling) in [10.0, 60, 300, 300, 300, 300].enumerated() {
                await waitForRetries(index + 1, events, clock)
                let nap = try XCTUnwrap(clock.pendingDeadlines.first.map { clock.now.duration(to: $0) })
                drawn.append(nap)
                let seconds = Double(nap.components.seconds)
                XCTAssertLessThanOrEqual(seconds, ceiling, "wait \(index + 1)")
                XCTAssertGreaterThanOrEqual(seconds, ceiling / 2 - 1, "wait \(index + 1)")
                await clock.advance(to: try XCTUnwrap(clock.pendingDeadlines.first))
            }
            XCTAssertGreaterThan(Set(drawn[2...]).count, 1, "waits at the ceiling are not the same wait")
            await settle(download, clock) { $0 == .ready }
        }
    }

    /// A download that moves between cuts is never more than the first step
    /// behind.
    func testTheWaitStartsOverWhenBytesArrive() async throws {
        try await run { clock, events in
            let steps: [ScriptedTransport.Step] = [
                .status(503), .status(503),
                .serving(weightsResource, fault: .cut(after: 50_000)),
                .serving(weightsResource, fault: .cut(after: 50_000)),
                .serving(weightsResource),
            ]
            let download = download(transport(weights: steps))
            download.fetch(.standard)
            var naps: [Double] = []
            for index in 1...4 {
                await waitForRetries(index, events, clock)
                let deadline = try XCTUnwrap(clock.pendingDeadlines.first)
                naps.append(Double(clock.now.duration(to: deadline).components.seconds))
                await clock.advance(to: deadline)
            }
            XCTAssertLessThanOrEqual(naps[0], 10)
            XCTAssertLessThanOrEqual(naps[1], 60, "no bytes, so the second step")
            XCTAssertLessThanOrEqual(naps[2], 10, "bytes arrived: the first step again")
            XCTAssertLessThanOrEqual(naps[3], 10, "and again")
            await settle(download, clock) { $0 == .ready }
        }
    }

    func testAnOfflineMacWaitsForever() async throws {
        try await run { clock, events in
            let download = download(transport(weights: [.failure(.notConnectedToInternet)]))
            download.fetch(.standard)
            for index in 1...12 {
                await waitForRetries(index, events, clock)
                await clock.advance(by: .seconds(300))
            }
            await settle(download, clock, .never) { $0 == .failed("download paused, retrying") }
            XCTAssertEqual(download.status, "Standard · download paused, retrying", "it keeps trying; it never gives up")
        }
    }

    func testWaitingForAConnectionIsSaidOncePastTheGrace() async throws {
        try await run { clock, _ in
            let download = download(transport(weights: [.hang]), grace: .seconds(3))
            download.fetch(.standard)
            await clock.waitForSleepers(count: 2)
            for _ in 0..<50 { await Task.yield() }
            XCTAssertNotEqual(download.state, .waiting, "a request is always waiting for a moment: not said")
            await settle(download, clock, .always(step: .seconds(1))) { $0 == .waiting }
            XCTAssertEqual(download.status, "Standard · waiting for a connection that is not metered")
            download.cancel(keepingPartial: true)
        }
    }

    /// No deadline cuts a transfer that is progressing: three hours of it,
    /// on a link that gives thirty kilobytes a minute, arrive. (A download
    /// declared as a long operation with no deadline of its own would be cut
    /// at 90 seconds.)
    func testNoDeadlineCutsASlowTransfer() async throws {
        try await run { clock, _ in
            let slow = transport(weights: [.serving(weightsResource, chunkSize: 30_000, chunkDelay: .seconds(60))])
            let download = download(slow)
            download.fetch(.standard)
            await settle(download, clock, .always(step: .seconds(60))) { $0 == .ready }
            XCTAssertGreaterThan(clock.now.offset, .seconds(9 * 60), "ten chunks a minute apart")
            XCTAssertEqual(requests(slow, weightsRoute).count, 1, "one request, not cut and resumed")
        }
    }

    // MARK: - Placing

    func testAFinishedModelReplacesWhatWasThere() async throws {
        try await run { clock, _ in
            try FileManager.default.createDirectory(at: finalFolder, withIntermediateDirectories: true)
            try Data("stale".utf8).write(to: finalFolder.appendingPathComponent("old.txt"))
            let download = download(transport())
            download.fetch(.standard)
            await settle(download, clock) { $0 == .ready }
            XCTAssertEqual(try Data(contentsOf: finalFolder.appendingPathComponent("model.safetensors")), weights)
            XCTAssertFalse(FileManager.default.fileExists(atPath: finalFolder.appendingPathComponent("old.txt").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "and the old one is not left to be resumed into")
        }
    }

    func testAModelWhoseSwapCouldNotBeSyncedIsInPlaceAndTheOldOneIsCleared() async throws {
        try await run { clock, _ in
            try FileManager.default.createDirectory(at: finalFolder, withIntermediateDirectories: true)
            try Data("stale".utf8).write(to: finalFolder.appendingPathComponent("old.txt"))
            let disk = TestDisk()
            disk.script.failSyncAfterExchange = EIO
            let download = download(transport(), disk: disk)
            download.fetch(.standard)
            await settle(download, clock) { $0 == .ready }
            XCTAssertTrue(disk.script.exchanged)
            XCTAssertTrue(EditorModels.isComplete(finalFolder, manifest), "the new model is in place")
            XCTAssertFalse(FileManager.default.fileExists(atPath: finalFolder.appendingPathComponent("old.txt").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "the old model is not left to be resumed into")
        }
    }

    func testAModelThatCouldNotBeSwappedIsAFailureAndLeavesBothAsTheyWere() async throws {
        try await run { clock, _ in
            try FileManager.default.createDirectory(at: finalFolder, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: finalFolder.appendingPathComponent("old.txt"))
            let disk = TestDisk()
            disk.script.failExchange = ENOSPC
            let transport = transport()
            let download = download(transport, disk: disk)
            download.fetch(.standard)
            await settle(download, clock) { self.isFailed($0) }
            XCTAssertEqual(download.state, .failed("could not be put in place"))
            XCTAssertEqual(try Data(contentsOf: finalFolder.appendingPathComponent("old.txt")), Data("old".utf8), "the old model, whole")
            XCTAssertEqual(try Data(contentsOf: staging.appendingPathComponent("model.safetensors")), weights, "the new one, checked, kept")
            // The next try places what is there, and asks the server for nothing.
            disk.script.failExchange = nil
            let before = transport.requestCount
            download.fetch(.standard)
            await settle(download, clock) { $0 == .ready }
            XCTAssertEqual(transport.requestCount, before, "nothing fetched again")
            XCTAssertTrue(EditorModels.isComplete(finalFolder, manifest))
        }
    }

    func testAWholeModelIsNotFetchedAgain() async throws {
        try await run { clock, _ in
            let first = transport()
            let one = download(first)
            one.fetch(.standard)
            await settle(one, clock) { $0 == .ready }
            let second = transport()
            let two = download(second)
            two.fetch(.standard)
            await settle(two, clock) { $0 == .ready }
            XCTAssertEqual(second.requestCount, 0)
        }
    }

    // MARK: - Stopping

    func testTurningOffKeepsThePartialAndResumesFromIt() async throws {
        try await run { clock, _ in
            // Chunks of ten kilobytes a second apart, until thirty have arrived.
            let steps: [ScriptedTransport.Step] = [
                .serving(weightsResource, chunkSize: 10_000, chunkDelay: .seconds(1)), .serving(weightsResource),
            ]
            let first = transport(weights: steps)
            let download = download(first)
            download.fetch(.standard)
            await settle(download, clock, .always(step: .seconds(1))) {
                if case .downloading(let done, _) = $0 { return done >= 30_000 }
                return false
            }
            download.cancel(keepingPartial: true)
            let drained = expectation(description: "the cancel has let go")
            let kept = staging.appendingPathComponent("model.safetensors.partial.resume")
            Task { while FileManager.default.fileExists(atPath: kept.path) == false { await Task.yield() }; drained.fulfill() }
            await fulfillment(of: [drained], timeout: 10)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path), "off: kept to resume")
            XCTAssertEqual(download.state, .idle)

            // Turned on again, the same download takes up where it was.
            download.fetch(.standard)
            await settle(download, clock) { $0 == .ready }
            let range = requests(first, weightsRoute).dropFirst().first?.headers["Range"]
            let from = range.flatMap { Int($0.dropFirst("bytes=".count).dropLast()) } ?? 0
            XCTAssertGreaterThanOrEqual(from, 30_000, "it resumed from what had arrived: \(String(describing: range))")
            XCTAssertEqual(from % 10_000, 0)
            XCTAssertEqual(try Data(contentsOf: finalFolder.appendingPathComponent("model.safetensors")), weights)
        }
    }

    func testChoosingAnotherModelDeletesThePartial() async throws {
        try await run { clock, _ in
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try weights.prefix(1000).write(to: staging.appendingPathComponent("model.safetensors.partial"))
            let download = download(transport(weights: [.hang]))
            download.fetch(.standard)
            download.cancel()
            let gone = expectation(description: "gone")
            Task { while FileManager.default.fileExists(atPath: staging.path) { await Task.yield() }; gone.fulfill() }
            await fulfillment(of: [gone], timeout: 10)
            XCTAssertEqual(download.state, .idle)
            XCTAssertNil(download.status)
        }
    }

    func testAFetchAfterACancelDoesNotRaceItsClearing() async throws {
        try await run { clock, _ in
            let download = download(transport())
            download.fetch(.standard)
            download.cancel()
            download.fetch(.standard)
            await settle(download, clock) { $0 == .ready }
            XCTAssertTrue(EditorModels.isComplete(finalFolder, manifest))
        }
    }

    /// A cancelled fetch changes nothing, however late its last report.
    func testACancelledFetchSaysNothingMore() async throws {
        try await run { clock, _ in
            let transport = transport()
            let download = download(transport)
            var finished: [EditorEngine] = []
            download.finished = { finished.append($0) }
            download.fetch(.standard)
            download.cancel(keepingPartial: true)
            for _ in 0..<50 { await Task.yield() }
            XCTAssertEqual(download.state, .idle)
            XCTAssertTrue(finished.isEmpty)
        }
    }

    // MARK: - Words

    func testTheStatusSettingsShows() async throws {
        try await run { clock, _ in
            let download = download(transport())
            XCTAssertNil(download.status)
            download.fetch(.standard)
            XCTAssertEqual(download.status, "Standard · downloading 0.0 of 0.0 GB")
            await settle(download, clock) { $0 == .ready }
            XCTAssertNil(download.status, "ready says nothing: the model's own status does")
        }
    }

    func testTheWordsForWhatCanGoWrong() {
        let words = EditorDownload.words(for:placing:)
        XCTAssertEqual(words(DownloadError.insufficientSpace(required: 2_000_000_001, available: 0), false), "needs 3 GB free")
        XCTAssertEqual(words(DownloadError.insufficientSpace(required: 21_900_000_000, available: 0), false), "needs 22 GB free")
        XCTAssertEqual(words(DownloadError.digestMismatch(expected: try! .sha256(String(repeating: "a", count: 64)), actual: "b", attempts: 2), false),
                       "the download did not match, try again later")
        XCTAssertEqual(words(DownloadError.sizeMismatch(expected: 1, reported: 2), false), "the download did not match, try again later")
        XCTAssertEqual(words(DownloadError.http(.status(404, excerpt: "", retryAfter: nil, attempts: 1)), false), "could not be downloaded (404)")
        XCTAssertEqual(words(DownloadError.store(StoreError(kind: .diskFull, operation: "write")), false), "ran out of disk space")
        XCTAssertEqual(words(DownloadError.store(StoreError(kind: .ioFailure, operation: "write")), false), "could not be saved")
        XCTAssertEqual(words(DownloadError.store(StoreError(kind: .diskFull, operation: "exchange")), true), "could not be put in place")
        XCTAssertEqual(words(DownloadError.deadlineExceeded, false), "could not be downloaded")
    }

    // MARK: - The pins

    func testThePinnedManifestsAreWhatTheFixtureWasRecordedAgainst() {
        XCTAssertEqual(EditorManifest.standard.revision, "238767527555cb75a05732a84dff5d6ba0dd6809")
        XCTAssertEqual(EditorManifest.full.revision, "38740b847e4cb78f352aba30aa41c76e08e6eb46")
        XCTAssertEqual(EditorManifest.standard.total, 3_583_086_498)
        XCTAssertEqual(EditorManifest.full.total, 20_429_166_969)
        XCTAssertNil(EditorManifest.forEngine(.spelling))
        XCTAssertNil(EditorManifest.forEngine(.minimal))
        XCTAssertEqual(EditorManifest.standard.url(for: EditorManifest.standard.files[1]).absoluteString,
                       "https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit/resolve/238767527555cb75a05732a84dff5d6ba0dd6809/config.json")
    }

    /// Every pin is a digest the downloader accepts, of the kind Hugging Face
    /// names the file by: a bad hex string would be a download that verifies
    /// nothing, and cannot be made.
    func testEveryPinnedFileIsADigestTheDownloaderChecks() throws {
        let root = URL(fileURLWithPath: "/models")
        for manifest in [EditorManifest.standard, .full] {
            let bundle = try manifest.bundle(in: root)
            XCTAssertEqual(bundle.destination, "/models/\(manifest.folder)")
            XCTAssertEqual(bundle.stagingPath, "/models/.\(manifest.folder).partial", "the folder an earlier build staged in")
            XCTAssertEqual(bundle.fileMode, 0o644)
            XCTAssertEqual(bundle.files.map(\.path), manifest.files.map(\.path))
            for (pinned, file) in zip(manifest.files, bundle.files) {
                XCTAssertEqual(file.expectedSize, Int(pinned.size))
                XCTAssertEqual(file.digest?.algorithm, pinned.sha256 != nil ? .sha256 : .gitBlobSHA1, pinned.path)
                XCTAssertEqual(file.digest?.hex, pinned.sha256 ?? pinned.gitSHA1)
                XCTAssertEqual(file.request.url, manifest.url(for: pinned))
            }
        }
    }

    func testTheSessionIsTheOneTheDownloadAlwaysHad() {
        let configuration = EditorDownload.sessionConfiguration()
        XCTAssertTrue(configuration.waitsForConnectivity)
        XCTAssertFalse(configuration.allowsExpensiveNetworkAccess)
        XCTAssertFalse(configuration.allowsConstrainedNetworkAccess)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 60)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(configuration.urlCache)
        let policy = EditorDownload.retryPolicy
        XCTAssertEqual(policy.verificationAttempts, 2, "one refetch after a mismatch")
        XCTAssertEqual(policy.progressInterval, .milliseconds(500))
    }

    func testOneModelIsKeptOnDisk() throws {
        for folder in ["gemma-4-e2b-it-4bit", "Qwen3.6-35B-A3B-4bit"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        EditorModels.removeAll(except: .full, root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("gemma-4-e2b-it-4bit").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Qwen3.6-35B-A3B-4bit").path))
    }

    // MARK: - What the build before left

    /// The folder an earlier build left: files part-way at their own names,
    /// no record. The gigabytes in it are resumed, not fetched again.
    func testAPartialLeftByTheEarlierBuildIsResumed() async throws {
        try await run { clock, _ in
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try config.write(to: staging.appendingPathComponent("config.json"))
            try weights.prefix(100_000).write(to: staging.appendingPathComponent("model.safetensors"))
            let transport = transport()
            let download = download(transport)
            download.fetch(.standard)
            await settle(download, clock) { $0 == .ready }
            XCTAssertEqual(requests(transport, configRoute).count, 0, "the whole file was checked, not fetched")
            let weightRequests = requests(transport, weightsRoute)
            XCTAssertEqual(weightRequests.count, 1)
            XCTAssertEqual(weightRequests.first?.headers["Range"], "bytes=100000-", "the rest, not the lot")
            XCTAssertEqual(try Data(contentsOf: finalFolder.appendingPathComponent("model.safetensors")), weights)
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        }
    }

    /// An earlier build wrote no checksum of what it had: its bytes are
    /// believed only until the digest says otherwise.
    func testAnEarlierPartialThatWasWrongIsFetchedAgainFromTheStart() async throws {
        try await run { clock, _ in
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            var wrong = Data(weights.prefix(100_000))
            wrong[10] ^= 0xFF
            try wrong.write(to: staging.appendingPathComponent("model.safetensors"))
            let transport = transport()
            let download = download(transport)
            download.fetch(.standard)
            await settle(download, clock) { $0 == .ready }
            let ranges = requests(transport, weightsRoute).map { $0.headers["Range"] }
            XCTAssertEqual(ranges.count, 2)
            XCTAssertEqual(ranges.first ?? "", "bytes=100000-")
            XCTAssertNil(ranges.last ?? nil, "then the whole file")
            XCTAssertEqual(try Data(contentsOf: finalFolder.appendingPathComponent("model.safetensors")), weights)
        }
    }

    func testAnEarlierFileLargerThanItShouldBeIsRemovedNotResumed() async throws {
        try await run { clock, _ in
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try (weights + Data(count: 10)).write(to: staging.appendingPathComponent("model.safetensors"))
            let transport = transport()
            let download = download(transport)
            download.fetch(.standard)
            await settle(download, clock) { $0 == .ready }
            XCTAssertNil(requests(transport, weightsRoute).first?.headers["Range"])
            XCTAssertEqual(try Data(contentsOf: finalFolder.appendingPathComponent("model.safetensors")), weights)
        }
    }
}

/// The real thing, on demand: Standard's 3.6 GB from Hugging Face into a
/// scratch folder, checked, loaded by MLX and asked a sentence.
///
///     LODESTAR_EDITOR_DOWNLOAD=standard swift test --filter EditorDownloadLiveTests
final class EditorDownloadLiveTests: XCTestCase {
    func testARealModelDownloadsLoadsAndAnswers() async throws {
        guard let name = ProcessInfo.processInfo.environment["LODESTAR_EDITOR_DOWNLOAD"],
              let engine = EditorEngine(rawValue: name), let manifest = EditorManifest.forEngine(engine) else {
            throw XCTSkip("LODESTAR_EDITOR_DOWNLOAD=standard downloads the real model")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let download = await MainActor.run { EditorDownload(root: root) }
        let started = Date()
        await MainActor.run { download.fetch(engine) }
        while await MainActor.run(body: { download.state != .ready }) {
            if case .failed(let why) = await MainActor.run(body: { download.state }), !why.contains("retrying") {
                XCTFail(why); return
            }
            try await Task.sleep(for: .seconds(1))
            XCTAssertLessThan(Date().timeIntervalSince(started), 1800, "a half hour is too long")
        }
        let seconds = Date().timeIntervalSince(started)
        print("editor download · \(engine.rawValue) · \(manifest.total / 1_000_000) MB in \(Int(seconds)) s")
        let folder = root.appendingPathComponent(manifest.folder)
        XCTAssertTrue(EditorModels.isComplete(folder, manifest))
        let model = EditorModel(engine: engine, loader: { _ in
            try await EditorModel.load(fromDirectory: folder, engine: engine)
        })
        let answer = await model.correct("Their going to push it.")
        XCTAssertEqual(answer, "They're going to push it.")
    }
}

final class EditorModelRemovalTests: XCTestCase {
    /// Switching to an engine with no download clears Lodestar's own
    /// model folders, partials included, and says how much it freed.
    func testSwitchingAwayRemovesTheModelsFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remove-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let full = root.appendingPathComponent("Qwen3.6-35B-A3B-4bit")
        let partial = root.appendingPathComponent(".gemma-4-e2b-it-4bit.partial")
        for folder in [full, partial] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(count: 2_000_000).write(to: folder.appendingPathComponent("model.safetensors"))
        }
        let removed = EditorModels.removeAll(except: .spelling, root: root)
        XCTAssertEqual(removed.map(\.0), [.full], "the whole model is reported; a partial just goes")
        XCTAssertEqual(removed.first?.1 ?? 0, 0.002, accuracy: 0.0005)
        XCTAssertFalse(FileManager.default.fileExists(atPath: full.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }
}
