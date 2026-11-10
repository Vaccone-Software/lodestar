import Foundation

// Measuring is not stamping. A duration measured on this machine is read off
// a monotonic clock, which no one sets and NTP never steps; "what time is it"
// comes from `Moment.now`, the ambient wall clock a test pins. These two
// helpers are the measuring half, so a call site says `began.secondsElapsed`
// where it once said `Date().timeIntervalSince(began)`.

extension Duration {
    /// This duration as seconds, the unit the logs and the report fields use.
    public var inSeconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }
}

extension ContinuousClock.Instant {
    /// Seconds from this instant to now, on the continuous clock.
    public var secondsElapsed: Double { duration(to: .now).inSeconds }

    /// Whole milliseconds from this instant to now, as the logs print them.
    public var millisecondsElapsed: Int { Int(secondsElapsed * 1000) }
}
