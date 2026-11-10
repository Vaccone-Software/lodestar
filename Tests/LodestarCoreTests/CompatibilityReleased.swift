import CoreGraphics
import Foundation

/// What release 0.54.22 decoded, kept as it was (design/27's way of proving a
/// format is read backwards: the old decoder, verbatim, in the test). Only the
/// Codable shapes and the one guard the outbox's decoder made are kept; each is
/// copied from the tag (`git show v0.54.22:Sources/LodestarCore/FeedbackEntry.swift`,
/// `Feedback.swift`, `Stores.swift`, `Curriculum.swift`), and the type names stay
/// apart from today's so neither can be read for the other.
///
/// This is the reader a build that the updater rolled back to would be: the
/// outbox opens with `onUndecodable: .discard`, so what this cannot read, a
/// rolled-back build would delete from a person's outbox without a word.
enum Released_0_54_22 {
    struct Feedback: Codable, Equatable {
        var message: String
        var replyTo: String
        var version: String
        var macos: String
        var diagnostics: String?
    }

    struct FeedbackEntry: Codable, Equatable {
        static let schema = 1

        var schema: Int
        var feedback: Feedback

        struct Unreadable: Error, Equatable {
            var why: String
        }

        /// FeedbackEntry.codec's decode, as that release had it.
        static func decode(_ bytes: [UInt8]) throws -> FeedbackEntry {
            let entry = try JSONDecoder().decode(FeedbackEntry.self, from: Data(bytes))
            guard entry.schema >= Self.schema else {
                throw Unreadable(why: "schema \(entry.schema) is older than the first")
            }
            return entry
        }
    }

    struct BreathMember: Codable {
        var windowID: UInt32
        var bundleID: String?
        var appName: String
        var title: String
        var frame: CGRect
        var display: String?
    }

    struct BreathRecord: Codable {
        var path: String
        var orientation: String
        var members: [BreathMember]
        var orientations: [String: String]?
    }

    struct UsageRecord: Codable {
        var count: Int
        var last: Date
    }

    struct CurriculumRecord: Codable, Equatable {
        var offers: Int
        var lastOfferedAt: Date?
        var completedAt: Date?
    }

    struct PersistedState: Codable {
        var version: Int?
        var breaths: [BreathRecord] = []
        var latestBreath: String?
        var parked: [UInt32: CGRect] = [:]
        var parkedSession: String?
        var usage: [String: UsageRecord]?
        var walkStep: Int?
        var walkCompletedVersion: String?
        var walkDoor: String?
        var editorConsentAt: Date?
        var meetingSpent: [String]?
        var coachStandingSince: [String: Date]?
        var curriculum: [String: CurriculumRecord]?
        var editingStyleSettled: Bool?

        /// StateFiles.decode, as that release had it (no migration step existed).
        static func decode(_ bytes: [UInt8]) -> PersistedState? {
            try? JSONDecoder().decode(PersistedState.self, from: Data(bytes))
        }
    }
}
