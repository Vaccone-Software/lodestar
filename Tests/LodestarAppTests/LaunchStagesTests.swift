import Stoic
import StoicTesting
import XCTest
@testable import lodestar

final class LaunchStagesTests: XCTestCase {
    private let clock = TestClock()
    private var lines: [(event: String, fields: [String: String])] = []

    private func stages() -> LaunchStages {
        LaunchStages(clock: clock.erased) { [self] event, fields in
            lines.append((event, Dictionary(uniqueKeysWithValues: fields.map { ($0.key, "\($0.value)") })))
        }
    }

    func testTheRunningStepIsNamedUntilLaunchFinishes() {
        let launch = stages()
        XCTAssertNil(launch.current)
        launch.enter("config")
        XCTAssertEqual(launch.current, "config")
        launch.enter("model")
        XCTAssertEqual(launch.current, "model")
        launch.finish()
        XCTAssertNil(launch.current)
    }

    func testAFinishedLaunchWritesEveryStepOnOneLine() async {
        let launch = stages()
        launch.enter("config")
        await clock.advance(by: .milliseconds(12))
        launch.enter("model")
        await clock.advance(by: .milliseconds(300))
        launch.finish()
        XCTAssertEqual(lines.map(\.event), ["launch stages"])
        XCTAssertEqual(lines.first?.fields["ms"], "config 12, model 300")
        XCTAssertGreaterThanOrEqual(Int(lines.first?.fields["exec-ms"] ?? "") ?? -1, 0, "how long since exec")
    }

    /// A launch that never finishes has already said which steps were slow.
    func testASlowStepIsWrittenAsItEnds() async {
        let launch = stages()
        launch.enter("config")
        await clock.advance(by: .seconds(58))
        launch.enter("model")
        XCTAssertEqual(lines.map(\.event), ["launch stage slow"])
        XCTAssertEqual(lines.first?.fields["stage"], "config")
        XCTAssertEqual(lines.first?.fields["ms"], "58000")
    }
}
