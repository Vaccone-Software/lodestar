import Foundation
import LodestarCore
import LodestarEars
import Stoic
import StoicDownloads
import StoicHTTP
import StoicStore

/// A model's files, pinned: the revision the accuracy fixture was recorded
/// against, each file's size and hash. A download is these bytes or it is
/// nothing — a model that changed upstream would be a different editor.
struct EditorManifest: Equatable {
    struct File: Equatable {
        let path: String
        let size: Int64
        /// Large files are checked by SHA-256, small ones by the git blob
        /// hash Hugging Face serves as their name.
        let sha256: String?
        let gitSHA1: String?

        init(path: String, size: Int64, sha256: String) {
            self.path = path; self.size = size; self.sha256 = sha256; self.gitSHA1 = nil
        }

        init(path: String, size: Int64, gitSHA1: String) {
            self.path = path; self.size = size; self.sha256 = nil; self.gitSHA1 = gitSHA1
        }
    }

    let repo: String
    let revision: String
    let files: [File]
    var total: Int64 { files.reduce(0) { $0 + $1.size } }
    /// The folder the model lives in under the models root.
    var folder: String { repo.split(separator: "/").last.map(String.init) ?? repo }

    func url(for file: File) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")!
    }

    static func forEngine(_ engine: EditorEngine) -> EditorManifest? {
        switch engine {
        case .standard: return standard
        case .full: return full
        case .spelling, .minimal: return nil
        }
    }

    static let standard = EditorManifest(
        repo: "mlx-community/gemma-4-e2b-it-4bit", revision: "238767527555cb75a05732a84dff5d6ba0dd6809",
        files: [
            .init(path: "chat_template.jinja", size: 17336, gitSHA1: "c19999a347da729cf62806a8ddb7eb8e315223b5"),
            .init(path: "config.json", size: 6395, gitSHA1: "1f8a26de63cd505f2fb5c98ad3f08f3e7f47a9de"),
            .init(path: "generation_config.json", size: 208, gitSHA1: "e605bb4523b1462ea9d9a3810b9e3ecf7ab7b1f6"),
            .init(path: "model.safetensors", size: 3_550_670_554,
                  sha256: "038e39a37a7667373d2c3991375446b10c96ae1d717a68674870343db376b76e"),
            .init(path: "model.safetensors.index.json", size: 218_323, gitSHA1: "b145d4f0cf82ffc8c1f9bef70da4b4083646382d"),
            .init(path: "processor_config.json", size: 1316, gitSHA1: "a086fb7e04b477c291a120b0a004abb78b11c6d2"),
            .init(path: "tokenizer.json", size: 32_169_626,
                  sha256: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
            .init(path: "tokenizer_config.json", size: 2740, gitSHA1: "cf6235aee46a24bf71f251c0a4e7a0379948f7d2"),
        ])

    static let full = EditorManifest(
        repo: "mlx-community/Qwen3.6-35B-A3B-4bit", revision: "38740b847e4cb78f352aba30aa41c76e08e6eb46",
        files: [
            .init(path: "chat_template.jinja", size: 7764, gitSHA1: "a8755d827c0a7b614c246c4060dfd58ab352a8ff"),
            .init(path: "config.json", size: 23591, gitSHA1: "e3a2334ebf2df216742ef3ed4b784417bfffe6fc"),
            .init(path: "configuration.json", size: 58, gitSHA1: "d24dba949ee1fe70cc810e4c4709a0bddf4e06ba"),
            .init(path: "generation_config.json", size: 202, gitSHA1: "023756cfadf88e5bf69eefeee3e172f38c448d64"),
            .init(path: "model-00001-of-00004.safetensors", size: 5_288_196_018,
                  sha256: "09f3e6ecb0b7af6e6a38bc8169a134c821b0924c2679b2bb8f4426ad38d032b8"),
            .init(path: "model-00002-of-00004.safetensors", size: 5_368_472_749,
                  sha256: "31dcdb1c49eebdb1505bd14e3cb33f9cf900bd2546b638f2464694ae763a033f"),
            .init(path: "model-00003-of-00004.safetensors", size: 5_368_324_139,
                  sha256: "3e66de06a1f03dade16a612a368cfce4a4c9caa4efd7d28185454384082cec03"),
            .init(path: "model-00004-of-00004.safetensors", size: 4_377_211_365,
                  sha256: "a5d0cf03519c26f8b506df6b0ba60526e5c08c8cea22d0c21ce92950e58a5422"),
            .init(path: "model.safetensors.index.json", size: 215_755, gitSHA1: "f714d295484e01790bad8b40c2ce49323d7d2598"),
            .init(path: "preprocessor_config.json", size: 390, gitSHA1: "2ea84a437d448ff71b08df68fdd949d5cc4ebb64"),
            .init(path: "processor_config.json", size: 1312, gitSHA1: "a3be3e79470d0a5befe0ba5247dfad8717d84529"),
            .init(path: "tokenizer.json", size: 19_989_343,
                  sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
            .init(path: "tokenizer_config.json", size: 1139, gitSHA1: "a068e2468cff426a9b105006e74e044030a6faf4"),
            .init(path: "video_preprocessor_config.json", size: 385, gitSHA1: "3ba673a5ad7d4d13f54155ecd38b2a94a6dac8fe"),
            .init(path: "vocab.json", size: 6_722_759, gitSHA1: "0aa0ce0658d60ac4a5d609f4eadb0e8e43514176"),
        ])

    /// The pinned file as a download is told to check it: its size, and
    /// the SHA-256 or git blob hash it was recorded with.
    ///
    /// It also adopts what an earlier build left: the staging folder is that
    /// build's, with each file part-way at its own name and no record of where
    /// it came from. The downloader resumes a file only with a record, and
    /// would remove those, so the gigabytes would be fetched again from
    /// nothing. The manifest pins the URL, the size and the digest, which is
    /// all the assurance there is: the bytes are believed, and the digest,
    /// checked as the rest arrives, says whether the splice was right (a file
    /// that fails it is fetched again from the start).
    func download(of file: File, in manifest: EditorManifest) throws(ContentDigest.Invalid) -> DownloadBundle.File {
        let digest: ContentDigest
        if let sha256 = file.sha256 {
            digest = try .sha256(sha256)
        } else {
            digest = try .gitBlobSHA1(file.gitSHA1 ?? "")
        }
        return DownloadBundle.File(file.path, manifest.url(for: file), expectedSize: Int(file.size), digest: digest)
            .adoptingUnrecordedPartial()
    }

    /// The whole model as one bundle, staged in `.<folder>.partial` beside
    /// where it goes: model files are readable by every user, 0o644.
    func bundle(in root: URL, requiredFreeBytes: UInt64? = nil) throws(ContentDigest.Invalid) -> DownloadBundle {
        var parts: [DownloadBundle.File] = []
        for file in files { parts.append(try download(of: file, in: self)) }
        return DownloadBundle(parts, to: root.appendingPathComponent(folder, isDirectory: true).path,
                              stagingPath: root.appendingPathComponent(".\(folder).partial", isDirectory: true).path,
                              fileMode: 0o644, requiredFreeBytes: requiredFreeBytes)
    }
}

/// What a download fetches: one of the editor's models or one of the
/// draft's settling ears. One downloader serves both kinds, each with its
/// own instance and folder.
enum ModelID: Hashable {
    case editor(EditorEngine)
    case ear(EarTier)
    /// The model dictation asks what was meant.
    case cleanup(CleanupModel)

    var name: String {
        switch self {
        case .editor(let engine): return engine.name
        case .ear(let tier): return tier.name
        case .cleanup(let model): return model.name
        }
    }

    static func manifest(_ id: ModelID) -> EditorManifest? {
        switch id {
        case .editor(let engine): return EditorManifest.forEngine(engine)
        case .ear(let tier): return tier.manifest.map(EditorManifest.init)
        case .cleanup(let model): return model.manifest
        }
    }
}

extension EditorManifest {
    /// An ear's pinned files, fetched the way the editor's are.
    init(_ ear: EarManifest) {
        self.init(repo: ear.repo, revision: ear.revision,
                  files: ear.files.map { File(path: $0.path, size: $0.size, sha256: $0.sha256) })
    }
}

/// Fetches a model's pinned files into Lodestar's models folder, in the
/// background, after the editor is turned on and agreed to: Stoic's
/// `Downloader`, with this file's words for what it is doing.
///
/// Resumable by byte range: a download cut off by sleep, a network change
/// or a quit continues where it stopped, next launch included. Never over
/// a metered connection or in Low Data Mode — twenty gigabytes on a phone's
/// hotspot is not the hand's intent. Each file is checked against its
/// pinned hash as it arrives, and the folder is swapped into place only
/// when every one is whole, so a model folder that exists is a whole model.
/// One model at a time; asking for another cancels the first and deletes
/// its partial files.
final class EditorDownload {
    enum State: Equatable {
        case idle
        case waiting                         // for a connection that is not metered
        case downloading(done: Int64, total: Int64)
        case verifying
        case failed(String)
        case ready
    }

    private(set) var state: State = .idle { didSet { if state != oldValue { changed() } } }
    private(set) var model: ModelID?
    /// The editor model on its way, if that is what this one fetches.
    var engine: EditorEngine? { if case .editor(let engine)? = model { return engine } else { return nil } }
    /// Main thread: the state moved (Settings redraws), and the model is
    /// whole and in place.
    var changed: () -> Void = {}
    var finished: (EditorEngine) -> Void = { _ in }
    var finishedEar: (EarTier) -> Void = { _ in }
    var finishedCleanup: (CleanupModel) -> Void = { _ in }

    let root: URL
    private let manifests: (ModelID) -> EditorManifest?
    private let fileSystem: any FileSystem
    private let downloader: Downloader
    private let spaceMargin: UInt64
    private let waitingGrace: Duration

    /// Which fetch is current: bumped by fetch and cancel on the main
    /// thread, read by the download, so a late report from a cancelled
    /// fetch changes nothing.
    private let lock = NSLock()
    private var _generation = 0
    private var generation: Int {
        get { lock.withLock { _generation } }
        set { lock.withLock { _generation = newValue } }
    }

    /// Main thread: the download going now, and the end of the line of
    /// everything started (a fetch, or the clearing a cancel asks for), so
    /// that one never begins before the one it replaced has let go of the
    /// files.
    private var running: Task<Void, Never>?
    private var line: Task<Void, Never>?

    /// - Parameters:
    ///   - transport: The network; the app's own session by default
    ///     (`sessionConfiguration`), a script in tests.
    ///   - fileSystem: Where the files go. Model files are 0o644.
    ///   - policy: Retries, verification and progress. `retryPolicy`'s by default.
    ///   - spaceMargin: Room to leave on the volume beyond what is left to fetch.
    ///   - waitingGrace: How long a request may wait for its answer before
    ///     Settings says it is waiting for a connection: a request is always
    ///     "waiting" for the first moments, and that is not worth saying.
    init(root: URL = EditorModels.root,
         transport: (any HTTPTransport)? = nil,
         fileSystem: any FileSystem = PosixFileSystem(newFileMode: 0o644, newDirectoryMode: 0o755),
         manifests: @escaping (ModelID) -> EditorManifest? = ModelID.manifest,
         policy: DownloadPolicy = EditorDownload.retryPolicy,
         spaceMargin: UInt64 = 2_000_000_000,
         waitingGrace: Duration = .seconds(3)) {
        self.root = root
        self.manifests = manifests
        self.fileSystem = fileSystem
        self.spaceMargin = spaceMargin
        self.waitingGrace = waitingGrace
        // One try for each request: the downloader is the retry layer. The
        // wait for an answer is the minute the session always allowed.
        var clientPolicy = HTTPPolicy.singleAttempt
        clientPolicy.attemptTimeout = .seconds(60)
        let client = HTTPClient(base: URL(string: "https://huggingface.co")!, policy: clientPolicy,
                                transport: transport ?? URLSessionTransport(configuration: Self.sessionConfiguration()),
                                label: "model-download")
        // No operation: a download declared as a `.long` operation without a
        // deadline gets design/22's safety net (90 s at user-initiated), and
        // this one is a person's agreed twenty gigabytes. Without one it
        // runs under the caller's deadline alone, and the caller sets none:
        // what ends it is the fetch finishing, a failure that cannot improve,
        // or the person turning the editor off.
        downloader = Downloader(client: client, fileSystem: fileSystem, policy: policy, label: "model-download")
    }

    /// Never over a metered connection or in Low Data Mode, never cached,
    /// waiting for the network rather than failing without one, and a
    /// minute of silence is a cut.
    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.timeoutIntervalForRequest = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return configuration
    }

    /// How long a failed fetch waits before it resumes: ten seconds, then
    /// sixty, then the five-minute ceiling. Equal jitter (half to all of
    /// each wait), so a fleet of Macs cut off together by the same outage
    /// does not come back to Hugging Face in the same second. Unbounded on
    /// purpose, and started over whenever bytes arrive: the person turned
    /// the editor on and agreed to the download, the fetch resumes by byte
    /// range, and a Mac that is offline for a day should still finish it
    /// when the network returns while the app runs. What cannot get better
    /// by waiting stops instead: the downloader does not retry a client
    /// error but 408 and 429.
    static let defaultRetrySchedule = Schedule
        .exponential(base: .seconds(10), factor: 6)
        .capped(at: .seconds(300))
        .jittered(.equal)

    /// The downloader's numbers: its own, but for the schedule above. One
    /// fetch again after a digest that does not match, progress every half
    /// second.
    static var retryPolicy: DownloadPolicy { DownloadPolicy(schedule: defaultRetrySchedule) }

    /// What Settings says while a model is on its way, or nil when there
    /// is nothing to say.
    var status: String? {
        guard let model else { return nil }
        let name = model.name
        func gb(_ bytes: Int64) -> String { String(format: "%.1f", Double(bytes) / 1e9) }
        switch state {
        case .idle, .ready: return nil
        case .waiting: return "\(name) · waiting for a connection that is not metered"
        case .downloading(let done, let total): return "\(name) · downloading \(gb(done)) of \(gb(total)) GB"
        case .verifying: return "\(name) · checking the download"
        case .failed(let why): return "\(name) · \(why)"
        }
    }

    private func staging(_ manifest: EditorManifest) -> URL {
        root.appendingPathComponent(".\(manifest.folder).partial", isDirectory: true)
    }

    /// Fetch this engine's model, unless it is already on its way. Asked
    /// again after a failure, it resumes from what it has. Main thread.
    func fetch(_ engine: EditorEngine) { fetch(.editor(engine)) }

    func fetch(_ wanted: ModelID) {
        if wanted == model, state != .idle, !isFailed { return }
        if wanted != model { cancel() }
        guard let manifest = manifests(wanted) else { return }
        model = wanted
        generation += 1
        let generation = self.generation
        state = .downloading(done: 0, total: manifest.total)
        running?.cancel()
        let before = line
        let task = Task { [weak self] in
            await before?.value
            await self?.fetch(manifest, generation: generation)
        }
        running = task
        line = task
    }

    private var isFailed: Bool { if case .failed = state { return true } else { return false } }

    /// Stop. What was half fetched is deleted, unless it is kept to resume
    /// later — the editor turned off, not another model chosen. Main thread.
    func cancel(keepingPartial: Bool = false) {
        generation += 1
        let fetching = model
        model = nil
        state = .idle
        running?.cancel()
        running = nil
        let before = line
        line = Task { [weak self] in
            await before?.value
            guard let self, !keepingPartial, let fetching, let manifest = self.manifests(fetching) else { return }
            try? FileManager.default.removeItem(at: self.staging(manifest))
        }
    }

    // MARK: - The work

    private func post(_ state: State, generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.state = state
            if state == .ready, let model = self.model {
                switch model {
                case .editor(let engine): self.finished(engine)
                case .ear(let tier): self.finishedEar(tier)
                case .cleanup(let model): self.finishedCleanup(model)
                }
            }
        }
    }

    private func fetch(_ manifest: EditorManifest, generation: Int) async {
        guard generation == self.generation else { return }
        // Already whole: nothing to fetch.
        let final = root.appendingPathComponent(manifest.folder, isDirectory: true)
        if manifest.files.allSatisfy({ Self.size(of: final.appendingPathComponent($0.path)) == $0.size }) {
            post(.ready, generation: generation)
            return
        }
        let staging = self.staging(manifest)
        EditorModels.excludeFromBackup(root)
        // Room for what is left, and two gigabytes besides: a full disk
        // breaks more than the editor.
        let have = manifest.files.reduce(Int64(0)) { sum, file in
            let path = staging.appendingPathComponent(file.path)
            return sum + min(file.size, max(Self.size(of: path), Self.size(of: path.appendingPathExtension("partial"))))
        }
        let needed = UInt64(max(0, manifest.total - have)) + spaceMargin
        let progress = Progress(model: self, manifest: manifest, generation: generation)
        let phase = Phase()
        do {
            let bundle = try manifest.bundle(in: root, requiredFreeBytes: needed)
            let result = try await withAmbient({ ambient in
                ambient.instrumentation = Tee(ambient.instrumentation) { progress.observe($0) }
            }, operation: {
                try await downloader.download(bundle) { phase.set($0.phase); progress.report($0) }
            })
            Log.info("editor", ["downloaded": manifest.folder, "bytes": manifest.total, "durable": result.isDurable])
            post(.ready, generation: generation)
        } catch is CancellationError {
            // Stopped by a newer fetch or a cancel, which say what is next.
        } catch {
            let placing = phase.value == .placing
            Log.error("editor: download of \(manifest.folder) failed: \(error)")
            post(.failed(Self.words(for: error, placing: placing)), generation: generation)
        }
    }

    /// What Settings says when a fetch ends without a model.
    static func words(for error: any Error, placing: Bool) -> String {
        if placing { return "could not be put in place" }
        guard let error = error as? DownloadError else { return "could not be downloaded" }
        switch error {
        case .insufficientSpace(let required, _):
            return "needs \(Int((Double(required) / 1e9).rounded(.up))) GB free"
        case .digestMismatch, .sizeMismatch, .byteLimitExceeded:
            return "the download did not match, try again later"
        case .http(.status(let code, _, _, _, _)):
            return "could not be downloaded (\(code))"
        case .store(let store) where store.kind == .diskFull:
            return "ran out of disk space"
        case .store:
            return "could not be saved"
        case .http, .retriesExhausted, .badResponse, .deadlineExceeded, .rejected:
            return "could not be downloaded"
        }
    }

    private static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

// MARK: - Reports

/// The download's phase as the last report said it, for the failure that
/// ends it: a swap that failed is not a failed download.
private final class Phase: @unchecked Sendable {
    private let lock = NSLock()
    private var phase = DownloadProgress.Phase.waiting
    func set(_ new: DownloadProgress.Phase) { lock.withLock { phase = new } }
    var value: DownloadProgress.Phase { lock.withLock { phase } }
}

/// What the downloader's reports and events become in the editor's state,
/// on the downloading task, handed to the main thread by `post`.
private final class Progress: @unchecked Sendable {
    private weak var model: EditorDownload?
    private let manifest: EditorManifest
    let generation: Int
    private let lock = NSLock()
    /// The retry the downloader is waiting out, if any: said instead of
    /// "waiting" until bytes arrive.
    private var retrying: String?
    /// Counts reports, so a wait that has been answered since is not said.
    private var sequence = 0

    init(model: EditorDownload, manifest: EditorManifest, generation: Int) {
        self.model = model
        self.manifest = manifest
        self.generation = generation
    }

    func report(_ progress: DownloadProgress) {
        let (retry, number): (String?, Int) = lock.withLock {
            sequence += 1
            if progress.phase == .downloading { retrying = nil }
            return (retrying, sequence)
        }
        let total = Int64(progress.totalBytes ?? Int(manifest.total))
        switch progress.phase {
        case .downloading:
            model?.say(.downloading(done: Int64(progress.bytesDone), total: total), generation: generation)
        case .verifying, .placing:
            model?.say(.verifying, generation: generation)
        case .waiting:
            if let retry {
                model?.say(.failed(retry), generation: generation)
            } else {
                sayWaiting(after: number)
            }
        }
    }

    /// The downloader is about to wait out a failure: what Settings has
    /// always said of it. Events are the downloader's own account of it, the
    /// status or error that ended the request.
    func observe(_ event: Event) {
        guard event.name == "download.retry", case .string(let reason)? = event["reason"] else { return }
        let words: String
        if reason.hasPrefix("status_"), let code = Int(reason.dropFirst("status_".count)), code >= 400 {
            words = "could not be downloaded (\(code))"
        } else {
            words = "download paused, retrying"
        }
        lock.withLock { retrying = words }
        model?.say(.failed(words), generation: generation)
    }

    private func sayWaiting(after number: Int) {
        let grace = model?.grace ?? .seconds(3)
        Task { [self] in
            do { try await Ambient.sleep(for: grace) } catch { return }
            model?.applyWaiting(number: number, from: self)
        }
    }

    func isCurrent(_ number: Int) -> Bool { lock.withLock { sequence == number && retrying == nil } }
}

extension EditorDownload {
    fileprivate func say(_ state: State, generation: Int) { post(state, generation: generation) }

    fileprivate var grace: Duration { waitingGrace }

    /// "Waiting for a connection", once a request has waited past the grace
    /// with nothing newer said. Judged on the main thread, where the state is
    /// changed, so that a report or a retry that came while the grace ran
    /// cannot be written over; and for the fetch the report is from, not the
    /// one now current, so a report that comes late from a cancelled fetch
    /// does not pass for a new one.
    fileprivate func applyWaiting(number: Int, from progress: Progress) {
        let generation = progress.generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation, progress.isCurrent(number) else { return }
            self.state = .waiting
        }
    }
}

/// Events pass through, and the editor reads the ones it words.
private struct Tee: Instrumentation {
    let base: any Instrumentation
    let observe: @Sendable (Event) -> Void

    init(_ base: any Instrumentation, observe: @escaping @Sendable (Event) -> Void) {
        self.base = base
        self.observe = observe
    }

    func record(_ event: Event) {
        base.record(event)
        observe(event)
    }

    func isEnabled(_ level: Event.Level) -> Bool { base.isEnabled(level) }
}
