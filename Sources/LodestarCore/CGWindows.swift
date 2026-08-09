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
    public static func list(onScreenOnly: Bool = true) -> [CGWindowRecord] {
        var option: CGWindowListOption = [.excludeDesktopElements]
        if onScreenOnly { option.insert(.optionOnScreenOnly) }
        guard let raw = CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { info in
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

    public static func contains(_ id: CGWindowID, onScreenOnly: Bool = false) -> Bool {
        list(onScreenOnly: onScreenOnly).contains { $0.id == id }
    }
}
