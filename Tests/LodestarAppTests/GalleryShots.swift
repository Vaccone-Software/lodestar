import AppKit
@testable import lodestar

/// Every picture the gallery takes.
enum GalleryShots {
    static var all: [GalleryShot] {
        GalleryFoundations.shots + GalleryMaterial.shots + GalleryLauncher.shots + GalleryBars.shots + GallerySettings.shots + GalleryKeep.shots + GalleryChrome.shots + GalleryKeys.shots + GalleryControls.shots
    }
}
