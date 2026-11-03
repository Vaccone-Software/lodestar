import Foundation
import Stoic
import StoicDownloads
import StoicHTTP
import StoicStore
import StoicTesting
import XCTest
@testable import LodestarCore

/// The update's zip: the feeds' digest, and the download that checks it, on a
/// scripted GitHub and a clock the test moves.
final class UpdateDownloadTests: XCTestCase {
    private var directory: URL!
    private let zip = [UInt8]((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
    private let route = HTTPRequest.get(URL(string: "https://github.com/Vaccone-Software/lodestar/releases/download/v9.9.9/lodestar-9.9.9.zip")!)

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("update-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private var destination: URL { directory.appendingPathComponent("download.zip") }

    private func release(digest: String?) -> Updater.Release {
        Updater.Release(tag: "v9.9.9", version: [9, 9, 9], zipName: "lodestar-9.9.9.zip",
                        zipURL: "https://github.com/Vaccone-Software/lodestar/releases/download/v9.9.9/lodestar-9.9.9.zip",
                        zipDigest: digest)
    }

    private var goodDigest: String { "sha256:" + ContentDigest(algorithm: .sha256, of: zip).hex }
    private var resource: ScriptedTransport.Resource { .init(zip, etag: "\"z1\"") }

    private func transport(_ steps: [ScriptedTransport.Step]) -> ScriptedTransport {
        let transport = ScriptedTransport()
        transport.on(route, respond: steps)
        return transport
    }

    private func fetch(_ release: Updater.Release, _ transport: ScriptedTransport,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> DownloadResult {
        try await UpdateDownload.fetch(release, to: destination, client: UpdateDownload.client(transport: transport),
                                       progress: progress)
    }

    private func run(_ body: (TestClock, RecordingInstrumentation) async throws -> Void) async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        try await withTestAmbient(clock: clock, events: events) { try await body(clock, events) }
    }

    /// Moves the clock `step` whenever something is asleep for exactly that
    /// long, until `finished`: a body that arrives a chunk at a time, each chunk
    /// `step` after the last. A request's own timeout (thirty seconds, while the
    /// answer is awaited) sleeps too, and a leap over it would end a request
    /// that was about to be answered, so it is never what is advanced to.
    private func drive(_ clock: TestClock, chunks step: Duration, until finished: () -> Bool) async {
        let limit = ContinuousClock.now.advanced(by: .seconds(30))
        while !finished(), ContinuousClock.now < limit {
            if clock.pendingDeadlines.contains(where: { clock.now.duration(to: $0) == step }) { await clock.advance(by: step) }
            await Task.yield()
        }
    }

    /// Waits for the downloader to say it is waiting out a failure: its request
    /// is over, and what it sleeps on is the backoff.
    private func waitForRetry(_ events: RecordingInstrumentation, _ clock: TestClock) async {
        let limit = ContinuousClock.now.advanced(by: .seconds(30))
        while events.events(named: "download.retry").isEmpty, ContinuousClock.now < limit { await Task.yield() }
        await clock.waitForSleepers()
    }

    // MARK: - What the feeds say

    func testThePreviewFeedCarriesGitHubsDigestOfTheZip() throws {
        let hex = String(repeating: "ab", count: 32)
        let url = "https://github.com/Vaccone-Software/lodestar/releases/download/v0.9.9/lodestar-0.9.9.zip"
        let release = try XCTUnwrap(Updater.parseFeed(Data("""
        [{"tag_name": "v0.9.9", "draft": false, "assets": [
            {"name": "lodestar-0.9.9.dmg", "browser_download_url": "https://example.com/a.dmg", "digest": "sha256:\(String(repeating: "cd", count: 32))"},
            {"name": "lodestar-0.9.9.zip", "browser_download_url": "\(url)", "digest": "sha256:\(hex)"}
        ]}]
        """.utf8)))
        XCTAssertEqual(release.zipDigest, "sha256:\(hex)", "the zip's, not the dmg's")
        XCTAssertEqual(UpdateDownload.digest(of: release)?.hex, hex)
    }

    func testAPreviewZipWithoutASha256IsNotARelease() {
        let url = "https://github.com/Vaccone-Software/lodestar/releases/download/v0.9.9/lodestar-0.9.9.zip"
        for asset in [#"{"name": "lodestar-0.9.9.zip", "browser_download_url": "\#(url)", "digest": null}"#,
                      #"{"name": "lodestar-0.9.9.zip", "browser_download_url": "\#(url)"}"#] {
            XCTAssertNil(Updater.parseFeed(Data(#"[{"tag_name": "v0.9.9", "assets": [\#(asset)]}]"#.utf8)), asset)
        }
    }

    func testTheStableAnswerCarriesTheDigestToo() throws {
        let hex = String(repeating: "01", count: 32)
        let url = "https://github.com/Vaccone-Software/lodestar/releases/download/v0.47.0/lodestar-0.47.0.zip"
        let release = try XCTUnwrap(Updater.parseStable(Data("""
        {"tag": "v0.47.0", "version": "0.47.0", "published": "2026-01-01T00:00:00Z",
         "zip": {"name": "lodestar-0.47.0.zip", "url": "\(url)", "digest": "sha256:\(hex)"},
         "preview": {"tag": "v0.48.0"}, "pending": [], "policy": {}}
        """.utf8)))
        XCTAssertEqual(UpdateDownload.digest(of: release)?.hex, hex)
        let without = try XCTUnwrap(Updater.parseStable(Data("""
        {"tag": "v0.47.0", "version": "0.47.0", "zip": {"name": "lodestar-0.47.0.zip", "url": "\(url)"}}
        """.utf8)))
        XCTAssertNil(without.zipDigest, "an older site answers as it did")
    }

    func testOnlyASha256IsACheckTheAppCanMake() {
        for odd in ["md5:abc", "sha256:xyz", "sha256:" + String(repeating: "a", count: 63), "", "abc"] {
            XCTAssertNil(UpdateDownload.digest(of: release(digest: odd)), odd)
        }
        XCTAssertNotNil(UpdateDownload.digest(of: release(digest: "sha256:" + String(repeating: "A", count: 64))),
                        "hex is hex in either case")
    }

    // MARK: - The download

    func testTheZipArrivesCheckedAgainstTheDigest() async throws {
        try await run { _, _ in
            let transport = transport([.serving(resource)])
            let shares = SharesBox()
            let result = try await fetch(release(digest: goodDigest), transport, progress: { shares.add($0) })
            XCTAssertEqual(try Data(contentsOf: destination), Data(zip))
            XCTAssertEqual(result.verifiedDigest?.hex, goodDigest.dropFirst("sha256:".count).description)
            XCTAssertEqual(transport.requestCount, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + ".partial"), "no partial is left")
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + ".partial.resume"))
            XCTAssertFalse(shares.values.isEmpty, "the mark has something to light")
            XCTAssertTrue(shares.values.allSatisfy { (0...1).contains($0) })
            XCTAssertEqual(transport.requests.first?.headers["User-Agent"], "lodestar/\(Lodestar.version)")
        }
    }

    func testAZipTheFeedNamesNoDigestForIsStillDelivered() async throws {
        try await run { _, _ in
            _ = try await fetch(release(digest: nil), transport([.serving(resource)]))
            XCTAssertEqual(try Data(contentsOf: destination), Data(zip), "the download delivers it; unpacking requires the digest")
        }
    }

    func testADigestThatDoesNotMatchFailsTheDownloadAndLeavesNoZip() async throws {
        try await run { _, _ in
            let wrong = "sha256:" + String(repeating: "0", count: 64)
            let transport = transport([.serving(resource)])
            let sent = release(digest: wrong)
            do {
                _ = try await fetch(sent, transport)
                XCTFail("a zip that is not the one GitHub names was delivered")
            } catch let error as DownloadError {
                guard case .digestMismatch(let expected, let actual, let attempts) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(expected.hex, String(repeating: "0", count: 64))
                XCTAssertEqual(actual, goodDigest.dropFirst("sha256:".count).description)
                XCTAssertEqual(attempts, 2, "once more from the start, then said")
                let said = UpdateDownload.problem(error, release: sent)
                XCTAssertTrue(said.contains(actual) && said.contains(expected.hex) && said.contains("lodestar-9.9.9.zip"), said)
                XCTAssertTrue(said.contains("not installed"), said)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "never a zip that failed its check")
            XCTAssertEqual(transport.requestCount, 2)
        }
    }

    func testACutDownloadResumesFromWhatArrived() async throws {
        try await run { clock, events in
            let transport = transport([.serving(resource, fault: .cut(after: 80_000)), .serving(resource)])
            let task = Task { try await fetch(release(digest: goodDigest), transport) }
            await waitForRetry(events, clock)
            await clock.advance(by: .seconds(10))
            _ = try await task.value
            XCTAssertEqual(events.events(named: "download.retry").count, 1)
            let requests = transport.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertNil(requests[0].headers["Range"])
            XCTAssertEqual(requests[1].headers["Range"], "bytes=80000-", "the rest, not the lot")
            XCTAssertEqual(requests[1].headers["If-Range"], "\"z1\"")
            XCTAssertEqual(try Data(contentsOf: destination), Data(zip))
        }
    }

    /// An earlier try's partial, from a quit or a crash, is where the next
    /// check picks up.
    func testAPartialFromAnEarlierTryIsResumedByTheNextCheck() async throws {
        try await run { clock, _ in
            let first = transport([.serving(resource, chunkSize: 10_000, chunkDelay: .seconds(1))])
            let shares = SharesBox()
            let done = FlagBox()
            let task = Task { defer { done.set() }; return try await fetch(release(digest: goodDigest), first, progress: { shares.add($0) }) }
            // A quarter of it arrives, and the app is quit.
            await drive(clock, chunks: .seconds(1)) { (shares.values.max() ?? 0) >= 0.25 || done.value }
            task.cancel()
            _ = await task.result
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "not delivered")
            let second = transport([.serving(resource)])
            _ = try await fetch(release(digest: goodDigest), second)
            let range = second.requests.first?.headers["Range"]
            let from = range.flatMap { Int($0.dropFirst("bytes=".count).dropLast()) } ?? 0
            XCTAssertGreaterThanOrEqual(from, 40_000, "the second try asked for the rest: \(String(describing: range))")
            XCTAssertEqual(try Data(contentsOf: destination), Data(zip))
        }
    }

    func testAZipOverTheLimitIsRefusedNotStored() async throws {
        try await run { _, _ in
            let transport = transport([.oversized(UpdateDownload.byteLimit + 1)])
            do {
                _ = try await fetch(release(digest: goodDigest), transport)
                XCTFail("a zip over the limit was delivered")
            } catch let error as DownloadError {
                guard case .byteLimitExceeded(let limit) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(limit, 1 << 30)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(transport.requestCount, 1, "not asked for again")
        }
    }

    /// The three-minute cap on the whole transfer is gone: a zip that takes
    /// more than three minutes to arrive, a chunk every twenty seconds, is a zip.
    func testASlowTransferThatIsMovingIsNotCutAtThreeMinutes() async throws {
        try await run { clock, _ in
            let slow = transport([.serving(resource, chunkSize: 20_000, chunkDelay: .seconds(20))])
            let shares = SharesBox()
            let done = FlagBox()
            let task = Task { defer { done.set() }; return try await fetch(release(digest: goodDigest), slow, progress: { shares.add($0) }) }
            await drive(clock, chunks: .seconds(20)) { done.value }
            _ = try await task.value
            XCTAssertGreaterThan(clock.now.offset, .seconds(180), "past the cap it used to have")
            XCTAssertEqual(slow.requestCount, 1, "one request, not cut and resumed")
            XCTAssertEqual(try Data(contentsOf: destination), Data(zip))
            XCTAssertEqual(shares.values, shares.values.sorted(), "the mark only ever lights further")
            XCTAssertGreaterThan(shares.values.last ?? 0, 0.8, "and lights as it goes")
        }
    }

    /// And a transfer that is stuck is not held for ever: the half hour ends
    /// it, so a run does not stay `.checking` and refuse every later check.
    func testAStuckTransferIsEndedByTheDeadline() async throws {
        try await run { clock, _ in
            let stuck = transport([.serving(resource, fault: .hang(after: 10_000))])
            let task = Task { try await fetch(release(digest: goodDigest), stuck) }
            while stuck.inFlightCount == 0 { await Task.yield() }
            for _ in 0..<100 { await Task.yield() }
            await clock.advance(by: UpdateDownload.deadline + .seconds(1))
            do {
                _ = try await task.value
                XCTFail("a stuck download finished")
            } catch let error as DownloadError {
                guard case .deadlineExceeded = error else { return XCTFail("\(error)") }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testTheDeadlineAndTheLimitAreWhatTheyAreSaidToBe() {
        XCTAssertEqual(UpdateDownload.deadline, .seconds(1800))
        XCTAssertEqual(UpdateDownload.byteLimit, 1_073_741_824)
        let configuration = UpdateDownload.sessionConfiguration()
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 30)
        XCTAssertGreaterThan(configuration.timeoutIntervalForResource, 3 * 24 * 3600 - 1, "URLSession's own (a week): no cap")
    }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var value: Bool { lock.withLock { flag } }
}

private final class SharesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var shares: [Double] = []
    func add(_ share: Double) { lock.withLock { shares.append(share) } }
    var values: [Double] { lock.withLock { shares } }
}
