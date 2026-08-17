import Foundation

/// Where observations live: `~/.local/share`, beside the clipboard and the
/// state file, and deliberately not in `~/.config`, which is what people
/// commit to a dotfiles repository. Writes are coalesced, because this is fed
/// from the event tap and a keystroke must never wait on a disk.
public final class ObservationStore {
    public static let defaultFile = Paths.data.appendingPathComponent("observations.json")

    public let file: URL
    public private(set) var observations = Observations()
    private var pendingSave: DispatchWorkItem?
    private var enabled = true

    public init(file: URL = ObservationStore.defaultFile) {
        self.file = file
    }

    /// Off means nothing is recorded and nothing is written. Somebody who does
    /// not want to be watched by their own window manager should get exactly
    /// that, not a smaller file.
    public func setEnabled(_ on: Bool) {
        enabled = on
    }

    public func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let decoded = try? JSONDecoder().decode(Observations.self, from: data) else {
            // Unreadable rather than absent. Observations are a convenience,
            // never a source of truth, so the honest move is to start over
            // instead of trying to rescue a file nobody would miss.
            Log.error("observations: unreadable, starting fresh")
            return
        }
        observations = decoded
        // The launcher was called the searcher until 0.12.0. The counts are the
        // same behaviour under a new word, so they move rather than reset.
        if let old = observations.verbs.removeValue(forKey: "searcher") {
            observations.verbs["launcher", default: 0] += old
            saveSoon()
        }
    }

    /// Mutate and persist. The closure keeps every call site down to the one
    /// line that says what happened.
    public func record(_ change: (inout Observations) -> Void) {
        guard enabled else { return }
        change(&observations)
        saveSoon()
    }

    public func clear() {
        observations = Observations()
        pendingSave?.cancel()
        pendingSave = nil
        try? FileManager.default.removeItem(at: file)
    }

    private var clearRequestFile: URL {
        file.deletingLastPathComponent().appendingPathComponent("observations.clear-request")
    }

    /// A CLI clear has to reach the running instance, or the copy it holds in
    /// memory is written straight back over the deletion. The clipboard learned
    /// this first; the handshake is the same file-as-a-flag.
    public func requestClear() {
        try? Data().write(to: clearRequestFile)
    }

    public func consumeClearRequest() -> Bool {
        guard FileManager.default.fileExists(atPath: clearRequestFile.path) else { return false }
        try? FileManager.default.removeItem(at: clearRequestFile)
        return true
    }

    public func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        save()
    }

    private func saveSoon() {
        guard pendingSave == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSave = nil
            self.save()
        }
        pendingSave = work
        // Longer than the state store's half second: nothing here is worth
        // losing sleep over if a crash takes the last few events with it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func save() {
        guard enabled else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(observations) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
