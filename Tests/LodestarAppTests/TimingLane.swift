import Metal
import XCTest

/// The one place in the tests that knows where it is running.
///
/// A test never asks whether it is on CI, and never widens a bound there: a
/// unit test of anything with a delay runs on a clock it owns and asserts
/// exactly. What is left is the few properties that are about real time (the
/// watchdog seeing a real main-thread stall) or about hardware a hosted
/// runner lacks. A test of that kind says so in one line, here, and is
/// listed under `ci` in allowed-skips.txt, so the desk must run it and a
/// runner may not.
enum TimingLane {
    /// The test measures real time on a real machine: a runner shared by
    /// every shard is not one, so it runs at the desk.
    static func require() throws {
        try XCTSkipIf(onCI, "a real-time property: it runs at the desk, where the time is the test's own")
    }

    /// The test needs the GPU (MLX), which a hosted runner's virtual
    /// machine does not have.
    static func requireGPU() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil || onCI,
                      "needs a GPU, which a hosted runner does not have")
    }

    private static var onCI: Bool { ProcessInfo.processInfo.environment["CI"] != nil }
}
