import Foundation
import LodestarCore
import LodestarEars

/// The draft's settling ear, chosen by tier and kept in memory only while
/// it is wanted: loaded when dictation starts, let go five minutes after
/// the draft closes, as the editor's model is. A model is read from
/// `~/.local/share/lodestar/ears/<engine>`; with none there, the draft
/// runs on Apple's recognizer and its own pipeline alone.
final class EarHost {
    static let folder = Paths.data.appendingPathComponent("ears", isDirectory: true)
    static let idleSeconds: TimeInterval = 300

    private(set) var ear: SettlingEar?
    private(set) var tier: EarTier = .apple
    private var idle: DispatchWorkItem?
    private var loading = false

    static func modelFolder(_ tier: EarTier) -> URL? {
        tier.engine.map { folder.appendingPathComponent($0, isDirectory: true) }
    }

    static func hasModel(_ tier: EarTier) -> Bool {
        guard let url = modelFolder(tier),
              let files = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        return !files.isEmpty
    }

    /// The tier the setting names, resolved for this Mac.
    func configure(_ named: String) {
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

    /// Dictation started: the ear loads now, off the main thread, if it
    /// is not already in memory.
    func warm() {
        idle?.cancel()
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
