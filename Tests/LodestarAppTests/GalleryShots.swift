import AppKit
@testable import lodestar

/// Every picture the gallery takes.
enum GalleryShots {
    static var all: [GalleryShot] {
        let base = GalleryFoundations.shots + GalleryMaterial.shots + GalleryLauncher.shots + GalleryBars.shots + GallerySettings.shots + GalleryKeep.shots + GalleryChrome.shots + GalleryKeys.shots + GalleryHints.shots + GalleryControls.shots
        return base + eyeComfort(of: base)
    }

    /// Eye comfort's pictures (design/06-eye-comfort.md): the colour sheet,
    /// the launcher, Settings, Keep and the pill in the evening (88%) and at
    /// bedtime (80%) in both looks, and the pill and the chip receded. Each
    /// is the same surface as its full-level picture, so the two are compared
    /// side by side; they are named for the hour, or for receding.
    static let evening = 0.88
    static let bedtime = 0.80

    static func eyeComfort(of base: [GalleryShot]) -> [GalleryShot] {
        let hours = [("evening", evening), ("bedtime", bedtime)]
        let dimmed: [(surface: String, state: String)] = [
            ("foundation", "colour"), ("launcher", "results-second-chosen"), ("settings", "general"),
            ("keep", "clips-newest-chosen"), ("pill", "scroll-standing"), ("pill", "offer"),
        ]
        let receded: [(surface: String, state: String)] = [
            ("pill", "scroll-standing"), ("pill", "select-typing"), ("meeting", "countdown-quiet"),
        ]
        var out: [GalleryShot] = []
        for (surface, state) in dimmed {
            guard let shot = base.first(where: { $0.surface == surface && $0.state == state }) else { continue }
            for (hour, level) in hours {
                var variant = shot
                variant.level = level
                variant.state = hour == "evening" ? "\(state)-evening" : "\(state)-bedtime"
                out.append(variant)
            }
        }
        for (surface, state) in receded {
            guard let shot = base.first(where: { $0.surface == surface && $0.state == state }) else { continue }
            for (name, level) in [("receded", 1.0), ("receded-bedtime", bedtime)] {
                var variant = shot
                variant.level = level
                variant.receded = true
                variant.state = "\(state)-\(name)"
                out.append(variant)
            }
        }
        return out
    }
}
