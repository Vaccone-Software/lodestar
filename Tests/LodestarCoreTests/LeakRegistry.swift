import XCTest
@testable import LodestarCore

/// Every process-wide static this bundle's tests change, which LeakGuard
/// watches (Overrides.swift). The app tests' bundle has its own, which adds
/// the app's; a test that needs a new one adds it here.
enum LeakRegistry {
    static let watched: [Watched] = LeakGuard.core

    /// This bundle's logic tests draw nothing and read no setting, so there is
    /// nothing of the Mac's to pin (the app tests' bundle pins its own).
    static func pinEnvironment() {}

    /// The repository's frequency list, which `CommonWords` reads once and
    /// keeps, installed when the bundle loads (LeakGuard). No test installs or
    /// changes it, and the guard fails one that does.
    static func installFixtures() {
        CommonWords.frequentListURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("packaging/common-words.txt")
    }
}
