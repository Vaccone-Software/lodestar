import CryptoKit
import Stoic
import StoicStore
import XCTest
@testable import lodestar
@testable import LodestarCore

/// A Hugging Face that lives in the test: files by path, byte ranges
/// honoured or not, failures on request, every request written down.
final class StubHub: URLProtocol {
    struct Behavior {
        var files: [String: Data] = [:]
        var ignoresRange = false
        /// Paths that fail with this status this many more times.
        var failures: [String: (status: Int, times: Int)] = [:]
        /// Paths served with their bytes changed, this many more times.
        var corrupt: [String: Int] = [:]
        /// Stop a response after this many bytes, once per path: a cut
        /// connection.
        var cutAfter: [String: Int] = [:]
    }
    private static let lock = NSLock()
    private static var _behavior = Behavior()
    private static var _requests: [(path: String, range: String?)] = []

    static var behavior: Behavior {
        get { lock.withLock { _behavior } }
        set { lock.withLock { _behavior = newValue } }
    }
    static var requests: [(path: String, range: String?)] { lock.withLock { _requests } }
    static func reset(_ behavior: Behavior) { lock.withLock { _behavior = behavior; _requests = [] } }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "huggingface.co" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url!.lastPathComponent
        let range = request.value(forHTTPHeaderField: "Range")
        Self.lock.withLock { Self._requests.append((path, range)) }
        var behavior = Self.behavior
        if let failure = behavior.failures[path], failure.times > 0 {
            behavior.failures[path] = (failure.status, failure.times - 1)
            Self.behavior = behavior
            respond(status: failure.status, headers: [:], body: Data())
            return
        }
        guard var data = behavior.files[path] else { respond(status: 404, headers: [:], body: Data()); return }
        if let left = behavior.corrupt[path], left > 0 {
            behavior.corrupt[path] = left - 1
            Self.behavior = behavior
            data[data.startIndex] ^= 0xFF
        }
        var start = 0
        if let range, !behavior.ignoresRange,
           let from = Int(range.replacingOccurrences(of: "bytes=", with: "").replacingOccurrences(of: "-", with: "")) {
            start = from
        }
        var body = data.subdata(in: start..<data.count)
        if let cut = behavior.cutAfter[path] {
            behavior.cutAfter[path] = nil
            Self.behavior = behavior
            body = body.prefix(cut)
            let status = start > 0 ? 206 : 200
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": String(data.count - start)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            // Ended short without an error — the case a dropped connection
            // can look like — so the resume is what the test sees, never a
            // race between the bytes and the failure.
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        respond(status: start > 0 ? 206 : 200,
                headers: start > 0 ? ["Content-Range": "bytes \(start)-\(data.count - 1)/\(data.count)"] : [:],
                body: body)
    }

    private func respond(status: Int, headers: [String: String], body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: headers.merging(["Content-Length": String(body.count)]) { a, _ in a })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class EditorDownloadTests: XCTestCase {
    private var root: URL!
    private let weights = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    private let config = Data(#"{"model_type":"test"}"#.utf8)

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

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("models-\(UUID().uuidString)")
        StubHub.reset(.init(files: ["config.json": config, "model.safetensors": weights]))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Putting the model in place

    private func stagedModel() throws -> SimulatedFileSystem {
        let disk = SimulatedFileSystem()
        try disk.createDirectory("/models")
        let file = AtomicFile(fileSystem: disk, options: .init(envelope: false))
        try file.write(Array("old".utf8), to: "/models/m")
        try file.write(Array("new".utf8), to: "/models/.m.partial")
        disk.settle()
        return disk
    }

    func testAModelWhoseSwapCouldNotBeSyncedIsInPlaceAndTheOldOneIsCleared() throws {
        let disk = try stagedModel()
        disk.inject(EIO, on: .syncDirectory)
        try EditorDownload.putInPlace(URL(fileURLWithPath: "/models/.m.partial"),
                                      at: URL(fileURLWithPath: "/models/m"), fileSystem: disk)
        XCTAssertEqual(disk.contents(of: "/models/m"), Array("new".utf8))
        XCTAssertNil(disk.contents(of: "/models/.m.partial"), "the old model is not left to be resumed into")
    }

    func testAModelThatCouldNotBeSwappedIsAFailureAndLeavesBothAsTheyWere() throws {
        let disk = try stagedModel()
        disk.inject(ENOSPC, on: .exchange)
        XCTAssertThrowsError(try EditorDownload.putInPlace(URL(fileURLWithPath: "/models/.m.partial"),
                                                           at: URL(fileURLWithPath: "/models/m"),
                                                           fileSystem: disk)) {
            XCTAssertEqual(($0 as? StoreError)?.kind, .diskFull)
        }
        XCTAssertEqual(disk.contents(of: "/models/m"), Array("old".utf8))
        XCTAssertEqual(disk.contents(of: "/models/.m.partial"), Array("new".utf8))
    }

    private func download(free: Int64 = 100_000_000_000, retry: Schedule = .fixed(.milliseconds(50))) -> EditorDownload {
        let manifest = self.manifest
        return EditorDownload(root: root, protocolClasses: [StubHub.self],
                              manifests: { $0 == .editor(.standard) ? manifest : nil },
                              freeSpace: { _ in free }, retrySchedule: retry)
    }

    private func settle(_ download: EditorDownload, until done: (EditorDownload.State) -> Bool,
                        file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(10)
        while !done(download.state), Date() < deadline { Stage.pump() }
        XCTAssertTrue(done(download.state), "stuck at \(download.state)", file: file, line: line)
    }

    private var finalFolder: URL { root.appendingPathComponent("tiny-model", isDirectory: true) }

    func testAModelArrivesWholeAndChecked() throws {
        let download = download()
        var finished: [EditorEngine] = []
        download.finished = { finished.append($0) }
        download.fetch(.standard)
        settle(download) { $0 == .ready }
        XCTAssertEqual(finished, [.standard])
        XCTAssertEqual(try Data(contentsOf: finalFolder.appendingPathComponent("model.safetensors")), weights)
        XCTAssertTrue(EditorModels.isComplete(finalFolder, manifest))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".tiny-model.partial").path),
                       "the partial folder became the model")
        let excluded = try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        XCTAssertEqual(excluded, true, "gigabytes that download again are not backed up")
    }

    func testACutDownloadResumesWhereItStopped() throws {
        var behavior = StubHub.behavior
        behavior.cutAfter = ["model.safetensors": 120_000]
        StubHub.reset(behavior)
        let download = download()
        download.fetch(.standard)
        settle(download) { $0 == .ready }
        let ranges = StubHub.requests.filter { $0.path == "model.safetensors" }.map(\.range)
        XCTAssertEqual(ranges.first ?? "x", nil, "the first request asks for everything")
        XCTAssertEqual(ranges.last ?? nil, "bytes=120000-", "the retry asks only for the rest")
        XCTAssertEqual(try Data(contentsOf: finalFolder.appendingPathComponent("model.safetensors")), weights)
    }

    func testAServerThatIgnoresTheRangeStartsTheFileOver() throws {
        var behavior = StubHub.behavior
        behavior.cutAfter = ["model.safetensors": 50_000]
        behavior.ignoresRange = true
        StubHub.reset(behavior)
        let download = download()
        download.fetch(.standard)
        settle(download) { $0 == .ready }
        XCTAssertEqual(try Data(contentsOf: finalFolder.appendingPathComponent("model.safetensors")), weights,
                       "a whole file after a 200, not the rest appended to the start")
    }

    func testACorruptFileIsFetchedAgainOnceThenSaid() throws {
        var once = StubHub.behavior
        once.corrupt = ["model.safetensors": 1]
        StubHub.reset(once)
        let healed = download()
        healed.fetch(.standard)
        settle(healed) { $0 == .ready }
        XCTAssertEqual(StubHub.requests.filter { $0.path == "model.safetensors" }.count, 2)

        try? FileManager.default.removeItem(at: root)
        var always = StubHub.behavior
        always.corrupt = ["model.safetensors": 5]
        StubHub.reset(always)
        let broken = download()
        broken.fetch(.standard)
        settle(broken) { if case .failed = $0 { return true } else { return false } }
        XCTAssertEqual(broken.state, .failed("the download did not match, try again later"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalFolder.path), "never a model that did not match")
    }

    func testAFullDiskIsSaidBeforeAByteIsFetched() {
        let download = download(free: 1_000_000)
        download.fetch(.standard)
        settle(download) { if case .failed = $0 { return true } else { return false } }
        XCTAssertEqual(download.status, "Standard · needs 3 GB free")
        XCTAssertTrue(StubHub.requests.isEmpty)
    }

    func testAServerErrorIsRetried() {
        var behavior = StubHub.behavior
        behavior.failures = ["model.safetensors": (503, 2)]
        StubHub.reset(behavior)
        let download = download()
        download.fetch(.standard)
        settle(download) { $0 == .ready }
        XCTAssertEqual(StubHub.requests.filter { $0.path == "model.safetensors" }.count, 3)
    }

    /// A 4xx is the server saying the request is wrong; asking again every
    /// five minutes for ever fixes nothing. It is said, once, as a failure
    /// the person can ask to retry from Settings.
    func testAClientErrorIsSaidAndNotRetried() {
        var behavior = StubHub.behavior
        behavior.failures = ["model.safetensors": (404, 99)]
        StubHub.reset(behavior)
        let download = download()
        download.fetch(.standard)
        settle(download) { if case .failed = $0 { return true } else { return false } }
        XCTAssertEqual(download.state, .failed("could not be downloaded (404)"))
        // The schedule says 50 ms; wait past two of them.
        let until = Date().addingTimeInterval(0.09)
        while Date() < until { Stage.pump() }
        XCTAssertEqual(StubHub.requests.filter { $0.path == "model.safetensors" }.count, 1, "asked once")
        guard case .failed = download.state else { return XCTFail("left the failure: \(download.state)") }
    }

    func testARateLimitIsRetried() {
        var behavior = StubHub.behavior
        behavior.failures = ["model.safetensors": (429, 1)]
        StubHub.reset(behavior)
        let download = download()
        download.fetch(.standard)
        settle(download) { $0 == .ready }
        XCTAssertEqual(StubHub.requests.filter { $0.path == "model.safetensors" }.count, 2)
    }

    func testOnlyTheClientErrorsThatCannotImproveAreFinal() {
        for status in [0, 200, 206, 301, 408, 429, 500, 502, 503] {
            XCTAssertTrue(EditorDownload.isRetryable(status: status), "\(status)")
        }
        for status in [400, 401, 403, 404, 410, 416] {
            XCTAssertFalse(EditorDownload.isRetryable(status: status), "\(status)")
        }
    }

    /// The waits climb from ten seconds to the five-minute ceiling, and
    /// the jitter never lengthens one nor takes more than half off it.
    func testTheRetryWaitsClimbToFiveMinutesAndAreJittered() {
        let schedule = EditorDownload.defaultRetrySchedule
        XCTAssertEqual(schedule.maximalDelays(limit: 5), [.seconds(10), .seconds(60), .seconds(300), .seconds(300), .seconds(300)])
        var stepper = schedule.makeStepper(random: RandomSource.seeded(7).generator())
        var drawn: [Duration] = []
        for ceiling in [10.0, 60, 300, 300, 300, 300] {
            let delay = stepper.next(elapsed: .zero)
            XCTAssertNotNil(delay, "it keeps trying")
            drawn.append(delay ?? .zero)
            let seconds = Double(delay?.components.seconds ?? 0)
            XCTAssertLessThanOrEqual(seconds, ceiling)
            XCTAssertGreaterThanOrEqual(seconds, ceiling / 2 - 1)
        }
        XCTAssertGreaterThan(Set(drawn[2...]).count, 1, "three waits at the ceiling are not the same wait")
    }

    /// The finished folder replaces the old one in one swap and leaves no
    /// partial behind.
    func testAFinishedModelReplacesWhatWasThere() throws {
        try FileManager.default.createDirectory(at: finalFolder, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: finalFolder.appendingPathComponent("old.txt"))
        let download = download()
        download.fetch(.standard)
        settle(download) { $0 == .ready }
        XCTAssertEqual(try Data(contentsOf: finalFolder.appendingPathComponent("model.safetensors")), weights)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalFolder.appendingPathComponent("old.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".tiny-model.partial").path))
    }

    func testAWholeModelIsNotFetchedAgain() throws {
        let first = download()
        first.fetch(.standard)
        settle(first) { $0 == .ready }
        StubHub.reset(StubHub.behavior)
        let second = download()
        second.fetch(.standard)
        settle(second) { $0 == .ready }
        XCTAssertTrue(StubHub.requests.isEmpty)
    }

    func testTurningOffKeepsThePartialAndChoosingAnotherDeletesIt() throws {
        let partial = root.appendingPathComponent(".tiny-model.partial")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try weights.prefix(1000).write(to: partial.appendingPathComponent("model.safetensors"))
        let download = download()
        download.fetch(.standard)
        download.cancel(keepingPartial: true)
        Stage.pump()
        download.fetch(.standard)
        download.cancel(keepingPartial: true)
        let drained = expectation(description: "queue")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path), "off: kept to resume")
        download.fetch(.standard)
        download.cancel()
        let gone = expectation(description: "gone")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { gone.fulfill() }
        wait(for: [gone], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path), "another model: deleted")
    }

    func testTheStatusSettingsShows() {
        let download = download()
        XCTAssertNil(download.status)
        download.fetch(.standard)
        XCTAssertEqual(download.status, "Standard · downloading 0.0 of 0.0 GB")
        settle(download) { $0 == .ready }
        XCTAssertNil(download.status, "ready says nothing: the model's own status does")
    }

    func testTheFileChecks() throws {
        let file = root.appendingPathComponent("w.bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try weights.write(to: file)
        XCTAssertTrue(EditorManifest.verify(file, against: manifest.files[1]))
        try (weights.dropLast() + Data([0])).write(to: file)
        XCTAssertFalse(EditorManifest.verify(file, against: manifest.files[1]), "one byte off")
        try config.write(to: file)
        XCTAssertTrue(EditorManifest.verify(file, against: manifest.files[0]), "a git blob hash")
    }

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

    func testOneModelIsKeptOnDisk() throws {
        for folder in ["gemma-4-e2b-it-4bit", "Qwen3.6-35B-A3B-4bit"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        EditorModels.removeAll(except: .full, root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("gemma-4-e2b-it-4bit").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Qwen3.6-35B-A3B-4bit").path))
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
