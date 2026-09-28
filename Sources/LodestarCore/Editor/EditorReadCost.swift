import Foundation

/// What the editor's reads cost the app being read, one app at a time.
///
/// Every read of the focused field is a dozen messages answered on that
/// app's main thread — the thread that also takes its keystrokes — and
/// the editor reads about once a keystroke. How long a read takes is how
/// long the app spent answering instead of typing, and that is unmeasured
/// in the apps where it matters most (Brave, Slack, Asana: web text).
/// Reads are gathered per app and said once the hand moves to another
/// app, or every `batch` reads in a long session.
public struct EditorReadCost {
    public struct Summary: Equatable {
        public let app: String
        public let reads: Int
        public let p50: Double
        public let p90: Double
        public let max: Double
        public let totalMs: Double
    }

    public let batch: Int
    private var app: String?
    private var samples: [Double] = []

    public init(batch: Int = 200) { self.batch = batch }

    /// One read of `app`'s field took `ms`. A summary comes back when the
    /// reads before it are complete: another app, or a full batch.
    public mutating func add(app: String, ms: Double) -> Summary? {
        var done: Summary?
        if let current = self.app, current != app { done = flush() }
        self.app = app
        samples.append(ms)
        if samples.count >= batch { done = flush() }
        return done
    }

    /// Whatever has been gathered, said now.
    public mutating func flush() -> Summary? {
        guard let app, !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let summary = Summary(app: app, reads: sorted.count, p50: sorted[sorted.count / 2],
                              p90: sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))],
                              max: sorted.last!, totalMs: sorted.reduce(0, +))
        samples = []
        return summary
    }
}
