import Foundation
import Stoic

/// One release of Lodestar on one Mac, from the day the feed offered it to the
/// day it is running or refused: the updater's state across launches and
/// builds, declared once (Stoic design/27).
///
/// Before this the state was a family of marker files (`updated-to`,
/// `rolled-back`, `routes-ok`, the `refused` tombstone) whose meaning each
/// reader worked out again at boot. The markers are still written and read,
/// because they are the protocol between processes: the watchdog is a bash
/// script that knows nothing of this, and a rollback can land on a build from
/// before it. The record is what this build adds beside them: who moved a
/// release and why, a timeout for every state that waits, and the two
/// announcements said across a relaunch as effects that are delivered at least
/// once, under keys, so a message is not said twice because two processes
/// booted, nor lost because the one that owed it exited.
///
/// The id is the release's canonical version (`id(for:)`), so `v0.54.25`,
/// `0.54.25` and `0.54.25.0` are one record.
public enum ReleaseOnThisMac: Lifecycle {
    public static let name = "lodestar.release"
    public static let version = 1

    /// Who moved the release. Recorded in every history entry, never in an event.
    public enum Principal: Hashable, Sendable, Codable {
        /// This build's controller: the feed offered it, a download ended, the swap was made.
        case updater
        /// The build that booted after the swap, the one that confirms it or finds it unchanged.
        case successor(pid: Int32)
        /// The detached bash script that blesses a successor or puts the old build back. It cannot
        /// write a record: its marker is read, once, at the next boot.
        case watchdog
        /// A marker or tombstone an earlier build left, turned into a record at boot.
        case importer
        /// A launch tidying what the last run left half done.
        case launch
    }

    public enum State: String, Hashable, Sendable, Codable, CaseIterable {
        case offered, downloading, staged, applying, running, rolledBack, refused
    }

    public enum Event: String, Hashable, Sendable, Codable, CaseIterable {
        case download, verified, failed, incompatible, apply, confirm, rollBack, unchanged, stall, abandon
    }

    /// What is said to the person across a relaunch: only these two. A failure inside one process
    /// (an incompatible build, a download that failed) stays a flash said where it happens.
    public enum Announcement: String, Hashable, Sendable, Codable, CaseIterable {
        case running, rolledBack
    }

    public enum Effect: Hashable, Sendable, Codable {
        case announce(Announcement)
    }

    /// Why a release that failed its handover is not tried again: the loop the tombstone was written to prevent.
    public static let failedOnce = "this release failed its handover on this Mac once"

    public static func transition(from state: State, on event: Event) -> Self.Step {
        switch (state, event) {
        case (.offered, .download):
            .to(.downloading)
        case (.downloading, .verified):
            .to(.staged)
        case (.downloading, .failed), (.downloading, .stall), (.downloading, .abandon):
            .to(.offered)
        case (.downloading, .incompatible):
            .to(.refused)
        case (.staged, .apply):
            .to(.applying)
        case (.staged, .failed), (.staged, .stall), (.staged, .abandon):
            .to(.offered)
        case (.applying, .confirm):
            .to(.running, effects: [.announce(.running)])
        // The watchdog's verdict can reach a release its successor already confirmed: a running
        // record that refused it would leave a rolled-back release on offer, which is the
        // update-and-rollback loop the tombstone exists to prevent.
        case (.applying, .rollBack), (.running, .rollBack):
            .to(.rolledBack, effects: [.announce(.rolledBack)])
        // v0.32.4 was 0.32.3's binary under a new label, applied 194 times in a night. Only logged
        // today, so nothing is announced.
        case (.applying, .unchanged):
            .to(.refused)
        // No successor confirmed it and no rollback was read.
        case (.applying, .stall):
            .to(.refused)
        // The relay and the resident both read the same marker; the second finds it done.
        case (.running, .confirm), (.rolledBack, .rollBack):
            .ignore
        case (.rolledBack, .download), (.rolledBack, .confirm), (.rolledBack, .apply),
             (.refused, .download), (.refused, .confirm), (.refused, .apply):
            .refuse(failedOnce)
        default:
            .ignore
        }
    }

    public static func timeout(in state: State) -> Self.Timeout? {
        switch state {
        case .downloading: .after(UpdateDownload.deadline, send: .stall)
        case .staged: .after(.seconds(7 * 24 * 3_600), send: .stall)
        case .applying: .after(.seconds(30 * 60), send: .stall)
        case .offered, .running, .rolledBack, .refused: nil
        }
    }

    /// `running` is not final: the watchdog's verdict may still arrive.
    public static func isFinal(_ state: State) -> Bool {
        state == .rolledBack || state == .refused
    }

    // MARK: - The id

    /// The record id for a version or a tag: parsed the way the updater parses versions, padded to
    /// three places and with trailing zeros past the third dropped, so `v0.54.25`, `0.54.25` and
    /// `0.54.25.0` are one release. Nil for text that is not a version.
    public static func id(for version: String) -> String? {
        guard var places = Updater.parseVersion(version) else { return nil }
        while places.count > 3, places.last == 0 { places.removeLast() }
        while places.count < 3 { places.append(0) }
        return places.map(String.init).joined(separator: ".")
    }
}

extension ReleaseOnThisMac.State {
    /// A state in which the release is not offered again: a rollback or a refusal is for good, and
    /// an `applying` that has not timed out is a successor that may still confirm.
    public var holdsTheOffer: Bool {
        switch self {
        case .applying, .rolledBack, .refused: true
        case .offered, .downloading, .staged, .running: false
        }
    }
}
