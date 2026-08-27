import Foundation

/// When a sense stops being evidence.
///
/// The microphone is the better of the two signals for "you are on a call"
/// because it knows about the meeting nobody put on a calendar. It has one
/// flaw the calendar does not: no end. A meeting ends at a time somebody
/// wrote down; an open input device ends whenever the app that opened it
/// decides to close it, and some never do.
///
/// The failure that produces is the quiet kind. Offers do not break, they
/// simply never come again, and a coach that speaks twice a week looks
/// exactly the same when it has been silenced as when it has nothing to
/// say. So the microphone holds the floor for a long time and not forever.
public enum Presence {
    /// Longer than any real call and shorter than forever. A meeting that
    /// genuinely runs past this has a calendar entry saying so, and the
    /// calendar half keeps holding the floor on its own.
    public static let microphoneCeiling: TimeInterval = 4 * 3600

    /// Does an input device that has been open since `openSince` still
    /// count as somebody being on a call?
    public static func microphoneHolds(openSince: Date?, now: Date) -> Bool {
        guard let openSince else { return false }
        return now.timeIntervalSince(openSince) <= microphoneCeiling
    }
}
