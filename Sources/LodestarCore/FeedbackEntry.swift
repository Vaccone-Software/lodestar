import Foundation
import StoicStore

/// A note as it waits in the outbox: the note, and the version of this
/// format, so a build that changes it can still read what an older one left.
///
/// JSON, because the file is the one place a note sits on disk for days, and
/// a person who looks should be able to read what is in it (it is theirs).
/// Only the person's own words, reply address and chosen report are in it;
/// the idempotency key is the outbox's, kept beside the entry.
public struct FeedbackEntry: Codable, Equatable, Sendable {
    /// The format this build writes. A reader accepts this and any later
    /// one, because a later format may only add fields; a change that
    /// cannot be read this way is a new codec, not a new number.
    public static let schema = 1

    public var schema: Int
    public var feedback: Feedback

    public init(_ feedback: Feedback) {
        self.schema = Self.schema
        self.feedback = feedback
    }

    public struct Unreadable: Error, Equatable {
        public var why: String
    }

    public static let codec = OutboxCodec<FeedbackEntry>(
        encode: { entry in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return [UInt8](try encoder.encode(entry))
        },
        decode: { bytes in
            let entry = try JSONDecoder().decode(FeedbackEntry.self, from: Data(bytes))
            guard entry.schema >= Self.schema else {
                throw Unreadable(why: "schema \(entry.schema) is older than the first")
            }
            return entry
        })
}
