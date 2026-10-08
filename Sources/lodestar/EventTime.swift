import CoreGraphics
import Darwin
import Foundation

/// When an input event happened, read from the event itself.
///
/// The taps' callbacks run on a run loop — the key tap's on main — and a
/// callback that reads the clock is timing the scheduler as much as the
/// hand: a release that lands while a retile holds the main thread is
/// measured late by however long the retile ran (p90 82 ms, measured,
/// against a 94 ms mean hold). The HID system stamps every event at the
/// moment it was generated, in `mach_absolute_time` ticks, and that stamp
/// is immune to everything that happens to the process afterwards. So a
/// press is timed from its own stamp and a release from its own, and the
/// hold between them is the hand's.
///
/// A hold is the difference of two stamps, taken on the monotonic clock
/// they were made on (`hold(from:to:)`). Each `date(of:)` reads the wall
/// clock to place an event, so two dates straddling a clock adjustment
/// differ by the adjustment too; the dates are for the record, the stamps
/// are for the intervals.
///
/// Synthesized events carry no stamp (zero) and fall back to the caller's
/// clock, which is how the scenario harness keeps its virtual time.
enum EventTime {
    private static let timebase: (numer: Double, denom: Double) = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return (Double(info.numer), Double(info.denom))
    }()

    /// Mach ticks as seconds, on this machine's timebase.
    static func seconds(ticks: Double) -> TimeInterval {
        ticks * timebase.numer / timebase.denom / 1e9
    }

    /// The event's stamp as nanoseconds on the monotonic clock, the scale
    /// two stamps are subtracted on. Nil for an event with no stamp, or one
    /// that fits neither reading below.
    static func monotonic(of event: CGEvent, now: UInt64 = mach_absolute_time()) -> Double? {
        monotonic(stamp: event.timestamp, now: now)
    }

    static func monotonic(stamp: CGEventTimestamp, now: UInt64 = mach_absolute_time()) -> Double? {
        guard stamp != 0 else { return nil }
        // The stamp is documented as nanoseconds and measured as exactly
        // that here (mach ticks already scaled by the timebase, on an
        // Apple silicon 125/3 machine); on a 1/1 timebase the two readings
        // coincide. Whichever puts the event within a minute of now is
        // the one this machine uses — a stamp that fits neither is not
        // trusted over the caller's clock.
        let nowNanos = Double(now) * timebase.numer / timebase.denom
        let asNanos = Double(stamp)
        if abs(nowNanos - asNanos) <= 60e9 { return asNanos }
        let fromTicks = Double(stamp) * timebase.numer / timebase.denom
        if abs(nowNanos - fromTicks) <= 60e9 { return fromTicks }
        return nil
    }

    /// Mach ticks (a HID report's timestamp) as nanoseconds on the
    /// monotonic clock, the scale `monotonic(of:)` reads a tap event on.
    static func nanoseconds(ticks: UInt64) -> Double {
        Double(ticks) * timebase.numer / timebase.denom
    }

    /// The wall-clock moment the event was generated, placed by its age
    /// against the same monotonic clock read now. Nil for an event with no
    /// stamp. For the record: an interval is taken from the stamps.
    static func date(of event: CGEvent) -> Date? {
        let now = mach_absolute_time()
        guard let stamp = monotonic(of: event, now: now) else { return nil }
        let age = (Double(now) * timebase.numer / timebase.denom - stamp) / 1e9
        return Date(timeIntervalSinceNow: -age)
    }

    /// Seconds from one moment to another: from their stamps when both
    /// carry one, the hand's own interval whatever the wall clock did in
    /// between; otherwise from their dates, which is the scenario
    /// harness's virtual time.
    static func interval(from start: (date: Date, stamp: Double?), to end: (date: Date, stamp: Double?)) -> TimeInterval {
        if let a = start.stamp, let b = end.stamp { return (b - a) / 1e9 }
        return end.date.timeIntervalSince(start.date)
    }
}
