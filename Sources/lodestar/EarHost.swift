import Foundation
import LodestarCore
import LodestarEars
import Stoic

/// The draft's settling ears, sized by the Mac (`EarTier`), kept in memory
/// only while wanted: Parakeet in front, which ⏎ waits for, and on a Mac
/// with room Qwen3-ASR behind it. Loaded when dictation starts, let go thirty minutes after
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
    /// The ear behind the quick one, when the setup has one.
    private(set) var backgroundEar: SettlingEar?
    /// The live recognizer, once its files are here: loaded and warmed at
    /// launch and kept, so no draft waits for it (`LiveEar`).
    private(set) var live: LiveEar?
    private var liveWarm = false
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
    /// The same, for the language model and the ear behind, which go on a
    /// warning too.
    private var modelPressed = false
    private var pressure: DispatchSourceMemoryPressure?
    private let clock: Clock

    /// Fetches a setup's ears, one engine at a time; `ready` runs when one
    /// is whole.
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
        // The live recognizer, then the ear that hears first, then the one
        // behind it.
        if let missing = ([suited.liveEngine].compactMap { $0 } + suited.engines).first(where: { !Self.hasEngine($0) }) {
            if download.model != .ear(missing) { download.fetch(.ear(missing)) }
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
        download.finishedEar = { [weak self] engine in
            guard let self else { return }
            Log.info("draft", ["ear downloaded": engine])
            self.configure(self.named)
            guard engine != EarEngines.nemotron else {
                // Words on the draft as they are said, from the next draft.
                self.fetchIfMissing()
                return
            }
            // Loaded once now, in the background: Parakeet's first load
            // compiles it for the Neural Engine (about 30 s, cached after),
            // and the first dictation must not be the one that pays.
            self.warm()
            self.rest()
            self.ready(self.tier)
            // The next ear, or the model for what was meant, follows.
            self.fetchIfMissing()
        }
        cleanupDownload.finishedCleanup = { [weak self] model in
            guard let self else { return }
            Log.info("draft", ["intent model downloaded": model.rawValue])
            self.configure(self.named)
            self.cleanupChanged()
        }
    }

    /// An engine's model folder: its pinned download's, or, for a model put
    /// there by hand, one named after the engine.
    static func modelFolder(_ engine: String) -> URL {
        if let manifest = EarEngines.manifest(engine) {
            return folder.appendingPathComponent(EditorManifest(manifest).folder, isDirectory: true)
        }
        return folder.appendingPathComponent(engine, isDirectory: true)
    }

    static func hasEngine(_ engine: String) -> Bool {
        let url = modelFolder(engine)
        if let manifest = EarEngines.manifest(engine) { return EditorModels.isComplete(url, EditorManifest(manifest)) }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return !files.isEmpty
    }

    /// Every ear the setup runs is on this Mac.
    static func hasModel(_ tier: EarTier) -> Bool {
        tier.engines.allSatisfy(hasEngine)
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
        if case .ear(let engine)? = download.model, !suited.engines.contains(engine) { download.cancel(keepingPartial: true) }
        if let fetching = cleanupDownload.model, fetching != suited.cleanup.map(ModelID.cleanup) {
            cleanupDownload.cancel(keepingPartial: true)
        }
        defer { adoptCleanup(); adoptLive() }
        let next = EarTier.resolved(named, memoryGB: EditorEngine.physicalGB, hasModel: Self.hasModel)
        guard next != tier || (ear == nil && next != .apple) else { return }
        // An ear the new setup runs too stays as it is, loaded or not.
        func make(_ engine: String?, keeping old: SettlingEar?) -> SettlingEar? {
            guard let engine else { old?.unload(); return nil }
            if let old, old.name == engine { return old }
            old?.unload()
            // Qwen3-ASR hears in the models service; Parakeet here.
            return EarFactory.make(engine, folder: Self.modelFolder(engine), qwen: { ServiceEar(name: $0, folder: $1) })
        }
        ear = make(next.engine, keeping: ear)
        backgroundEar = make(next.backgroundEngine, keeping: backgroundEar)
        tier = next
        Log.info("draft", ["ear": next.rawValue, "engine": next.engine ?? "none",
                           "behind": next.backgroundEngine ?? "none", "ready": ear != nil])
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

    /// The live recognizer follows the setup this Mac suits, whether or not
    /// its ears are here yet: made and warmed once its files are whole, let
    /// go when the setup has none.
    private func adoptLive() {
        guard let engine = suited.liveEngine, Self.hasEngine(engine) else {
            if let old = live { Task { await old.unload() } }
            live = nil
            liveWarm = false
            return
        }
        if live == nil { live = LiveEar(folder: Self.modelFolder(engine)) }
        prepareLive()
    }

    /// Load and warm the live recognizer in the background, if it is not.
    private func prepareLive() {
        guard let live, !liveWarm else { return }
        liveWarm = true
        Task(priority: .utility) { [weak self] in
            await live.prepare()
            let warm = await live.isWarm
            await MainActor.run { [weak self] in if !warm { self?.liveWarm = false } }
        }
    }

    /// The editor changed what it holds: whose copy is asked may change.
    func editorChanged() {
        adoptCleanup()
    }

    /// Every pinned ear `keep` does not run, and any half-finished download
    /// of one. Only Lodestar's own folders: a model put here by hand stays.
    @discardableResult
    static func removeAll(except keep: EarTier, root: URL = folder) -> [String] {
        var removed: [String] = []
        let kept = Set(([keep.liveEngine].compactMap { $0 } + keep.engines)
            .compactMap(EarEngines.manifest).map { EditorManifest($0).folder })
        let known = EarEngines.all + [ParakeetEar.Variant.v3.name]
        for engine in known {
            guard let manifest = EarEngines.manifest(engine).map(EditorManifest.init), !kept.contains(manifest.folder) else { continue }
            let model = root.appendingPathComponent(manifest.folder, isDirectory: true)
            let partial = root.appendingPathComponent(".\(manifest.folder).partial", isDirectory: true)
            for url in [model, partial] where FileManager.default.fileExists(atPath: url.path) {
                Log.attemptUnlessAbsent("draft: could not remove an ear's files", ["name": url.lastPathComponent]) {
                    try FileManager.default.removeItem(at: url)
                }
                if url == model { removed.append(engine) }
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
        case .small, .standard, .full, .max:
            let live = live != nil ? [EarEngines.nemotron] : []
            let names = (live + tier.engines).map(EarEngines.displayName)
            return (names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names.joined())
                + " in use"
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
        // Let go under pressure: warm again, for the next draft.
        prepareLive()
        // A load already on its way starts the models when it is done.
        guard !loading else { return }
        // The quick ear first, then the one behind it: each starts hearing
        // the moment it is in.
        let cold = [ear, backgroundEar].compactMap { $0 }.filter { !$0.isLoaded }
        guard !cold.isEmpty else { loadModels(); return }
        loading = true
        // An ordinary Task, not a detached one, so the ear's load runs with the
        // ambient context that started it (Stoic's events from it reach the
        // log). It is not isolated to an actor here, so it still runs off the
        // main thread, and at the default priority a detached task had: a Task
        // takes its creator's, which is the main thread's, and a model load
        // should not.
        Task(priority: .medium) { [weak self] in
            for ear in cold {
                let began = ContinuousClock.now
                do {
                    try await ear.load()
                    Log.info("draft", ["ear": ear.name, "loaded ms": Int(began.secondsElapsed * 1000)])
                    await MainActor.run { [weak self] in self?.loaded() }
                } catch {
                    Log.info("draft", ["ear": ear.name, "load failed": "\(error)"])
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.loading = false
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
        // As in `warm`: an ordinary Task, at the priority a detached one had.
        if let draftModel { Task(priority: .medium) { await draftModel.load() } } else if sharesEditor(model) { prepareShared() }
    }

    /// Phrases being heard outside the draft (`lodestar transcribe`).
    private var hearing = 0

    /// A phrase heard outside the draft (`lodestar transcribe`), by the ear
    /// whose words dictation keeps: the one behind when this Mac's setup
    /// has one, the quick one otherwise. A cold ear loads as it would for a
    /// draft, through the same `loading` (one load at a time, never two of
    /// one ear), and is let go on the same thirty minutes when no draft
    /// holds it. `done` runs on main.
    func hear(_ samples: [Float], context: [String],
              done: @escaping (Result<(heard: Heard, ear: String), Error>) -> Void) {
        guard let chosen = backgroundEar ?? ear else { return done(.failure(Transcribe.Failure.noEar)) }
        idle?.cancel()
        hearing += 1
        Task(priority: .medium) { [weak self] in
            let result: Result<(heard: Heard, ear: String), Error>
            do {
                if !chosen.isLoaded { try await self?.load(chosen) }
                result = .success((try await chosen.transcribe(samples, context: context), chosen.name))
            } catch {
                result = .failure(error)
            }
            await MainActor.run { [weak self] in
                if let self {
                    self.hearing -= 1
                    if !self.inUse, self.hearing == 0 { self.restEars() }
                }
                done(result)
            }
        }
    }

    /// Loads one ear for a phrase: waits out a load already on its way (a
    /// draft's), or takes `loading` for its own, so a draft starting
    /// meanwhile waits for it as it would for its own.
    private func load(_ chosen: SettlingEar) async throws {
        let mine = await MainActor.run { () -> Bool in
            guard !loading else { return false }
            loading = true
            return true
        }
        guard mine else {
            while await MainActor.run(body: { loading }) {
                // Cancellation only ends the wait sooner: the ear is asked anyway.
                do { try await Ambient.sleep(for: .milliseconds(50)) } catch { break }
            }
            return
        }
        let began = ContinuousClock.now
        do {
            try await chosen.load()
            Log.info("draft", ["ear": chosen.name, "loaded ms": Int(began.secondsElapsed * 1000), "for": "transcribe"])
        } catch {
            await MainActor.run { loading = false }
            throw error
        }
        await MainActor.run { [weak self] in
            guard let self else { return }
            self.loading = false
            self.loaded()
            // A draft that opened while this loaded asked for its models.
            if self.inUse { self.loadModels() }
        }
    }

    /// The ears go after their idle time, as when a draft closes; the
    /// language model's own timer is not touched.
    private func restEars() {
        if pressed { letGo(); return }
        let ears = DispatchWorkItem { [weak self] in
            self?.ear?.unload()
            self?.backgroundEar?.unload()
        }
        idle = ears
        clock.after(Self.idleSeconds, ears)
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
        let ears = DispatchWorkItem { [weak self] in
            self?.ear?.unload()
            self?.backgroundEar?.unload()
        }
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

    /// macOS says memory is short: the draft's own language model and the
    /// ear behind go now, not when their idle time is up, or when their
    /// draft closes if one is open. The quick ear stays. See `init`.
    func memoryWarning() {
        Log.info("draft", ["memory warning": true, "in use": inUse || loading])
        if inUse || loading { modelPressed = true } else { letModelGo() }
    }

    /// The idle timer is left to run: it finds nothing to do, unless a load
    /// was still on its way when this asked, and then it is what lets go.
    private func letModelGo() {
        modelPressed = false
        // The ear behind goes with it: it is a gigabyte or more, and the
        // quick ear still hears.
        if !loading { backgroundEar?.unload() }
        if let model = draftModel { Task { await model.release() } }
    }

    private func letGo() {
        pressed = false
        idle?.cancel()
        guard !loading else { return }
        ear?.unload()
        backgroundEar?.unload()
        // Critical: the live recognizer too. The next draft hears with
        // Apple's while it warms again.
        if let live {
            liveWarm = false
            Task { await live.unload() }
        }
    }

    #if DEBUG
    /// A stage's ear and model, in place of what a tier's files would make.
    func install(ear: SettlingEar?, behind: SettlingEar? = nil, tier: EarTier, model: DraftModel? = nil) {
        self.ear = ear
        backgroundEar = behind
        self.tier = tier
        draftModel = model
    }
    #endif
}
