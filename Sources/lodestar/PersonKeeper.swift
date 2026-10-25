import Foundation
import LodestarCore

/// The facts about you (`Person`), as Settings shows and changes them, sealed
/// in `person.json` with the health record. Main thread, except where a
/// method says otherwise.
///
/// Nil until the health record has opened, or while it cannot be read: the
/// rows read as nothing then, and take no writes. A write is sealed off the
/// main thread, because the first one may make the health key and that may
/// ask the keychain. The health record being deleted or set aside bumps a
/// generation before it goes, and a write queued earlier checks it, so the
/// facts can never come back into the record that replaced it.
final class PersonKeeper {
    private(set) var person: Person?
    private let file: PersonFile
    private let ring: Vault.Ring
    private let queue: DispatchQueue
    private let generation = PersonGeneration()
    /// A move out of the config is under way; the reload it causes must not
    /// start another.
    private var moving = false
    /// The move could not be sealed this launch: tried once, not at every
    /// reload.
    private var moveFailed = false

    /// The rows should be drawn again.
    var changed: () -> Void = {}
    /// A line for the person, when a change they made was not kept.
    var flash: (String) -> Void = { _ in }
    /// Take the facts' old keys out of the config, once they are sealed.
    /// Returns a problem, or nil.
    var stripConfig: () -> String? = { nil }

    init(directory: URL = Paths.data, ring: Vault.Ring,
         queue: DispatchQueue = DispatchQueue(label: "lodestar.person", qos: .utility)) {
        file = PersonFile(directory: directory, ring: ring)
        self.ring = ring
        self.queue = queue
    }

    /// The facts as the launch read them (`PersonFile.read`, off the main
    /// thread), once the keys settled.
    func read(_ read: PersonFile.Read) {
        switch read {
        case .person(let read):
            person = read
        case .unavailable(let why):
            person = nil
            Log.error("health: person.json could not be read (\(why)); the facts about you wait for the next launch")
        }
        changed()
    }

    /// One Settings row's value. Returns the problem the row shows, or nil.
    func set(_ path: String, to value: ConfigValue, healthOn: Bool) -> String? {
        guard healthOn else { return "Needs health" }
        guard let current = person else { return "the health record has not opened yet" }
        let text: String
        switch value {
        case .string(let string): text = string
        case .int(let number): text = String(number)
        default: return "\(path) takes a word or a year"
        }
        let next: Person
        do { next = try current.setting(path, to: text) } catch { return "\(error)" }
        guard next != current else { return nil }
        person = next
        changed()
        save(next, over: current, announce: true) { _ in }
        return nil
    }

    /// `health.born` and `health.hand` as the config holds them move into
    /// the sealed facts (filling only what is not set there) and out of the
    /// file. The config history never kept them (`ConfigHistory.changes`),
    /// so the removal leaves no plaintext copy behind.
    func moveOutOfConfig(born: Int?, hand: String) {
        guard !moving, !moveFailed, let current = person, born != nil || !hand.isEmpty else { return }
        switch ring.availability {
        case .paused, .keyLost: return
        default: break
        }
        let merged = current.movingIn(born: born, hand: hand)
        moving = true
        // The facts are the merged ones from here, so an edit made while the
        // move is sealing builds on them and not on what came before.
        person = merged
        let strip = { [weak self] in
            guard let self else { return }
            if let problem = self.stripConfig() {
                Log.error("health: the facts about you are sealed but the config still holds them", ["problem": problem])
            }
            self.moving = false
        }
        guard merged != current else { return strip() }
        changed()
        save(merged, over: current, announce: false) { [weak self] saved in
            if saved {
                strip()
            } else {
                self?.moving = false
                self?.moveFailed = true
            }
        }
    }

    /// The health record is about to be deleted or set aside, and the facts
    /// go with it: called before it goes, so no write queued earlier lands
    /// in the record that replaces it.
    func forget() {
        generation.bump()
        person = Person()
        moving = false
        changed()
    }

    /// Tests: every write queued so far has been made; its answer is then
    /// on its way to the main queue.
    func drainForTesting() {
        queue.sync {}
    }

    /// Seals `next` off the main thread. On failure the facts go back to
    /// what is on disk and, when `announce`, say so; `done` hears which. A
    /// write the deletion of the record overtook is not made, and one it
    /// overtook mid-write is removed again.
    private func save(_ next: Person, over previous: Person, announce: Bool, done: @escaping (Bool) -> Void) {
        let file = file
        let mine = generation.value
        let counter = generation
        queue.async { [weak self] in
            guard counter.value == mine else { return }
            let written = file.write(next)
            if counter.value != mine { try? FileManager.default.removeItem(at: file.stored.url) }
            DispatchQueue.main.async {
                guard let self, counter.value == mine else { return }
                guard written != .written else { return done(true) }
                Log.error("health: person.json was not written", ["why": "\(written)"])
                if self.person == next { self.person = previous }
                if announce { self.flash("✕ Not saved. The health record could not be written") }
                self.changed()
                done(false)
            }
        }
    }
}

/// A counter any thread may read: the facts' generation (`PersonKeeper.forget`).
final class PersonGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return current }
    func bump() { lock.lock(); current += 1; lock.unlock() }
}
