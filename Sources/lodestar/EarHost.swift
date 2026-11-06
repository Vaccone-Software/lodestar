import Foundation
import LodestarCore
import LodestarEars

/// The draft's settling ear, chosen by tier and kept in memory only while
/// it is wanted: loaded when dictation starts, let go thirty minutes after
/// the draft closes, or at once when macOS says memory is critical. (Measured
/// on the maker's record: kept five minutes, 62% of drafts found it warm;
/// kept thirty, 83%. It is 2.5 GB, and the 35B model beside it is not kept
/// that long.) A model lives under
/// `~/.local/share/lodestar/ears/`; choosing Standard or Full in Settings
/// fetches its pinned files (never on a metered connection), and
/// Automatic uses the best one already there. With none, the draft runs
/// on Apple's recognizer and its own pipeline alone.
///
/// Each tier also brings the language model the draft asks what was
/// meant (`CleanupModel`), fetched once the ear is whole into the models
/// folder the editor uses: where the editor runs the same weights, the two
/// share one copy on disk, and in memory the editor's is asked instead of
/// loading a second.
final class EarHost {
    static let folder = Paths.data.appendingPathComponent("ears", isDirectory: true)
    /// How long the ear stays after the draft closes.
    static let idleSeconds: TimeInterval = 1800
    /// How long the draft's own copy of the language model stays: its own
    /// policy, shorter, since on Max it is 20 GB shared with the editor.
    static let modelIdleSeconds: TimeInterval = 300

    private(set) var ear: SettlingEar?
    private(set) var tier: EarTier = .apple
    private var idle: DispatchWorkItem?
    private var modelIdle: DispatchWorkItem?
    private var loading = false
    /// Between dictation starting and the draft closing: the ear is being
    /// used, whatever the memory says.
    private var inUse = false
    /// macOS said memory was short while the ear was in use: it goes the
    /// moment the draft closes, not thirty minutes on.
    private var pressed = false
    /// The same, for the language model, which goes on a warning too.
    private var modelPressed = false
    private var pressure: DispatchSourceMemoryPressure?
    private let clock: Clock

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
    /// The ear finished loading: a draft open at that moment hears again
    /// the phrases the cold ear missed.
    var loaded: () -> Void = {}
    /// Whether a language model's weights are on this Mac.
    var hasCleanup: (CleanupModel) -> Bool = { EditorModels.directory(for: $0.manifest) != nil }

    /// The model the tier this Mac settled on wants, here yet or not.
    var wantedCleanup: CleanupModel? { suited.cleanup }

    /// The model the tier in use writes what was meant with, when it is
    /// whole on this Mac.
    var cleanup: CleanupModel? {
        guard let model = tier.cleanup, hasCleanup(model) else { return nil }
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

    init(clock: Clock = .live) {
        self.clock = clock
        // The language model goes on a warning, the editor's copy by the
        // editor's own handler and the draft's copy here, and on Max that is
        // the 20 GB the warning is about. It costs little, since it is cold
        // for any draft five minutes after the last. The ear goes only when
        // memory is critical: on the maker's Mac the editor was let go by a
        // warning ninety times in twenty-two days, and an ear that went with
        // it would be cold again for a quarter of the day's drafts.
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self, weak pressure] in
            guard let event = pressure?.data else { return }
            if event.contains(.critical) { self?.memoryPressure() } else { self?.memoryWarning() }
        }
        pressure.resume()
        self.pressure = pressure
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
        defer { adoptCleanup() }
        let next = EarTier.resolved(named, memoryGB: EditorEngine.physicalGB, hasModel: Self.hasModel)
        guard next != tier || (ear == nil && next != .apple) else { return }
        ear?.unload()
        ear = nil
        tier = next
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

    /// What the Settings row says: the ear in use, or the one on its way.
    var status: String {
        if let fetching = download.status ?? cleanupDownload.status { return fetching }
        switch tier {
        case .apple: return named == "apple" ? "" : "Not on this Mac yet"
        case .standard, .full, .max: return "\(tier.name) in use"
        }
    }

    /// Dictation started: the ear loads now, off the main thread, if it
    /// is not already in memory. The language model follows only once the
    /// ear is in, or has failed: loaded together they fight for the same
    /// disk and the same GPU, and the small one, the one that hears, took
    /// ten seconds. Listening itself waits for neither.
    func warm() {
        idle?.cancel()
        modelIdle?.cancel()
        inUse = true
        fetchIfMissing()
        guard let ear, !ear.isLoaded else { loadModels(); return }
        // A load already on its way starts the models when it is done.
        guard !loading else { return }
        loading = true
        Task.detached { [weak self] in
            let began = Date()
            let whole: Bool
            do {
                try await ear.load()
                whole = true
                Log.info("draft", ["ear": ear.name, "loaded ms": Int(Date().timeIntervalSince(began) * 1000)])
            } catch {
                whole = false
                Log.info("draft", ["ear": ear.name, "load failed": "\(error)"])
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loading = false
                if whole { self.loaded() }
                self.loadModels()
                // Memory ran short while it loaded and nothing is using it.
                if self.pressed, !self.inUse { self.letGo() }
                if self.modelPressed, !self.inUse { self.letModelGo() }
            }
        }
    }

    /// The language model for what was meant: loaded, or the editor's
    /// copy of the same weights prepared.
    private func loadModels() {
        guard let model = cleanup else { return }
        if let draftModel { Task.detached { await draftModel.load() } } else if sharesEditor(model) { prepareShared() }
    }

    /// The draft closed: the ear lets its memory go after a while, and the
    /// language model, which is far larger, sooner.
    func rest() {
        idle?.cancel()
        modelIdle?.cancel()
        inUse = false
        let models = DispatchWorkItem { [weak self] in
            if let model = self?.draftModel { Task { await model.release() } }
        }
        modelIdle = models
        clock.after(Self.modelIdleSeconds, models)
        if modelPressed { letModelGo() }
        if pressed { letGo(); return }
        let ears = DispatchWorkItem { [weak self] in self?.ear?.unload() }
        idle = ears
        clock.after(Self.idleSeconds, ears)
    }

    /// macOS says memory is critical: a resting ear and language model go
    /// now. Ones in use go when their draft closes, so a dictation never loses
    /// its ear mid-sentence to a signal that may have passed.
    func memoryPressure() {
        Log.info("draft", ["memory pressure": true, "ear in use": inUse || loading])
        if inUse || loading {
            pressed = true
            modelPressed = true
        } else {
            letGo()
            letModelGo()
        }
    }

    /// macOS says memory is short: the draft's own language model goes now,
    /// not when its idle time is up, or when its draft closes if one is open.
    /// The ear stays. See `init`.
    func memoryWarning() {
        Log.info("draft", ["memory warning": true, "in use": inUse || loading])
        if inUse || loading { modelPressed = true } else { letModelGo() }
    }

    /// The idle timer is left to run: it finds nothing to do, unless a load
    /// was still on its way when this asked, and then it is what lets go.
    private func letModelGo() {
        modelPressed = false
        if let model = draftModel { Task { await model.release() } }
    }

    private func letGo() {
        pressed = false
        idle?.cancel()
        guard !loading else { return }
        ear?.unload()
    }

    #if DEBUG
    /// A stage's ear and model, in place of what a tier's files would make.
    func install(ear: SettlingEar?, tier: EarTier, model: DraftModel? = nil) {
        self.ear = ear
        self.tier = tier
        draftModel = model
    }
    #endif
}
