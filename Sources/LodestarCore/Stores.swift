import CoreGraphics
import Foundation
import StoicStore
import Synchronization

public struct BreathMember: Codable, Sendable {
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

public struct BreathRecord: Codable, Sendable {
    public var path: String
    public var orientation: String
    public var members: [BreathMember]

    public init(path: String, orientation: String, members: [BreathMember]) {
        self.path = path
        self.orientation = orientation
        self.members = members
    }
}

public struct UsageRecord: Codable, Sendable {
    public var count: Int
    public var last: Date
}

/// A retired `marks` key from a pre-0.9.14 file decodes away silently:
/// unknown keys are ignored, and the next save writes the file without it.
public struct PersistedState: Codable, Sendable {
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
    /// The door chosen on the welcome (`Walk.Door`'s raw value). A walk
    /// resumes only inside the door it began in; without one, the welcome
    /// asks again.
    public var walkDoor: String?
    /// When the hand accepted the editor reading its fields on this Mac.
    /// Machine owned, like the walk: consent is given by a person at a
    /// Mac, not carried in a config file copied to another one.
    public var editorConsentAt: Date?
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
    /// The curriculum's record, by lesson: offers made, when, and whether
    /// the hand completed it. Machine owned, like the walk's step.
    public var curriculum: [String: Curriculum.Record]?
    /// Whether the draft's editing style has been settled for this Mac: the
    /// one-time choice made when the setting arrived (`EditingStyleMigration`).
    /// Machine owned: it must outlive a config that drops the key at its
    /// default, or a hand that chose Standard would be given Vim back.
    public var editingStyleSettled: Bool?
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
///
/// The file is **sealed at rest** (`StateFiles`): `state.sealed` and its
/// backup `state.sealed.bak`, AES-256-GCM under the `state` ring of the
/// `Vault`. It holds the addresses (window titles and URLs among them), so it
/// is kept like the logbook. What each state of the key means for it is the
/// vault's one rule, and here it reads:
///
/// - **ready**: the file is read, written and backed up as before.
/// - **paused** (the keychain is locked, refused, or the ring is damaged):
///   nothing on disk is read, written, removed or migrated. The app runs on an
///   empty state held in memory; what changes meanwhile is kept there, never
///   written in the clear and never over the sealed file, and is merged into
///   what is on disk when the keychain answers (`resume`), or at the next
///   launch if it never does (that part is lost, said in `bootWarning`).
/// - **key lost** (no ring, sealed state exists): the sealed files are moved
///   aside (`state-unreadable-…`, never deleted), a new ring is made, the
///   state starts fresh and `bootWarning` says so.
///
/// The disk half runs off the main thread (`openInBackground`): the first ask
/// of the keychain may wait on a prompt.
public final class StateStore {
    /// Where an earlier build kept the state, in the clear. Read once, taken
    /// into the sealed file and removed; written again only by a build older
    /// than the sealing, whose file the next launch merges in.
    public static let defaultFile = Paths.data.appendingPathComponent("state.json")

    /// The plaintext name (`StateStore.defaultFile`'s); the sealed file is beside it.
    public let file: URL
    private let files: StateFiles
    public var sealedFile: URL { files.sealedURL }

    /// Whether any state file is on disk, read or not. Only the app's own
    /// store writes one, so it is how a Mac says it has run Lodestar before.
    public var existsOnDisk: Bool {
        [file, sealedFile].contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    public private(set) var state = PersistedState()
    private var pendingSave: DispatchWorkItem?
    private var reportedSaveFailure = false

    /// Where the store is with the disk.
    public enum Condition: Equatable {
        /// Not read yet (the key may be asked for).
        case loading
        /// Read, and writes reach the sealed file.
        case ready
        /// The key cannot be had: for the reason, in words.
        case paused(String)
    }

    public private(set) var condition = Condition.loading

    /// Whether `state` is what the disk holds (plus what changed since):
    /// first-run questions (the walk, the editor's consent) are only asked
    /// of a state that is known, because an empty one would ask them again.
    public var isKnown: Bool { condition == .ready }

    /// Something was saved while the disk could not take it, so the memory
    /// state has to be merged into what is read.
    private var unsaved = false
    /// Breaths deleted while the disk could not be read: they must not come
    /// back with the merge.
    private var deletedWhileUnknown: Set<String> = []

    /// Set when load had to recover — the app surfaces it once the HUD
    /// exists. Breaths are the user's accumulated addresses; losing them
    /// silently is not acceptable.
    public private(set) var bootWarning: String?

    /// Main. The disk answered after `load` or `openInBackground`: the state
    /// is read, or paused with a reason. What waited for it (parked windows,
    /// a warning to say) acts here.
    public var onSettled: (() -> Void)?

    public init(file: URL = StateStore.defaultFile, vault: Vault, fileSystem: any FileSystem = OwnerOnly.fileSystem) {
        self.file = file
        self.files = StateFiles(plain: file, ring: vault.ring(.state), fileSystem: fileSystem)
    }

    /// Read the state now, on this thread (which may wait on the keychain):
    /// tests, and a process that has nothing else to do. The app uses
    /// `openInBackground`.
    public func load() {
        adopt(files.open())
    }

    // MARK: Opening off the main thread

    private let opened = Mutex<StateFiles.Opened?>(nil)
    private let openingGroup = DispatchGroup()
    private var opening = false

    /// Main. Read the state on a utility queue; it is adopted on the main
    /// thread when it is done (`waitForOpen` may adopt it sooner).
    public func openInBackground() {
        guard !opening else { return }
        opening = true
        openingGroup.enter()
        let files = files
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = files.open()
            self?.opened.withLock { $0 = result }
            self?.openingGroup.leave()
            DispatchQueue.main.async { self?.adoptOpened() }
        }
    }

    /// Main. Wait up to `seconds` for the background read, and adopt it if it
    /// finished: the normal launch, where the keychain answers in a few
    /// milliseconds, so that what reads the state next finds it. A keychain
    /// that is waiting on a prompt is not waited for beyond that: the app goes
    /// on with the state unknown, and `onSettled` fires when it answers.
    /// Returns whether the state is settled.
    @discardableResult
    public func waitForOpen(upTo seconds: TimeInterval) -> Bool {
        if opening, openingGroup.wait(timeout: .now() + seconds) == .success { adoptOpened() }
        return condition != .loading
    }

    private func adoptOpened() {
        guard let result = opened.withLock({ taken -> StateFiles.Opened? in defer { taken = nil }; return taken }) else { return }
        opening = false
        adopt(result)
    }

    /// Main. A keychain that was only locked can be asked again: the screen
    /// unlocked. Does nothing unless the store is paused for a reason that can lift.
    public func retryIfPaused() {
        guard case .paused = condition, !opening, files.ring.retry() else { return }
        openInBackground()
    }

    private func adopt(_ result: StateFiles.Opened) {
        switch result.outcome {
        case .paused(let why):
            condition = .paused(why)
            bootWarning = "your saved breaths and settings are unavailable this launch: \(why). Lodestar loads them when the keychain allows it, or at the next launch"
            Log.error("state: paused — \(why); nothing is read or written", [:])
        case .ready(let loaded):
            var merged = loaded
            if unsaved {
                merged = loaded.merging(newer: state)
                merged.breaths.removeAll { deletedWhileUnknown.contains($0.path) }
                if let latest = merged.latestBreath, !merged.breaths.contains(where: { $0.path == latest }) {
                    merged.latestBreath = nil
                }
                Log.info("state: merged what changed while it was unavailable")
            }
            deletedWhileUnknown = []
            state = merged
            // A warning stands for the launch (a second read does not unsay it),
            // except the one about the pause, which the end of the pause answers.
            if case .paused = condition { bootWarning = nil }
            condition = .ready
            bootWarning = result.warning ?? bootWarning
            Log.info("state: loaded \(state.breaths.count) breaths, \(state.parked.count) parked")
            if unsaved {
                unsaved = false
                save()
            }
        }
        onSettled?()
    }

    // MARK: Writing

    private func encode(_ state: PersistedState) -> [UInt8]? {
        StateFiles.encode(state)
    }

    /// Immediate write — explicit user data (breaths) and shutdown. While
    /// the disk cannot take it (loading, paused) the change is kept in memory
    /// for `adopt` to merge.
    public func save() {
        pendingSave?.cancel()
        pendingSave = nil
        state.version = Lodestar.stateVersion
        guard condition == .ready else {
            unsaved = true
            return
        }
        guard let data = encode(state) else {
            Log.error("state: SAVE FAILING — the state could not be encoded")
            return
        }
        switch files.write(data) {
        case .written:
            // An atomic write is a new inode, and a new inode is backed up
            // until something says otherwise.
            Paths.excludeFromBackup(files.sealedURL)
            reportedSaveFailure = false
        case .paused:
            unsaved = true
            if !reportedSaveFailure {
                reportedSaveFailure = true
                Log.error("state: the key cannot be asked for — breaths are held in memory until it can")
            }
        case .failed(let why):
            unsaved = true
            if !reportedSaveFailure {
                reportedSaveFailure = true
                Log.error("state: SAVE FAILING — breaths are not persisting", ["error": why])
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
        deletedWhileUnknown.remove(record.path)
        state.breaths.removeAll { $0.path == record.path }
        state.breaths.append(record)
        state.latestBreath = record.path
        save()
    }

    public func deleteBreath(at path: String) -> Bool {
        let before = state.breaths.count
        state.breaths.removeAll { $0.path == path }
        if condition != .ready { deletedWhileUnknown.insert(path) }
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
    public var walkDoor: Walk.Door? { state.walkDoor.flatMap(Walk.Door.init(rawValue:)) }

    public func setWalkStep(_ step: Int) {
        state.walkStep = step
        saveSoon()
    }

    public func setWalkDoor(_ door: Walk.Door) {
        state.walkDoor = door.rawValue
        saveSoon()
    }

    public func markWalkCompleted(version: String) {
        state.walkCompletedVersion = version
        save()
    }

    // MARK: - The draft's editing style

    public var editingStyleSettled: Bool { state.editingStyleSettled == true }

    public func settleEditingStyle() {
        state.editingStyleSettled = true
        save()
    }

    // MARK: - The editor's consent

    public var editorConsented: Bool { state.editorConsentAt != nil }

    public func setEditorConsent(_ at: Date?) {
        state.editorConsentAt = at
        save()
    }

    // MARK: - The curriculum

    public var curriculumRecords: [Curriculum.Lesson: Curriculum.Record] {
        var out: [Curriculum.Lesson: Curriculum.Record] = [:]
        for (key, record) in state.curriculum ?? [:] {
            if let lesson = Curriculum.Lesson(rawValue: key) { out[lesson] = record }
        }
        return out
    }

    public func setCurriculumRecord(_ record: Curriculum.Record, for lesson: Curriculum.Lesson) {
        var map = state.curriculum ?? [:]
        map[lesson.rawValue] = record
        state.curriculum = map
        saveSoon()
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

    /// Saved at once, not coalesced. The record is how a parked window —
    /// moved to a one-point sliver at the screen's corner — comes back, and
    /// a coalesced save half a second later is lost to an abort in that
    /// half second, or to a stalled main thread that never runs the timer:
    /// the window stays in the sliver with nothing that knows where it came
    /// from. The file is small and written atomically.
    public func setParked(_ spots: [CGWindowID: CGRect]) {
        state.parked = Dictionary(uniqueKeysWithValues: spots.map { (UInt32($0.key), $0.value) })
        state.parkedSession = Lodestar.bootSession
        save()
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
