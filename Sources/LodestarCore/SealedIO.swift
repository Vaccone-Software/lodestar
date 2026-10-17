import CryptoKit
import Foundation
import StoicSealed
import StoicStore
import Synchronization

/// SHA-256 of what a plaintext file held, which is how a migration knows a
/// file has already been taken into a sealed journal (and so how an
/// interrupted one is finished instead of repeated).
enum Digest {
    static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: bytes))
    }
}

/// Sealed values that would not open, counted for the run and logged, so a
/// key that does not fit or a file that was altered is never read as an empty
/// one. `lodestar diagnose` prints the counts; nothing here ever deletes.
public enum SealedFailures {
    public struct Tally: Sendable, Equatable {
        /// Sealed values that failed to open, by what failed.
        public var tampered = 0
        public var unknownKey = 0
        public var other = 0
        /// Files that could not be read at all (a journal that would not open).
        public var files = 0
        public var total: Int { tampered + unknownKey + other + files }
    }

    private struct State {
        var tally = Tally()
        var logged: Set<String> = []
    }

    private static let state = Mutex(State())

    public static var tally: Tally { state.withLock { $0.tally } }

    /// Tests, and a command that wants its own count.
    public static func reset() { state.withLock { $0 = State() } }

    static func note(_ failures: [SealedJournal.Replay.Failure], file: String) {
        guard !failures.isEmpty else { return }
        var tampered = 0, unknown = 0, other = 0
        for failure in failures {
            switch failure.error {
            case .tampered: tampered += 1
            case .unknownKey: unknown += 1
            default: other += 1
            }
        }
        let first = state.withLock { state -> Bool in
            state.tally.tampered += tampered
            state.tally.unknownKey += unknown
            state.tally.other += other
            return state.logged.insert(file + "#values").inserted
        }
        if first {
            Log.error("sealed: \(failures.count) values in \(file) did not open and were left as they are",
                      ["tampered": tampered, "unknownKey": unknown, "other": other])
        }
    }

    static func note(file path: String, why: String) {
        let first = state.withLock { state -> Bool in
            state.tally.files += 1
            return state.logged.insert(path + "#file").inserted
        }
        if first { Log.error("sealed: \(path) could not be read (\(why)) and was left as it is") }
    }
}

/// How a sealed journal is read by anyone who is not its writer: the app's
/// own readers, the command line, the export. `readOnlyReplay`, never
/// `open`: it repairs nothing and creates nothing, so a second process never
/// cuts the tail of an append in flight.
enum SealedRead {
    enum Outcome {
        /// There is no such journal.
        case absent
        /// The journal is there and no key can be asked for it: the ring is
        /// paused or missing. Not empty.
        case unavailable
        case opened(SealedJournal.Replay)
        /// The journal's own files could not be read (damaged beyond what its
        /// open repairs).
        case failed(String)
    }

    /// The options every reader and writer of one journal must share: the
    /// record size is part of what a frame is valid as.
    static func replay(
        at path: String, context: SealContext, ring: Vault.Ring?, fileSystem: any FileSystem,
        options: Journal.Options
    ) -> Outcome {
        guard (try? fileSystem.exists(path)) == true else { return .absent }
        guard let keyring = ring?.existing() else { return .unavailable }
        func look() -> Result<SealedJournal.Replay, SealedStoreError> {
            do {
                return .success(try SealedJournal.readOnlyReplay(
                    at: path, context: context, keyring: keyring, fileSystem: fileSystem, options: options))
            } catch {
                return .failure(error)
            }
        }
        var seen = look()
        // The app rotates its ring; a long-running reader holds the one it
        // opened with. An unknown key may only mean "newer than mine": reload
        // once, and look again.
        if case .success(let replay) = seen, replay.failures.contains(where: { if case .unknownKey = $0.error { true } else { false } }) {
            if (try? keyring.reload()) != nil { seen = look() }
        }
        switch seen {
        case .success(let replay):
            SealedFailures.note(replay.failures, file: SealedPath.name(of: path))
            return .opened(replay)
        case .failure(let error):
            SealedFailures.note(file: SealedPath.name(of: path), why: "\(error)")
            return .failed("\(error)")
        }
    }
}
