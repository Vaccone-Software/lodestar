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
    /// Which boot the parked window ids belong to.
    ///
    /// A `CGWindowID` is only meaningful within a login session (FINDINGS
    /// §4), so after an unclean shutdown a recycled id could make an
    /// unrelated window look parked — and the next quit would yank it to a
    /// frame it never had. Parking is restored only when this matches the
    /// running session.
    public var parkedSession: String?
    public var usage: [String: UsageRecord]?
    /// The walk's progress. Machine owned, so it lives here rather than in
    /// the config: nobody should have to edit a file to stop being shown a
    /// tour. The step survives a restart because the walk resumes, never
    /// restarts; the completed version is what stops the auto-show. The old
    /// deck's `onboardedVersion` is deliberately not read: everyone sees
    /// the walk once, because what the deck taught was not this.
    public var walkStep: Int?
    public var walkCompletedVersion: String?
    /// Meeting occurrences already joined or dismissed — the chip never
    /// resurrects one. Pruned to live occurrences on every write.
    public var meetingSpent: [String]?
    /// When each coach suggestion first took the standing slot, keyed by
    /// `kind:target`.
    ///
    /// Machine owned and persisted because the cue wait is measured from
    /// it. Held only in memory it restarted on every launch, and the wait
    /// is four days: across 120 launches on the author's machine the
    /// longest uninterrupted run was 2.3 days, so the escape hatch that
    /// promises a cue-having suggestion goes out eventually had never once
    /// opened. An auto-update alone is enough to reset it.
    public var coachStandingSince: [String: Date]?
}

/// The corruption ritual, shared by every store that keeps user data:
/// stamp the moment, set the evidence aside, return where it went.
/// `keepOriginal` copies instead of moving — for a caller about to try a
/// backup that still needs the original in place.
public enum Quarantine {
    @discardableResult
    public static func setAside(_ file: URL, keepOriginal: Bool = false) -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let quarantine = file.appendingPathExtension("corrupt-\(stamp)")
        if keepOriginal {
            try? FileManager.default.copyItem(at: file, to: quarantine)
        } else {
            try? FileManager.default.moveItem(at: file, to: quarantine)
        }
        return quarantine
    }
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
        let quarantine = Quarantine.setAside(file, keepOriginal: true)
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
            Paths.restrict(file)
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

    // MARK: - The walk

    public var walkStep: Int? { state.walkStep }
    public var walkCompletedVersion: String? { state.walkCompletedVersion }

    public func setWalkStep(_ step: Int) {
        state.walkStep = step
        saveSoon()
    }

    public func markWalkCompleted(version: String) {
        state.walkCompletedVersion = version
        save()
    }

    // MARK: - Meetings

    public var meetingSpent: Set<String> { Set(state.meetingSpent ?? []) }

    public func setMeetingSpent(_ spent: Set<String>) {
        state.meetingSpent = spent.sorted()
        saveSoon()
    }

    // MARK: - The coach

    /// When this suggestion first took the slot. Stamps on first sight and
    /// returns the same answer forever after, so the cue wait counts
    /// wall-clock days rather than the life of one process.
    public func coachStandingSince(_ id: String, now: Date = Date()) -> Date {
        var map = state.coachStandingSince ?? [:]
        if let stamped = map[id] { return stamped }
        map[id] = now
        // Bounded, and the eviction can never disturb a live suggestion:
        // only one stands at a time, so anything old enough to be dropped
        // has long since been answered, parked, or outgrown.
        if map.count > Self.coachStandingCap {
            for key in map.sorted(by: { $0.value < $1.value })
                .prefix(map.count - Self.coachStandingCap).map(\.key) {
                map.removeValue(forKey: key)
            }
        }
        state.coachStandingSince = map
        saveSoon()
        return now
    }

    static let coachStandingCap = 64

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
        state.parkedSession = Lodestar.bootSession
        saveSoon()
    }

    /// Parked windows, but only the ones this boot could have parked.
    public var parkedSpots: [CGWindowID: CGRect] {
        guard Lodestar.isCurrentBootSession(state.parkedSession) else {
            if !state.parked.isEmpty {
                Log.info("state: dropping \(state.parked.count) parked spots from an earlier session")
            }
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: state.parked.map { (CGWindowID($0.key), $0.value) })
    }
}
