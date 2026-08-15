import CoreGraphics
import Foundation

public struct BreathMember: Codable {
    public var windowID: UInt32
    public var bundleID: String?
    public var appName: String
    public var title: String
    public var frame: CGRect

    public init(windowID: UInt32, bundleID: String?, appName: String,
                title: String, frame: CGRect) {
        self.windowID = windowID
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.frame = frame
    }
}

public struct BreathRecord: Codable {
    public var path: String
    public var orientation: String
    public var members: [BreathMember]

    public init(path: String, orientation: String, members: [BreathMember]) {
        self.path = path
        self.orientation = orientation
        self.members = members
    }
}

public struct UsageRecord: Codable {
    public var count: Int
    public var last: Date
}

/// A retired `marks` key from a pre-0.9.14 file decodes away silently:
/// unknown keys are ignored, and the next save writes the file without it.
public struct PersistedState: Codable {
    public var version: Int?
    public var breaths: [BreathRecord] = []
    public var latestBreath: String?
    public var parked: [UInt32: CGRect] = [:]
    public var usage: [String: UsageRecord]?
    /// The release whose walkthrough has been seen. Machine owned, so it lives
    /// here rather than in the config: nobody should have to edit a file to
    /// stop being shown a tour.
    public var onboardedVersion: String?
}

/// Breaths and parking bookkeeping — saved on every change so a crash or
/// restart can still find and restore everything best-effort.
public final class StateStore {
    public static let defaultFile = Paths.data.appendingPathComponent("state.json")

    public let file: URL
    private var backupFile: URL { file.appendingPathExtension("bak") }

    public private(set) var state = PersistedState()
    private var pendingSave: DispatchWorkItem?
    private var reportedSaveFailure = false

    /// Set when load had to recover — the app surfaces it once the HUD
    /// exists. Breaths are the user's accumulated addresses; losing them
    /// silently is not acceptable.
    public private(set) var bootWarning: String?

    public init(file: URL = StateStore.defaultFile) {
        self.file = file
    }

    public func load() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        if let state = decode(at: file) {
            self.state = state
            // The last-known-good generation: one backup per boot, so a
            // future corruption always has somewhere to fall back to.
            try? FileManager.default.removeItem(at: backupFile)
            try? FileManager.default.copyItem(at: file, to: backupFile)
            Log.info("state: loaded \(state.breaths.count) breaths, \(state.parked.count) parked")
            return
        }
        // Corruption. Quarantine the evidence, fall back to the backup,
        // and say so loudly — silence here costs the user their addresses.
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let quarantine = file.appendingPathExtension("corrupt-\(stamp)")
        try? FileManager.default.copyItem(at: file, to: quarantine)
        Log.error("state: corrupt, quarantined", ["at": quarantine.lastPathComponent])
        if let recovered = decode(at: backupFile) {
            state = recovered
            bootWarning = "state was corrupted — restored from backup (\(recovered.breaths.count) breaths)"
            Log.error("state: restored from backup", ["breaths": recovered.breaths.count])
            save()
        } else {
            bootWarning = "state was corrupted and no backup existed — starting fresh (kept \(quarantine.lastPathComponent))"
            Log.error("state: no usable backup — starting fresh")
        }
    }

    private func decode(at url: URL) -> PersistedState? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: StateMigrations.lift(raw))
    }

    /// Immediate write — explicit user data (breaths) and shutdown.
    public func save() {
        pendingSave?.cancel()
        pendingSave = nil
        state.version = Lodestar.stateVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        do {
            try data.write(to: file, options: .atomic)
            reportedSaveFailure = false
        } catch {
            if !reportedSaveFailure {
                reportedSaveFailure = true
                Log.error("state: SAVE FAILING — breaths are not persisting", ["error": error.localizedDescription])
            }
        }
    }

    /// Coalesced write for high-frequency bookkeeping (usage, parking) — a
    /// summon touches both and must not cost two file writes. Worst case a
    /// hard kill loses half a second of frecency, which is noise.
    private func saveSoon() {
        guard pendingSave == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSave = nil
            self.save()
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - Breaths

    public func breath(at path: String) -> BreathRecord? {
        state.breaths.first { $0.path == path }
    }

    public func isBreathPrefix(_ prefix: String) -> Bool {
        state.breaths.contains { $0.path.hasPrefix(prefix) && $0.path != prefix }
    }

    public func breathWouldShadow(_ path: String) -> String? {
        state.breaths.first { $0.path.hasPrefix(path) && $0.path != path }?.path
    }

    public func setBreath(_ record: BreathRecord) {
        state.breaths.removeAll { $0.path == record.path }
        state.breaths.append(record)
        state.latestBreath = record.path
        save()
    }

    public func deleteBreath(at path: String) -> Bool {
        let before = state.breaths.count
        state.breaths.removeAll { $0.path == path }
        if state.latestBreath == path { state.latestBreath = nil }
        save()
        return state.breaths.count != before
    }

    public func touchLatestBreath(_ path: String) {
        state.latestBreath = path
        save()
    }

    public func rebindBreathMember(path: String, oldID: UInt32, newID: UInt32, title: String) {
        guard let index = state.breaths.firstIndex(where: { $0.path == path }) else { return }
        guard let memberIndex = state.breaths[index].members.firstIndex(where: { $0.windowID == oldID }) else { return }
        state.breaths[index].members[memberIndex].windowID = newID
        state.breaths[index].members[memberIndex].title = title
        save()
    }

    // MARK: - Onboarding

    public var onboardedVersion: String? { state.onboardedVersion }

    public func markOnboarded(version: String) {
        state.onboardedVersion = version
        save()
    }

    // MARK: - Usage (searcher frecency)

    public func touchUsage(_ bundleID: String?) {
        guard let bundleID else { return }
        var usage = state.usage ?? [:]
        var record = usage[bundleID] ?? UsageRecord(count: 0, last: .distantPast)
        record.count += 1
        record.last = Date()
        usage[bundleID] = record
        state.usage = usage
        saveSoon()
    }

    /// Frecency boost on the fuzzy score: how often, decayed by how recently.
    public func usageBoost(_ bundleID: String?) -> Double {
        guard let bundleID, let record = (state.usage ?? [:])[bundleID] else { return 0 }
        let age = Date().timeIntervalSince(record.last)
        let recency: Double = age < 3600 ? 4 : age < 86400 ? 2.5 : age < 604_800 ? 1.5 : 0.8
        return min(min(Double(record.count), 12) * recency * 0.25, 6)
    }

    // MARK: - Parking

    public func setParked(_ spots: [CGWindowID: CGRect]) {
        state.parked = Dictionary(uniqueKeysWithValues: spots.map { (UInt32($0.key), $0.value) })
        saveSoon()
    }

    public var parkedSpots: [CGWindowID: CGRect] {
        Dictionary(uniqueKeysWithValues: state.parked.map { (CGWindowID($0.key), $0.value) })
    }
}
