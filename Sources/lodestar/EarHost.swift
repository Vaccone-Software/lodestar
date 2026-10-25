import Foundation
import LodestarCore
import LodestarEars

/// The draft's settling ear, chosen by tier and kept in memory only while
/// it is wanted: loaded when dictation starts, let go five minutes after
/// the draft closes, as the editor's model is. A model lives under
/// `~/.local/share/lodestar/ears/`; choosing Standard or Full in Settings
/// fetches its pinned files (never on a metered connection), and
/// Automatic uses the best one already there. With none, or when a load
/// fails, the draft runs on Apple's recognizer and its own pipeline
/// alone. The failure stays until a later load works.
///
/// Each tier also brings the language model the draft asks what was
/// meant (`CleanupModel`), fetched once the ear is whole into the models
/// folder the editor uses: where the editor runs the same weights, the two
/// share one copy on disk, and in memory the editor's is asked instead of
/// loading a second.
final class EarHost {
    static let folder = Paths.data.appendingPathComponent("ears", isDirectory: true)
    static let idleSeconds: TimeInterval = 300

    private(set) var ear: SettlingEar?
    private(set) var tier: EarTier = .apple
    private var idle: DispatchWorkItem?
    private var loading = false
    /// The ear now in memory failed its last load. Kept until a later load
    /// of this same ear works, or the tier is replaced. While it is set,
    /// the draft hears with Apple's recognizer alone.
    private var loadFailed = false
    /// What Settings was last told. It is told again only when the words move.
    private var lastStatus = ""
    /// The row's words changed, so Settings can draw them.
    var statusChanged: () -> Void = {}

    /// Fetches a chosen tier's model; `ready` runs when it is whole.
    let download = EditorDownload(root: EarHost.folder)
    var ready: (EarTier) -> Void = { _ in }
    private var named = ""
    private var suited: EarTier = .apple

    /// The tier's model for what was meant, into the editor's folder.
    let cleanupDownload = EditorDownload(root: EditorModels.root)
    /// The editor's model on its way, so the two never fetch one folder at once.
    var editorFetching: () -> EditorManifest? = { nil }
    /// Does the editor hold these weights itself? Then its copy is asked.
    var sharesEditor: (CleanupModel) -> Bool = { _ in false }
    /// Dictation started and the editor's copy is the one asked: load it.
    var prepareShared: () -> Void = {}
    /// The model for what was meant arrived, or the tier settled: the app
    /// rewires the draft and tidies the models folder.
    var cleanupChanged: () -> Void = {}
    /// The draft's own copy, when the editor does not hold the same.
    private(set) var draftModel: DraftModel?

    /// The model the tier this Mac settled on wants, here yet or not.
    var wantedCleanup: CleanupModel? { suited.cleanup }

    /// The model the tier in use writes what was meant with, when it is
    /// whole on this Mac.
    var cleanup: CleanupModel? {
        guard let model = tier.cleanup, EditorModels.directory(for: model.manifest) != nil else { return nil }
        return model
    }

    private func fetchIfMissing() {
        guard suited != .apple else { return }
        if !Self.hasModel(suited), suited.manifest != nil {
            download.fetch(.ear(suited))
            return
        }
        // The ear first: it is what hears. Then the model for what was meant.
        guard let model = suited.cleanup, EditorModels.directory(for: model.manifest) == nil,
              editorFetching()?.folder != model.manifest.folder else { return }
        cleanupDownload.fetch(.cleanup(model))
    }

    init() {
        download.finishedEar = { [weak self] tier in
            guard let self else { return }
            Log.info("draft", ["ear downloaded": tier.rawValue])
            self.configure(self.named)
            // Loaded once now, in the background: Parakeet's first load
            // compiles it for the Neural Engine (about 30 s, cached after),
            // and the first dictation must not be the one that pays.
            self.warm()
            self.rest()
            self.ready(tier)
            // The ear is whole: its model for what was meant follows.
            self.fetchIfMissing()
        }
        cleanupDownload.finishedCleanup = { [weak self] model in
            guard let self else { return }
            Log.info("draft", ["intent model downloaded": model.rawValue])
            self.configure(self.named)
            self.cleanupChanged()
        }
    }

    /// A tier's model folder: its pinned download's, or, for a model put
    /// there by hand, one named after its engine.
    static func modelFolder(_ tier: EarTier) -> URL? {
        if let manifest = tier.manifest {
            return folder.appendingPathComponent(EditorManifest(manifest).folder, isDirectory: true)
        }
        return tier.engine.map { folder.appendingPathComponent($0, isDirectory: true) }
    }

    static func hasModel(_ tier: EarTier) -> Bool {
        guard let url = modelFolder(tier) else { return false }
        if let manifest = tier.manifest { return EditorModels.isComplete(url, EditorManifest(manifest)) }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return !files.isEmpty
    }

    /// The tier the setting names, resolved for this Mac. A tier named
    /// outright whose model is not here yet is fetched, and taken up when
    /// it is whole.
    func configure(_ named: String) {
        self.named = named
        // The tier this Mac suits: the one named, or for Automatic the
        // largest the memory allows. A tier named outright is fetched now;
        // Automatic waits for the first dictation, so nobody who never
        // dictates downloads a model. Meanwhile the best one here is used.
        suited = EarTier.resolved(named, memoryGB: EditorEngine.physicalGB, hasModel: { _ in true })
        if !named.isEmpty { fetchIfMissing() }
        if let fetching = download.model, fetching != .ear(suited) { download.cancel(keepingPartial: true) }
        if let fetching = cleanupDownload.model, fetching != suited.cleanup.map(ModelID.cleanup) {
            cleanupDownload.cancel(keepingPartial: true)
        }
        defer {
            adoptCleanup()
            noteStatus()
        }
        let next = EarTier.resolved(named, memoryGB: EditorEngine.physicalGB, hasModel: Self.hasModel)
        guard next != tier || (ear == nil && next != .apple) else { return }
        ear?.unload()
        ear = nil
        tier = next
        // The ear just installed has not been asked to load. A failure
        // belonged to the one it replaces.
        loadFailed = false
        if let engine = next.engine, let url = Self.modelFolder(next) {
            ear = EarFactory.make(engine, folder: url)
        }
        Log.info("draft", ["ear": next.rawValue, "engine": next.engine ?? "none", "ready": ear != nil])
        // One model on disk at a time, as the editor keeps it: once the
        // tier this Mac settled on is whole (or needs none), the others'
        // pinned downloads go.
        if next == suited, next == .apple || Self.hasModel(next) {
            Self.removeAll(except: next)
            cleanupChanged()
        }
    }

    /// The draft's own copy follows the tier: made when the tier's model
    /// is here and the editor does not hold it, let go otherwise.
    private func adoptCleanup() {
        let wanted = cleanup.flatMap { sharesEditor($0) ? nil : $0 }
        guard wanted != draftModel?.model else { return }
        if let old = draftModel { Task { await old.release() } }
        draftModel = wanted.map { DraftModel(model: $0) }
    }

    /// The editor changed what it holds: whose copy is asked may change.
    func editorChanged() {
        adoptCleanup()
    }

    /// Every pinned ear but `keep`, and any half-finished download of one.
    /// Only Lodestar's own folders: a model put here by hand stays.
    @discardableResult
    static func removeAll(except keep: EarTier, root: URL = folder) -> [EarTier] {
        var removed: [EarTier] = []
        let kept = keep.manifest.map { EditorManifest($0).folder }
        for tier in EarTier.allCases where tier != keep {
            // Full and Max hear with the same ear.
            guard let manifest = tier.manifest.map(EditorManifest.init), manifest.folder != kept else { continue }
            let model = root.appendingPathComponent(manifest.folder, isDirectory: true)
            let partial = root.appendingPathComponent(".\(manifest.folder).partial", isDirectory: true)
            for url in [model, partial] where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                if url == model { removed.append(tier) }
                Log.info("draft", ["ear removed": url.lastPathComponent])
            }
        }
        return removed
    }

    /// What the Settings row says: a load that failed (the draft is on
    /// Apple's recognizer), the model on its way, or the ear in use.
    var status: String {
        Self.statusLine(tier: tier, named: named,
                        fetching: download.status ?? cleanupDownload.status,
                        loadFailed: loadFailed)
    }

    /// The row's words for a tier. A failed load is said ahead of a download:
    /// the cleanup model arriving must not hide that the ear did not load.
    static func statusLine(tier: EarTier, named: String, fetching: String?,
                           loadFailed: Bool) -> String {
        if loadFailed, tier != .apple {
            return "\(tier.name) failed to load, so Apple's recognizer is being used"
        }
        if let fetching { return fetching }
        switch tier {
        case .apple: return named == "apple" ? "" : "Not on this Mac yet"
        case .standard, .full, .max: return "\(tier.name) in use"
        }
    }

    /// Settings hears when the row's words have moved.
    private func noteStatus() {
        let next = status
        guard next != lastStatus else { return }
        lastStatus = next
        statusChanged()
    }

    /// For the tests: an ear and the tier the row would be speaking about,
    /// without a model folder on disk.
    func stageForTesting(tier: EarTier, named: String, ear: SettlingEar? = nil, loadFailed: Bool = false) {
        self.ear = ear
        self.tier = tier
        self.named = named
        self.loadFailed = loadFailed
    }

    /// Dictation started: the ear loads now, off the main thread, if it
    /// is not already in memory.
    func warm() {
        idle?.cancel()
        fetchIfMissing()
        if let model = cleanup {
            if let draftModel { Task.detached { await draftModel.load() } } else if sharesEditor(model) { prepareShared() }
        }
        guard let ear, !ear.isLoaded, !loading else { return }
        loading = true
        let loadingEar = ear
        Task.detached { [weak self] in
            let began = Date()
            var failed = false
            do {
                try await loadingEar.load()
                Log.info("draft", ["ear": loadingEar.name, "loaded ms": Int(Date().timeIntervalSince(began) * 1000)])
            } catch {
                failed = true
                Log.info("draft", ["ear": loadingEar.name, "load failed": "\(error)"])
            }
            let outcome = failed
            await MainActor.run { self?.finishLoad(of: loadingEar, failed: outcome) }
        }
    }

    /// `ear`'s load ended. A failure stays until a later load of this same
    /// ear works. A load for an ear since replaced does not count.
    private func finishLoad(of ear: SettlingEar, failed: Bool) {
        loading = false
        if (self.ear as AnyObject?) === (ear as AnyObject) { loadFailed = failed }
        noteStatus()
    }

    /// The draft closed: the ear lets its memory go after a while.
    func rest() {
        idle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.ear?.unload()
            if let model = self?.draftModel { Task { await model.release() } }
        }
        idle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleSeconds, execute: work)
    }
}
