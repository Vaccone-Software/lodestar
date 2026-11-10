import Foundation
import StoicTime

// "Today" and "this hour" are questions about a place. The place Lodestar
// means is the person's own: the zone the device is set to now, which Stoic's
// zone rules name (`TimeZoneID.device`) and a test scripts, where
// `Calendar.current` and `TimeZone.current` took it from the machine unsaid.

extension TimeZone {
    /// The zone the device is set to now.
    public static var device: TimeZone { TimeZone(TimeZoneID.device) ?? .gmt }
}

extension Calendar {
    /// The person's own calendar (their locale's, with its first weekday and
    /// month names) in the device's zone.
    public static var device: Calendar {
        var calendar = Locale.current.calendar
        calendar.timeZone = .device
        return calendar
    }
}
