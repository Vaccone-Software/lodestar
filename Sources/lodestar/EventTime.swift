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

    /// The wall-clock moment the event was generated, placed by its age
    /// against the same monotonic clock read now. Two events converted
    /// this way differ by exactly their stamps' difference, up to the
    /// microseconds between reading the two clocks. Nil for an event with
    /// no stamp.
    static func date(of event: CGEvent) -> Date? {
        let stamp = event.timestamp
        guard stamp != 0 else { return nil }
        let now = mach_absolute_time()
        // The stamp is documented as nanoseconds and measured as exactly
        // that here (mach ticks already scaled by the timebase, on an
        // Apple silicon 125/3 machine); on a 1/1 timebase the two readings
        // coincide. Whichever puts the event within a minute of now is
        // the one this machine uses — a stamp that fits neither is not
        // trusted over the caller's clock.
        var age = (Double(now) * timebase.numer / timebase.denom - Double(stamp)) / 1e9
        if abs(age) > 60 {
            let ticks = seconds(ticks: Double(now) - Double(stamp))
            if abs(ticks) < 60 { age = ticks } else { return nil }
        }
        return Date(timeIntervalSinceNow: -age)
    }
}
