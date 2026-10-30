import XCTest

/// The one place in the tests that knows where it is running; see the App
/// target's TimingLane.swift, which this mirrors for the core's few
/// real-time tests.
enum TimingLane {
    /// The test measures real time on a real machine: a runner shared by
    /// every shard is not one, so it runs at the desk.
    static func require() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] != nil,
                      "a real-time property: it runs at the desk, where the time is the test's own")
    }
}
