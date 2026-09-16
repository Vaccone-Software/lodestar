import Foundation
import IOKit

/// Whether the lid is closed, from the power management root's own
/// register. A public IORegistry read, no prompt. Closed means the
/// built-in keyboard and trackpad could not have made the act, which is
/// what resolves a roster that names two of each; and it is a posture,
/// a desk with an external display, for free.
enum Lid {
    static func isClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else { return nil }
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }
}
