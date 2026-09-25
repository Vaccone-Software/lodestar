import CryptoKit
import Foundation
import LodestarCore

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

    /// Does this file on disk hold exactly the pinned bytes? Streamed, so
    /// a five-gigabyte shard costs memory for one chunk at a time.
    static func verify(_ url: URL, against file: File) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seekToEnd()) == UInt64(file.size) else { return false }
        try? handle.seek(toOffset: 0)
        let chunk = 8 << 20
        if let expected = file.sha256 {
            var hash = SHA256()
            while let data = try? handle.read(upToCount: chunk), !data.isEmpty { hash.update(data: data) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined() == expected
        }
        if let expected = file.gitSHA1 {
            var hash = Insecure.SHA1()
            hash.update(data: Data("blob \(file.size)\u{0}".utf8))
            while let data = try? handle.read(upToCount: chunk), !data.isEmpty { hash.update(data: data) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined() == expected
        }
        return false
    }
}

/// Fetches a model's pinned files into Lodestar's models folder, in the
/// background, after the editor is turned on and agreed to.
///
/// Resumable by byte range: a download cut off by sleep, a network change
/// or a quit continues where it stopped, next launch included. Never over
/// a metered connection or in Low Data Mode — twenty gigabytes on a phone's
/// hotspot is not the hand's intent. Each file is checked against its
/// pinned hash before the folder is renamed into place, so a model folder
/// that exists is a whole model. One model at a time; asking for another
/// cancels the first and deletes its partial files.
final class EditorDownload: NSObject, URLSessionDataDelegate {
    enum State: Equatable {
        case idle
        case waiting                         // for a connection that is not metered
        case downloading(done: Int64, total: Int64)
        case verifying
        case failed(String)
        case ready
    }

    private(set) var state: State = .idle { didSet { if state != oldValue { changed() } } }
    private(set) var engine: EditorEngine?
    /// Main thread: the state moved (Settings redraws), and the model is
    /// whole and in place.
    var changed: () -> Void = {}
    var finished: (EditorEngine) -> Void = { _ in }

    let root: URL
    private let manifests: (EditorEngine) -> EditorManifest?
    private let freeSpace: (URL) -> Int64
    private let retryDelays: [TimeInterval]
    private var session: URLSession!
    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.vaccone.lodestar.editor.download"
        return queue
    }()

    // Delegate-queue state.
    private var manifest: EditorManifest?
    private var index = 0
    private var handle: FileHandle?
    private var fileDone: Int64 = 0
    private var before: Int64 = 0          // bytes of the files already whole
    private var task: URLSessionDataTask?
    private var lastReport = Date.distantPast
    /// Network failures in a row, for the retry's wait; reset by bytes.
    private var failures = 0
    /// Files that arrived and did not match their hash, this fetch: never
    /// reset by bytes arriving, or a server sending the wrong ones would
    /// be fetched from forever.
    private var mismatches = 0
    /// Which fetch is current: bumped by fetch and cancel on the main
    /// thread, read by the delegate queue, so a late callback from a
    /// cancelled fetch changes nothing.
    private let lock = NSLock()
    private var _generation = 0
    private var generation: Int {
        get { lock.withLock { _generation } }
        set { lock.withLock { _generation = newValue } }
    }

    init(root: URL = EditorModels.root, protocolClasses: [AnyClass]? = nil,
         manifests: @escaping (EditorEngine) -> EditorManifest? = EditorManifest.forEngine,
         freeSpace: @escaping (URL) -> Int64 = EditorDownload.availableSpace,
         retryDelays: [TimeInterval] = [10, 60, 300]) {
        self.root = root
        self.manifests = manifests
        self.freeSpace = freeSpace
        self.retryDelays = retryDelays
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.allowsExpensiveNetworkAccess = false
        configuration.allowsConstrainedNetworkAccess = false
        configuration.timeoutIntervalForRequest = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    static func availableSpace(_ url: URL) -> Int64 {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    /// What Settings says while a model is on its way, or nil when there
    /// is nothing to say.
    var status: String? {
        guard let engine else { return nil }
        let name = engine.name
        func gb(_ bytes: Int64) -> String { String(format: "%.1f", Double(bytes) / 1e9) }
        switch state {
        case .idle, .ready: return nil
        case .waiting: return "\(name) · waiting for a connection that is not metered"
        case .downloading(let done, let total): return "\(name) · downloading \(gb(done)) of \(gb(total)) GB"
        case .verifying: return "\(name) · checking the download"
        case .failed(let why): return "\(name) · \(why)"
        }
    }

    private func partial(_ manifest: EditorManifest) -> URL {
        root.appendingPathComponent(".\(manifest.folder).partial", isDirectory: true)
    }

    /// Fetch this engine's model, unless it is already on its way. Asked
    /// again after a failure, it resumes from what it has. Main thread.
    func fetch(_ engine: EditorEngine) {
        if engine == self.engine, state != .idle, !isFailed { return }
        if engine != self.engine { cancel() }
        guard let manifest = manifests(engine) else { return }
        self.engine = engine
        generation += 1
        let generation = self.generation
        state = .downloading(done: 0, total: manifest.total)
        delegateQueue.addOperation { [weak self] in
            guard let self else { return }
            self.task?.cancel()
            self.begin(manifest, generation: generation)
        }
    }

    private var isFailed: Bool { if case .failed = state { return true } else { return false } }

    /// Stop. What was half fetched is deleted, unless it is kept to resume
    /// later — the editor turned off, not another model chosen. Main thread.
    func cancel(keepingPartial: Bool = false) {
        generation += 1
        let engine = self.engine
        self.engine = nil
        state = .idle
        delegateQueue.addOperation { [weak self] in
            guard let self else { return }
            self.task?.cancel()
            self.task = nil
            try? self.handle?.close()
            self.handle = nil
            if !keepingPartial, let engine, let manifest = self.manifests(engine) {
                try? FileManager.default.removeItem(at: self.partial(manifest))
            }
            self.manifest = nil
        }
    }

    // MARK: - The work, on the delegate queue

    private func post(_ state: State, generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == generation else { return }
            self.state = state
            if state == .ready, let engine = self.engine { self.finished(engine) }
        }
    }

    private func begin(_ manifest: EditorManifest, generation: Int) {
        guard generation == self.generation else { return }
        self.manifest = manifest
        // Already whole: nothing to fetch.
        let final = root.appendingPathComponent(manifest.folder, isDirectory: true)
        if manifest.files.allSatisfy({ Self.size(of: final.appendingPathComponent($0.path)) == $0.size }) {
            post(.ready, generation: generation)
            return
        }
        index = 0
        failures = 0
        mismatches = 0
        let folder = partial(manifest)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        EditorModels.excludeFromBackup(root)
        // Room for what is left, and two gigabytes besides: a full disk
        // breaks more than the editor.
        let have = manifest.files.reduce(Int64(0)) { sum, file in
            sum + min(file.size, Self.size(of: folder.appendingPathComponent(file.path)))
        }
        let needed = manifest.total - have + 2_000_000_000
        guard freeSpace(root) >= needed else {
            post(.failed("needs \(Int((Double(needed) / 1e9).rounded(.up))) GB free"), generation: generation)
            return
        }
        next(generation: generation)
    }

    private static func size(of url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func next(generation: Int) {
        guard let manifest, generation == self.generation else { return }
        let folder = partial(manifest)
        while index < manifest.files.count {
            let file = manifest.files[index]
            let url = folder.appendingPathComponent(file.path)
            let have = Self.size(of: url)
            if have == file.size { index += 1; continue }
            if have > file.size { try? FileManager.default.removeItem(at: url) }
            // Resume where the file stops.
            before = manifest.files[..<index].reduce(0) { $0 + $1.size }
            fileDone = Self.size(of: url)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
            var request = URLRequest(url: manifest.url(for: file))
            if fileDone > 0 { request.setValue("bytes=\(fileDone)-", forHTTPHeaderField: "Range") }
            let task = session.dataTask(with: request)
            task.taskDescription = String(generation)
            self.task = task
            post(.downloading(done: before + fileDone, total: manifest.total), generation: generation)
            task.resume()
            return
        }
        verify(manifest, generation: generation)
    }

    private func verify(_ manifest: EditorManifest, generation: Int) {
        post(.verifying, generation: generation)
        let folder = partial(manifest)
        let bad = manifest.files.filter { !EditorManifest.verify(folder.appendingPathComponent($0.path), against: $0) }
        guard bad.isEmpty else {
            // A corrupt file is fetched again, once; twice is a problem to say.
            for file in bad { try? FileManager.default.removeItem(at: folder.appendingPathComponent(file.path)) }
            mismatches += 1
            if mismatches > 1 {
                post(.failed("the download did not match, try again later"), generation: generation)
                return
            }
            index = 0
            next(generation: generation)
            return
        }
        let final = root.appendingPathComponent(manifest.folder, isDirectory: true)
        try? FileManager.default.removeItem(at: final)
        do {
            try FileManager.default.moveItem(at: folder, to: final)
            Log.info("editor", ["downloaded": manifest.folder, "bytes": manifest.total])
            post(.ready, generation: generation)
        } catch {
            post(.failed("could not be put in place"), generation: generation)
        }
    }

    // MARK: - URLSession

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200, fileDone > 0 {
            // The server sent the whole file, not the rest: start it over.
            try? handle?.truncate(atOffset: 0)
            fileDone = 0
        } else if status != 200, status != 206 {
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let manifest, dataTask.taskDescription == String(generation) else { return }
        do {
            try handle?.write(contentsOf: data)
        } catch {
            dataTask.cancel()
            return
        }
        fileDone += Int64(data.count)
        failures = 0
        if Date().timeIntervalSince(lastReport) > 0.5 {
            lastReport = Date()
            post(.downloading(done: before + fileDone, total: manifest.total),
                 generation: Int(dataTask.taskDescription ?? "") ?? -1)
        }
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        post(.waiting, generation: Int(task.taskDescription ?? "") ?? -1)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let generation = Int(task.taskDescription ?? "") ?? -1
        try? handle?.close()
        handle = nil
        self.task = nil
        guard generation == self.generation, let manifest else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        // Done means the file is its full size: a transfer that ended
        // short without saying so is resumed like one that failed.
        let file = manifest.files[index]
        let have = Self.size(of: partial(manifest).appendingPathComponent(file.path))
        if error == nil, status == 200 || status == 206, have == file.size {
            index += 1
            next(generation: generation)
            return
        }
        if (error as? URLError)?.code == .cancelled, status == 0 { return }
        // A failure waits and resumes where it stopped; the waits grow.
        let delay = retryDelays[min(failures, retryDelays.count - 1)]
        failures += 1
        let why = status >= 400 ? "could not be downloaded (\(status))" : "download paused, retrying"
        Log.info("editor", ["download": manifest.folder, "error": error.map { "\($0)" } ?? "http \(status)",
                            "retry": Int(delay)])
        post(.failed(why), generation: generation)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.delegateQueue.addOperation { self?.next(generation: generation) }
        }
    }
}
