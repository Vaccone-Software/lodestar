import Stoic
import StoicTesting
import XCTest
@testable import lodestar

/// The windows a decision is made in (a throttle, a staleness, a memo), on a
/// clock the test holds: thirty seconds and ten minutes that nobody waits
/// for, and that used to be out of a test's reach.
@MainActor final class AmbientWindowTests: XCTestCase {
    private let clock = TestClock()

    /// `body`, with the test's clock as the ambient one.
    private func held<R>(_ body: () -> R) -> R {
        withAmbient({ $0.clock = clock.erased }) { body() }
    }

    private func eventually(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () -> Bool) async {
        let until = Date().addingTimeInterval(EditorRig.patience)
        while !condition(), Date() < until { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition(), what, file: file, line: line)
    }

    /// One warming per app per half minute, each app on its own.
    func testAnAppIsWarmedOncePerHalfMinute() async {
        // Processes there are none of: asking one is an error at once.
        let one: pid_t = 2_000_000_001, other: pid_t = 2_000_000_002
        XCTAssertTrue(held { AXWarmer.warm(one) })
        XCTAssertFalse(held { AXWarmer.warm(one) })
        await clock.advance(by: .seconds(29))
        XCTAssertFalse(held { AXWarmer.warm(one) }, "not yet")
        XCTAssertTrue(held { AXWarmer.warm(other) }, "another app's half minute is its own")
        await clock.advance(by: .seconds(1))
        XCTAssertTrue(held { AXWarmer.warm(one) })
        XCTAssertFalse(held { AXWarmer.warm(other) })
    }

    /// The index is read again when it is more than half a minute old, and
    /// its age is counted from the end of the last reading.
    func testTheIndexIsReadAgainOnceItIsStale() async {
        let index = AppIndex()
        held { index.refresh() }
        held { index.refreshIfStale() }
        XCTAssertFalse(index.scanning, "fresh")
        await clock.advance(by: .seconds(30))
        held { index.refreshIfStale() }
        XCTAssertFalse(index.scanning, "half a minute is not more than one")
        await clock.advance(by: .seconds(1))
        held { index.refreshIfStale() }
        XCTAssertTrue(index.scanning)
        await eventually("it is read") { !index.scanning }
        held { index.refreshIfStale() }
        XCTAssertFalse(index.scanning, "fresh again, on the clock it was asked on")
        await clock.advance(by: .seconds(31))
        held { index.refreshIfStale() }
        XCTAssertTrue(index.scanning)
        await eventually("and read again") { !index.scanning }
    }

    /// A repository's names are kept ten minutes, and are then an answer at
    /// once: the answer comes before the call returns.
    func testARepositorysNamesAreKeptTenMinutes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-names-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var answers = 0
        func answeredAtOnce() -> Bool {
            let before = answers
            held { RepoNames.index(for: root) { _ in answers += 1 } }
            return answers > before
        }
        XCTAssertFalse(answeredAtOnce(), "read off the main thread")
        await eventually("read") { answers == 1 }
        XCTAssertTrue(answeredAtOnce())
        await clock.advance(by: .seconds(599))
        XCTAssertTrue(answeredAtOnce())
        await clock.advance(by: .seconds(1))
        XCTAssertFalse(answeredAtOnce(), "ten minutes on, it is read again")
        await eventually("read again") { answers == 4 }
    }
}
