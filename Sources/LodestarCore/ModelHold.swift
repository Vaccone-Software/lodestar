import Foundation

/// How long a model that memory pressure sent away stays away.
///
/// Releasing is not enough on its own. The model is let go, the warning
/// passes because it was let go, the next keystroke loads the same weights
/// again, and the warning comes back: on the evening of 2026-11-05 the
/// editor's model was back within fifteen seconds of five warnings out of
/// seven. So after a warning the model waits for the quiet to last, and for
/// as long as the system still says memory is short. The wait has a ceiling,
/// or a Mac that lives at the warning level would lose the model for the day
/// on one signal.
///
/// A pure rule: the level is asked only while a warning is being waited out,
/// and the caller decides what waiting means.
public struct ModelHold: Sendable {
    /// How long after a warning the model stays away, whatever the level says.
    public static let quiet: TimeInterval = 5 * 60
    /// How long a level that never recovers can keep it away.
    public static let longest: TimeInterval = 30 * 60

    private var pressedAt: Date?

    public init() {}

    public mutating func pressed(at now: Date) {
        pressedAt = now
    }

    public func holds(at now: Date, level: @autoclosure () -> MemoryLevel) -> Bool {
        guard let pressedAt else { return false }
        let since = now.timeIntervalSince(pressedAt)
        if since >= Self.longest { return false }
        return since < Self.quiet || level() != .normal
    }
}
