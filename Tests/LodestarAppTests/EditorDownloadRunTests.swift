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

/// The main thread's queue, held by the test: what the download hands to the
/// main thread waits here until the test says. A report that is on its way to
/// the main thread when a fetch is cancelled or replaced is then a thing a test
/// can arrange, rather than a race it hopes to win.
final class HeldMain: @unchecked Sendable {
    // stoic:allow(unchecked-sendable): a lock guards the queue
    private let lock = NSLock()
    private var blocks: [@Sendable () -> Void] = []

    var count: Int { lock.withLock { blocks.count } }

    func hold(_ block: @escaping @Sendable () -> Void) { lock.withLock { blocks.append(block) } }

    /// Runs the first `count` held blocks (all of them by default), in order.
    @MainActor func release(_ count: Int? = nil) {
        let run: [@Sendable () -> Void] = lock.withLock {
            let take = min(count ?? blocks.count, blocks.count)
            defer { blocks.removeFirst(take) }
            return Array(blocks.prefix(take))
        }
        for block in run { block() }
    }
}

/// The states a download passes through and what it tells its owner, as a
/// download goes from one model to the next, is cancelled, fails and is asked
/// again, with the reports that come late from a run that is over.
///
/// What a person sees in Settings, and when the editor takes a model up,
/// follows from this order; each test pins one transition.
@MainActor
final class EditorDownloadRunTests: XCTestCase {
    private var root: URL!
    private var events = RecordingInstrumentation()
    private let weights = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    private let otherWeights = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 17) })
    private let config = Data(#"{"model_type":"test"}"#.utf8)

    private func route(_ repo: String, _ revision: String, _ file: String) -> HTTPRequest {
        .get(URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file)")!)
    }
    private var weightsRoute: HTTPRequest { route("test/tiny-model", "abc123", "model.safetensors") }
    private var otherWeightsRoute: HTTPRequest { route("test/other-model", "def456", "model.safetensors") }

    private func manifest(_ repo: String, _ revision: String, _ body: Data) -> EditorManifest {
        EditorManifest(repo: repo, revision: revision, files: [
            .init(path: "config.json", size: Int64(config.count), gitSHA1: EditorDownloadTests.gitSHA1(config)),
            .init(path: "model.safetensors", size: Int64(body.count),
                  sha256: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()),
        ])
    }
    /// The model the editor's Standard fetches here, and the one its Full does.
    private var tiny: EditorManifest { manifest("test/tiny-model", "abc123", weights) }
    private var other: EditorManifest { manifest("test/other-model", "def456", otherWeights) }

    private var finalFolder: URL { root.appendingPathComponent("tiny-model", isDirectory: true) }
    private var staging: URL { root.appendingPathComponent(".tiny-model.partial", isDirectory: true) }
    private var otherFolder: URL { root.appendingPathComponent("other-model", isDirectory: true) }

    private let standard = ModelID.editor(.standard)
    private let full = ModelID.editor(.full)

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private var weightsResource: ScriptedTransport.Resource { .init([UInt8](weights), etag: "\"w1\"") }
    private var otherResource: ScriptedTransport.Resource { .init([UInt8](otherWeights), etag: "\"o1\"") }
    /// Ten kilobytes a second: thirty seconds of virtual time for the tiny model.
    private var slow: ScriptedTransport.Step { .serving(weightsResource, chunkSize: 10_000, chunkDelay: .seconds(1)) }

    private func transport(weights steps: [ScriptedTransport.Step]? = nil,
                           other otherSteps: [ScriptedTransport.Step]? = nil) -> ScriptedTransport {
        let transport = ScriptedTransport()
        let configResource = ScriptedTransport.Resource([UInt8](config), etag: "\"c1\"")
        transport.on(route("test/tiny-model", "abc123", "config.json"), respond: [.serving(configResource)])
        transport.on(weightsRoute, respond: steps ?? [.serving(weightsResource)])
        transport.on(route("test/other-model", "def456", "config.json"), respond: [.serving(configResource)])
        transport.on(otherWeightsRoute, respond: otherSteps ?? [.serving(otherResource)])
        return transport
    }

    private func download(_ transport: ScriptedTransport, grace: Duration = .seconds(3600),
                          held: HeldMain? = nil) -> EditorDownload {
        let (tiny, other) = (self.tiny, self.other)
        let manifests: (ModelID) -> EditorManifest? = { id in
            switch id {
            case .editor(.standard), .ear(.standard), .cleanup(.gemma): return tiny
            case .editor(.full): return other
            default: return nil
            }
        }
        if let held {
            return EditorDownload(root: root, transport: transport, manifests: manifests, waitingGrace: grace,
                                  onMain: { held.hold($0) })
        }
        return EditorDownload(root: root, transport: transport, manifests: manifests, waitingGrace: grace)
    }

    private func run(_ body: (TestClock) async throws -> Void) async throws {
        let clock = TestClock()
        events = RecordingInstrumentation()
        try await withTestAmbient(clock: clock, events: events) { try await body(clock) }
    }

    /// Lets the clock run on, a second a time, until `done`. Real time only
    /// bounds a test that never gets there.
    private func drive(_ clock: TestClock, step: Duration = .seconds(1), until done: () -> Bool,
                       file: StaticString = #filePath, line: UInt = #line) async {
        let limit = ContinuousClock.now.advanced(by: .seconds(30))
        while !done(), ContinuousClock.now < limit {
            if clock.sleeperCount > 0 { await clock.advance(by: step) }
            await Task.yield()
        }
        XCTAssertTrue(done(), "stuck", file: file, line: line)
    }

    private func settle(_ clock: TestClock, _ download: EditorDownload, held: HeldMain? = nil,
                        until done: (EditorDownload.State) -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        await drive(clock, until: { held?.release(); return done(download.state) }, file: file, line: line)
    }

    private func yields(_ count: Int = 100) async { for _ in 0..<count { await Task.yield() } }

    private func waitForRetries(_ count: Int, _ clock: TestClock) async {
        let limit = ContinuousClock.now.advanced(by: .seconds(30))
        while events.events(named: "download.retry").count < count, ContinuousClock.now < limit { await Task.yield() }
        await clock.waitForSleepers()
    }

    private func gone(_ url: URL) async {
        let limit = ContinuousClock.now.advanced(by: .seconds(30))
        while FileManager.default.fileExists(atPath: url.path), ContinuousClock.now < limit { await Task.yield() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "\(url.lastPathComponent) is gone")
    }

    private func downloading(_ done: Int64 = 0, of manifest: EditorManifest? = nil) -> EditorDownload.State {
        .downloading(done: done, total: (manifest ?? tiny).total)
    }

    private func isFailed(_ state: EditorDownload.State) -> Bool { if case .failed = state { return true } else { return false } }

    /// What the owner saw, in the order it saw it.
    private final class Seen {
        var log: [String] = []
        var states: [String] { log.filter { $0.hasPrefix("state ") } }
        var finished: [String] { log.filter { $0.hasPrefix("finished ") } }
        init(_ download: EditorDownload) {
            download.changed = { [unowned self, unowned download] in log.append("state \(download.state)") }
            download.finished = { [unowned self] in log.append("finished \($0)") }
            download.finishedEar = { [unowned self] in log.append("finishedEar \($0)") }
            download.finishedCleanup = { [unowned self] in log.append("finishedCleanup \($0)") }
        }
    }

    // MARK: - Arriving

    /// Ready is said once, after the state has moved to it, and asking again
    /// for the model that is whole starts nothing.
    func testReadyIsSaidOnceAfterTheStateMovedAndAskingAgainChangesNothing() async throws {
        try await run { clock in
            let transport = transport()
            let download = download(transport)
            let seen = Seen(download)
            download.fetch(standard)
            XCTAssertEqual(download.state, downloading(), "said the moment it is asked for")
            XCTAssertEqual(download.model, standard)
            XCTAssertEqual(download.engine, .standard)
            await settle(clock, download) { $0 == .ready }
            await yields()
            XCTAssertEqual(seen.log.first, "state \(downloading())")
            XCTAssertEqual(Array(seen.log.suffix(2)), ["state ready", "finished standard"])
            XCTAssertEqual(seen.finished, ["finished standard"], "once")
            XCTAssertEqual(seen.states.filter { $0 == "state ready" }.count, 1)
            XCTAssertTrue(seen.states.contains("state verifying"))
            XCTAssertLessThan(try XCTUnwrap(seen.states.firstIndex(of: "state verifying")),
                              try XCTUnwrap(seen.states.firstIndex(of: "state ready")), "checked, then ready")
            for (before, after) in zip(seen.states, seen.states.dropFirst()) {
                XCTAssertNotEqual(before, after, "a state that did not change is not said")
            }
            XCTAssertEqual(download.model, standard, "ready keeps the model it is of")
            XCTAssertNil(download.status)

            let (logged, requests) = (seen.log.count, transport.requestCount)
            download.fetch(standard)
            await yields()
            XCTAssertEqual(download.state, .ready)
            XCTAssertEqual(seen.log.count, logged, "nothing said again")
            XCTAssertEqual(transport.requestCount, requests, "nothing asked of the server")
        }
    }

    /// The model that arrived is told to the callback of its own kind.
    func testEachKindOfModelIsToldToItsOwnCallback() async throws {
        try await run { clock in
            for (id, expected) in [(ModelID.editor(.standard), "finished standard"),
                                   (.ear(.standard), "finishedEar standard"),
                                   (.cleanup(.gemma), "finishedCleanup gemma")] {
                try? FileManager.default.removeItem(at: root)
                let download = download(transport())
                let seen = Seen(download)
                download.fetch(id)
                XCTAssertEqual(download.model, id)
                await settle(clock, download) { $0 == .ready }
                await yields()
                XCTAssertEqual(seen.log.filter { !$0.hasPrefix("state ") }, [expected], "\(id)")
            }
        }
    }

    // MARK: - A second request

    /// Asked for the model already on its way, the download carries on: it is
    /// not started over, not told again, and the server is asked once.
    func testAskingAgainForTheModelOnItsWayChangesNothing() async throws {
        try await run { clock in
            let transport = transport(weights: [slow])
            let download = download(transport)
            let seen = Seen(download)
            download.fetch(standard)
            await drive(clock) { if case .downloading(let done, _) = download.state { return done >= 30_000 }; return false }
            let (state, logged) = (download.state, seen.log.count)
            download.fetch(standard)
            XCTAssertEqual(download.state, state, "not back to nothing fetched")
            XCTAssertEqual(seen.log.count, logged)
            await settle(clock, download) { $0 == .ready }
            XCTAssertEqual(transport.requests(to: weightsRoute).count, 1, "one request, not two")
            XCTAssertEqual(seen.finished, ["finished standard"])
        }
    }

    /// Waiting for a connection is on its way too.
    func testAskingAgainWhileWaitingForAConnectionChangesNothing() async throws {
        try await run { clock in
            let download = download(transport(weights: [.hang]), grace: .seconds(3))
            let seen = Seen(download)
            download.fetch(standard)
            await drive(clock) { download.state == .waiting }
            let logged = seen.log.count
            download.fetch(standard)
            XCTAssertEqual(download.state, .waiting)
            XCTAssertEqual(seen.log.count, logged)
            download.cancel(keepingPartial: true)
        }
    }

    /// Another model replaces it: the first is stopped and its partial files
    /// go, the second starts from nothing, and only the second is ever done.
    func testAnotherModelReplacesTheOneOnItsWayAndItsPartialGoes() async throws {
        try await run { clock in
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try weights.prefix(1000).write(to: staging.appendingPathComponent("model.safetensors.partial"))
            let transport = transport(weights: [slow])
            let download = download(transport)
            let seen = Seen(download)
            download.fetch(standard)
            await drive(clock) { if case .downloading(let done, _) = download.state { return done >= 30_000 }; return false }
            download.fetch(full)
            XCTAssertEqual(download.state, downloading(of: other), "the second, from nothing")
            XCTAssertEqual(download.model, full)
            XCTAssertEqual(download.engine, .full)
            XCTAssertEqual(download.status, "Full · downloading 0.0 of 0.0 GB")
            await gone(staging)
            await settle(clock, download) { $0 == .ready }
            await yields()
            XCTAssertEqual(seen.finished, ["finished full"], "the first was never done")
            XCTAssertTrue(EditorModels.isComplete(otherFolder, other))
            XCTAssertFalse(FileManager.default.fileExists(atPath: finalFolder.path))
            XCTAssertEqual(transport.requests(to: weightsRoute).count, 1, "the first was not asked for again")
        }
    }

    /// A model it has no files for is not fetched; the one on its way is still
    /// stopped, for another was asked for.
    func testAModelWithNoFilesStartsNothingAndStopsTheOneOnItsWay() async throws {
        try await run { clock in
            let idle = download(transport())
            let idleSeen = Seen(idle)
            idle.fetch(.editor(.minimal))
            XCTAssertEqual(idle.state, .idle)
            XCTAssertNil(idle.model)
            XCTAssertTrue(idleSeen.log.isEmpty)

            let transport = transport(weights: [slow])
            let download = download(transport)
            let seen = Seen(download)
            download.fetch(standard)
            await drive(clock) { if case .downloading(let done, _) = download.state { return done >= 30_000 }; return false }
            download.fetch(.editor(.minimal))
            XCTAssertEqual(download.state, .idle)
            XCTAssertNil(download.model)
            XCTAssertNil(download.status)
            XCTAssertEqual(seen.states.last, "state idle")
            await gone(staging)
            let logged = seen.log.count
            for _ in 0..<20 { if clock.sleeperCount > 0 { await clock.advance(by: .seconds(1)) }; await Task.yield() }
            XCTAssertEqual(seen.log.count, logged, "and nothing after")
            XCTAssertEqual(transport.requests(to: weightsRoute).count, 1)
        }
    }

    // MARK: - Stopping

    /// Cancelled while it downloads: idle at once, said once, no model, the
    /// partial files deleted, and nothing more from the run.
    func testCancelDuringTheDownloadStopsItAndSaysNothingMore() async throws {
        try await run { clock in
            let transport = transport(weights: [slow])
            let download = download(transport)
            let seen = Seen(download)
            download.fetch(standard)
            await drive(clock) { if case .downloading(let done, _) = download.state { return done >= 30_000 }; return false }
            download.cancel()
            XCTAssertEqual(download.state, .idle)
            XCTAssertNil(download.model)
            XCTAssertNil(download.engine)
            XCTAssertNil(download.status)
            XCTAssertEqual(seen.states.last, "state idle")
            XCTAssertEqual(seen.states.filter { $0 == "state idle" }.count, 1)
            await gone(staging)
            let logged = seen.log.count
            for _ in 0..<40 { if clock.sleeperCount > 0 { await clock.advance(by: .seconds(1)) }; await Task.yield() }
            XCTAssertEqual(seen.log.count, logged, "the run said nothing after the cancel")
            XCTAssertTrue(seen.finished.isEmpty)
            XCTAssertEqual(transport.requests(to: weightsRoute).count, 1, "and did not start again")
        }
    }

    /// Cancelling a model that arrived forgets it was of that model, and
    /// asking again says it arrived again: once for each time it was asked.
    func testCancelAfterReadyForgetsTheModelAndAskingAgainIsDoneAgain() async throws {
        try await run { clock in
            let transport = transport()
            let download = download(transport)
            let seen = Seen(download)
            download.fetch(standard)
            await settle(clock, download) { $0 == .ready }
            await yields()
            download.cancel()
            XCTAssertEqual(download.state, .idle)
            XCTAssertNil(download.model)
            XCTAssertEqual(seen.states.last, "state idle")
            XCTAssertEqual(seen.finished.count, 1, "cancelling does not say it arrived")
            let requests = transport.requestCount
            download.fetch(standard)
            await settle(clock, download) { $0 == .ready }
            await yields()
            XCTAssertEqual(seen.finished, ["finished standard", "finished standard"])
            XCTAssertEqual(transport.requestCount, requests, "it was whole: nothing fetched")
        }
    }

    /// A cancel with nothing on its way says nothing.
    func testCancelWithNothingOnItsWayChangesNothing() async throws {
        try await run { _ in
            let download = download(transport())
            let seen = Seen(download)
            download.cancel()
            download.cancel(keepingPartial: true)
            await yields()
            XCTAssertEqual(download.state, .idle)
            XCTAssertTrue(seen.log.isEmpty)
        }
    }

    /// A fetch cancelled before its work began asks the server for nothing.
    func testAFetchCancelledBeforeItsWorkBeganAsksForNothing() async throws {
        try await run { clock in
            let transport = transport()
            let download = download(transport)
            let seen = Seen(download)
            download.fetch(standard)
            download.cancel(keepingPartial: true)
            await yields()
            for _ in 0..<10 { if clock.sleeperCount > 0 { await clock.advance(by: .seconds(1)) }; await Task.yield() }
            XCTAssertEqual(transport.requestCount, 0)
            XCTAssertEqual(seen.states, ["state \(downloading())", "state idle"])
            XCTAssertTrue(seen.finished.isEmpty)
        }
    }

    // MARK: - Failing, and again

    /// A failure that cannot improve is said and kept; asking again begins from
    /// downloading, at once, and goes on to the end.
    func testAFailureIsKeptUntilItIsAskedAgainAndThenItGoesOn() async throws {
        try await run { clock in
            let transport = transport(weights: [.status(404), .serving(weightsResource)])
            let download = download(transport)
            let seen = Seen(download)
            download.fetch(standard)
            await settle(clock, download) { self.isFailed($0) }
            await yields()
            XCTAssertEqual(download.state, .failed("could not be downloaded (404)"))
            XCTAssertEqual(download.model, standard, "still that model's")
            XCTAssertEqual(download.status, "Standard · could not be downloaded (404)")
            XCTAssertTrue(seen.finished.isEmpty)
            XCTAssertEqual(seen.states.first, "state \(downloading())")
            XCTAssertEqual(seen.states.last, "state failed(\"could not be downloaded (404)\")")
            XCTAssertEqual(seen.states.filter { $0.hasPrefix("state failed") || $0 == "state ready" || $0 == "state idle" }.count, 1,
                           "one end, and it is the failure: \(seen.states)")

            download.fetch(standard)
            XCTAssertEqual(download.state, downloading(), "at once, before anything is heard")
            await settle(clock, download) { $0 == .ready }
            await yields()
            XCTAssertEqual(seen.finished, ["finished standard"], "once, for the second try")
            XCTAssertEqual(transport.requests(to: weightsRoute).count, 2)
            XCTAssertEqual(seen.states.filter { $0 == "state ready" }.count, 1)
        }
    }

    // MARK: - Reports that come late

    /// What the downloader said just before the cancel is on its way to the
    /// main thread when the cancel happens, and changes nothing there.
    func testProgressOnItsWayWhenTheFetchIsCancelledChangesNothing() async throws {
        try await run { clock in
            let held = HeldMain()
            let download = download(transport(weights: [slow]), held: held)
            let seen = Seen(download)
            download.fetch(standard)
            await drive(clock) { held.count >= 3 }
            download.cancel(keepingPartial: true)
            XCTAssertEqual(download.state, .idle)
            let logged = seen.log.count
            held.release()
            XCTAssertEqual(download.state, .idle, "what was on its way did not move it")
            XCTAssertNil(download.status)
            XCTAssertEqual(seen.log.count, logged)
            for _ in 0..<20 { if clock.sleeperCount > 0 { await clock.advance(by: .seconds(1)) }; await Task.yield() }
            held.release()
            XCTAssertEqual(download.state, .idle)
            XCTAssertEqual(seen.log.count, logged)
            XCTAssertTrue(seen.finished.isEmpty)
        }
    }

    /// A run that got to the end, its "ready" not yet heard, and was then
    /// cancelled: the model was not turned on by it.
    func testADoneOnItsWayWhenTheFetchIsCancelledIsNotToldToTheOwner() async throws {
        try await run { clock in
            let held = HeldMain()
            let download = download(transport(), held: held)
            let seen = Seen(download)
            download.fetch(standard)
            await drive(clock) { EditorModels.isComplete(self.finalFolder, self.tiny) }
            await yields(300)
            XCTAssertGreaterThan(held.count, 0)
            download.cancel()
            await yields()
            held.release()
            XCTAssertEqual(download.state, .idle)
            XCTAssertNil(download.model)
            XCTAssertTrue(seen.finished.isEmpty, "\(seen.log)")
            XCTAssertEqual(seen.states, ["state \(downloading())", "state idle"])
        }
    }

    /// The same, when another model was asked for instead: the first's "ready"
    /// is not the second's, and the second is told once, when it is done.
    func testADoneOnItsWayWhenAnotherModelIsAskedForIsNotToldToTheOwner() async throws {
        try await run { clock in
            let held = HeldMain()
            let download = download(transport(), held: held)
            let seen = Seen(download)
            download.fetch(standard)
            await drive(clock) { EditorModels.isComplete(self.finalFolder, self.tiny) }
            await yields(300)
            let first = held.count
            XCTAssertGreaterThan(first, 0)
            download.fetch(full)
            let logged = seen.log.count
            held.release(first)
            XCTAssertEqual(download.state, downloading(of: other), "the first's reports did not move the second")
            XCTAssertEqual(seen.log.count, logged)
            XCTAssertTrue(seen.finished.isEmpty)
            await settle(clock, download, held: held) { $0 == .ready }
            held.release()
            XCTAssertEqual(seen.finished, ["finished full"], "\(seen.log)")
        }
    }

    /// A failure said by the run that was replaced, on its way when the same
    /// model was asked for again, does not undo the new run's start.
    func testAReportOnItsWayWhenTheSameModelIsAskedAgainChangesNothing() async throws {
        try await run { clock in
            let held = HeldMain()
            let transport = transport(weights: [.status(503), slow, .serving(weightsResource)])
            let download = download(transport, held: held)
            let seen = Seen(download)
            download.fetch(standard)
            await waitForRetries(1, clock)
            held.release()
            XCTAssertEqual(download.state, .failed("could not be downloaded (503)"))
            // The wait is over: the run goes on, slowly, and says what it gets.
            await clock.advance(by: .seconds(300))
            await drive(clock) { held.count >= 3 }
            download.fetch(standard)
            XCTAssertEqual(download.state, downloading(), "asked again")
            let logged = seen.log.count
            held.release()
            XCTAssertEqual(download.state, downloading(), "what the first run had said was dropped")
            XCTAssertEqual(seen.log.count, logged)
            await settle(clock, download, held: held) { $0 == .ready }
            held.release()
            XCTAssertEqual(seen.finished, ["finished standard"], "once")
            XCTAssertEqual(seen.states.filter { $0.hasPrefix("state failed") }.count, 1, "only the first run's own failure")
        }
    }

    /// "Waiting for a connection" is said after a grace; a grace that ends
    /// after the fetch was cancelled does not say it.
    func testAGraceThatEndsAfterTheFetchWasCancelledSaysNothing() async throws {
        try await run { clock in
            let download = download(transport(weights: [.hang]), grace: .seconds(3))
            let seen = Seen(download)
            download.fetch(standard)
            await clock.waitForSleepers(count: 2)
            await yields()
            download.cancel(keepingPartial: true)
            let logged = seen.log.count
            for _ in 0..<10 { if clock.sleeperCount > 0 { await clock.advance(by: .seconds(1)) }; await Task.yield() }
            XCTAssertEqual(download.state, .idle)
            XCTAssertNil(download.status)
            XCTAssertEqual(seen.log.count, logged)
        }
    }
}
