import AppKit
@testable import lodestar

/// Every picture the gallery takes.
enum GalleryShots {
    static var all: [GalleryShot] {
        GalleryLauncher.shots + GalleryKeys.shots
    }
}
