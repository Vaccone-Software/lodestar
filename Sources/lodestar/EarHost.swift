import Foundation
import LodestarCore
import LodestarEars

/// The draft's settling ear, chosen by tier and kept in memory only while
/// it is wanted: loaded when dictation starts, let go five minutes after
/// the draft closes, as the editor's model is. A model lives under
/// `~/.local/share/lodestar/ears/`; choosing Standard or Full in Settings
/// fetches its pinned files (never on a metered connection), and
/// Automatic uses the best one already there. With none, the draft runs
/// on Apple's recognizer and its own pipeline alone.
final class EarHost {
    static let folder = Paths.data.appendingPathComponent("ears", isDirectory: true)
    static let idleSeconds: TimeInterval = 300

    private(set) var ear: SettlingEar?
    private(set) var tier: EarTier = .apple
    private var idle: DispatchWorkItem?
    private var loading = false

    /// Fetches a chosen tier's model; `ready` runs when it is whole.
    let download = EditorDownload(root: EarHost.folder)
    var ready: (EarTier) -> Void = { _ in }
    private var named = ""
    private var suited: EarTier = .apple

    private func fetchIfMissing() {
        guard suited != .apple, !Self.hasModel(suited), suited.manifest != nil else { return }
        download.fetch(.ear(suited))
    }

    init() {
        download.finishedEar = { [weak self] tier in
            guard let self else { return }
            Log.info("draft", ["ear downloaded": tier.rawValue])
            self.configure(self.named)
            self.ready(tier)
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
        let next = EarTier.resolved(named, memoryGB: EditorEngine.physicalGB, hasModel: Self.hasModel)
        guard next != tier || (ear == nil && next != .apple) else { return }
        ear?.unload()
        ear = nil
        tier = next
        if let engine = next.engine, let url = Self.modelFolder(next) {
            ear = EarFactory.make(engine, folder: url)
        }
        Log.info("draft", ["ear": next.rawValue, "engine": next.engine ?? "none", "ready": ear != nil])
    }

    /// What the Settings row says: the ear in use, or the one on its way.
    var status: String {
        if let fetching = download.status { return fetching }
        switch tier {
        case .apple: return ear == nil && named == "apple" ? "Off" : "None on this Mac yet"
        case .standard: return "Standard in use"
        case .full: return "Full in use"
        }
    }

    /// Dictation started: the ear loads now, off the main thread, if it
    /// is not already in memory.
    func warm() {
        idle?.cancel()
        fetchIfMissing()
        guard let ear, !ear.isLoaded, !loading else { return }
        loading = true
        Task.detached { [weak self] in
            let began = Date()
            do {
                try await ear.load()
                Log.info("draft", ["ear": ear.name, "loaded ms": Int(Date().timeIntervalSince(began) * 1000)])
            } catch {
                Log.info("draft", ["ear": ear.name, "load failed": "\(error)"])
            }
            await MainActor.run { self?.loading = false }
        }
    }

    /// The draft closed: the ear lets its memory go after a while.
    func rest() {
        idle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.ear?.unload() }
        idle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleSeconds, execute: work)
    }
}
