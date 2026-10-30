import XCTest
@testable import LodestarCore

/// Every process-wide static this bundle's tests change, which LeakGuard
/// watches (Overrides.swift). The app tests' bundle has its own, which adds
/// the app's; a test that needs a new one adds it here.
enum LeakRegistry {
    static let watched: [Watched] = LeakGuard.core
}
