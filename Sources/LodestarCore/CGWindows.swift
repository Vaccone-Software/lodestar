import CoreGraphics
import Foundation

/// A window as the window server reports it. Available without any
/// Accessibility trust; titles are deliberately not requested (those would
/// need Screen Recording permission, which nothing here justifies).
public struct CGWindowRecord {
    public let id: CGWindowID
    public let pid: pid_t
    public let ownerName: String
    public let bounds: CGRect
    public let layer: Int
}

public enum CGWindows {
    /// The one call both entry points share, so the option set cannot
    /// diverge between the full listing and the id sweep.
    private static func rawInfo(onScreenOnly: Bool) -> [[String: Any]] {
        var option: CGWindowListOption = [.excludeDesktopElements]
        if onScreenOnly { option.insert(.optionOnScreenOnly) }
        return CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]] ?? []
    }

    public static func list(onScreenOnly: Bool = true) -> [CGWindowRecord] {
        rawInfo(onScreenOnly: onScreenOnly).compactMap { info in
            guard
                let id = info[kCGWindowNumber as String] as? CGWindowID,
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return CGWindowRecord(
                id: id,
                pid: pid,
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "?",
                bounds: bounds,
                layer: info[kCGWindowLayer as String] as? Int ?? 0
            )
        }
    }

    /// Just the ids, skipping record construction: the liveness sweep runs
    /// on every focus change and every summon, and it only ever asks
    /// "which windows still exist" — bridging bounds and owner names for
    /// hundreds of windows to answer that was most of the sweep's cost.
    public static func liveIDs(onScreenOnly: Bool = false) -> Set<CGWindowID> {
        Set(rawInfo(onScreenOnly: onScreenOnly)
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
    }

    public static func contains(_ id: CGWindowID, onScreenOnly: Bool = false) -> Bool {
        liveIDs(onScreenOnly: onScreenOnly).contains(id)
    }
}
