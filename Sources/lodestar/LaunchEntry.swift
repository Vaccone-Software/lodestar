import Foundation
import LodestarCore
import Stoic
import StoicStore

/// How a launch is counted and what the count changes, apart from the
/// delegate so a test can run it on a guard file of its own.
enum LaunchEntry {
    /// Counts this launch with `guardian` and puts the watchdog in the mode
    /// the count asks for: in safe mode a stall is logged and not aborted.
    ///
    /// Safe mode is said once, by Stoic's `launch.safe_mode`, which `StoicLog`
    /// writes to the log with the number of unclean launches and the limit
    /// they reached. This used to add a line of its own beside it; what that
    /// line also said (that the watchdog logs a stall instead of aborting) is
    /// said by the watchdog, in the line it writes when a stall comes
    /// ("safe mode: not aborting"), where a reader of the log needs it.
    static func begin(_ guardian: LaunchGuard, watchdog: MainThreadWatchdog) -> RunMarker.Mode {
        let mode = RunMarker.Mode(guardian.beginLaunch())
        if case .safe = mode { watchdog.response = .logOnly }
        return mode
    }
}
