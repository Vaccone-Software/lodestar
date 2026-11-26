import Foundation
import Stoic
import StoicTesting
import XCTest
@testable import lodestar
@testable import LodestarCore

/// An Apple Event to a player has two seconds. The asks share one serial
/// queue with every pause, resume, route and tab check, so a player that
/// never answers must cost that queue two seconds, never the two minutes an
/// Apple Event waits by default. The clock is the test's own, so an ask
/// overruns when the test moves it and never because a machine was slow.
final class PlayerAskDeadlineTests: XCTestCase {
    private let clock = TestClock()
    private let silent = Silent()
    /// Always running in a session with a screen, so `isPlaying` and `pause`
    /// get as far as asking. Nothing is sent to it: the send is the stand-in.
    private let player = "com.apple.dock"

    override func setUp() {
        setOverride(\Players.Type.clock, to: clock.erased)
        let silent = silent
        setOverride(\Players.Type.send, to: { source in silent.hear(source) })
        // An ask still stuck outlives its test; it lets go of its place under
        // the player's label when it comes back, which is what this opens,
        // and the next test starts with nothing of this one's on the ledger.
        let label = "player.\(player)"
        addTeardownBlock { [clock, silent] in
            silent.release()
            await clock.advance(by: .seconds(1_000_000))
            for _ in 0..<2000 where AbandonedWork.current.contains(where: { $0.label == label }) {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    /// A player that never answers: each ask blocks its thread until the test
    /// lets it go, and says what it was asked.
    private final class Silent: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var _asked: [String] = []
        var asked: [String] { lock.withLock { _asked } }
        func hear(_ source: String) -> Players.Reply {
            lock.withLock { _asked.append(source) }
            gate.wait()
            return .answer("playing")
        }
        func release() { for _ in 0..<8 { gate.signal() } }
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [String] = []
        var all: [String] { lock.withLock { _all } }
        func add(_ line: String) { lock.withLock { _all.append(line) } }
    }

    /// The call as the playback queue makes it: from a thread of its own.
    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: work()) }
        }
    }

    /// Real time for what threads and tasks do after the clock moved. A
    /// hang guard: a condition that does not come fails the test.
    private func eventually(_ condition: @Sendable () -> Bool) async -> Bool {
        for _ in 0..<2000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func testAPlayerThatNeverAnswersIsNotPlayingOnceItsTwoSecondsAreUp() async {
        let player = player
        let asking = Task { await onQueue { Players.isPlaying(player) } }
        let began = await eventually { [silent, clock] in silent.asked.count == 1 && clock.sleeperCount == 1 }
        XCTAssertTrue(began, "the player was asked, with its two seconds")
        XCTAssertEqual(silent.asked.first, "tell application id \"\(player)\" to player state as string")
        await clock.advance(by: .seconds(Players.deadline))
        let playing = await asking.value
        XCTAssertFalse(playing, "no answer in time is not playing")
        XCTAssertEqual(AbandonedWork.current.filter { $0.label == "player.\(player)" }.count, 1,
                       "the ask is left running and counted, not waited for")
    }

    func testAPauseThatIsNeverAnsweredReturnsAtItsDeadlineAndDoesNothingMore() async {
        let lines = Lines()
        Log.listener = { lines.add($0) }
        addTeardownBlock { Log.listener = nil }
        let player = player
        let pausing = Task { await onQueue { Players.pause(player) } }
        let began = await eventually { [silent, clock] in silent.asked.count == 1 && clock.sleeperCount == 1 }
        XCTAssertTrue(began)
        await clock.advance(by: .seconds(Players.deadline))
        await pausing.value
        XCTAssertEqual(silent.asked, ["tell application id \"\(player)\" to pause"], "asked once, never again")
        XCTAssertTrue(lines.all.contains { $0.contains("no answer") && $0.contains(player) }, "\(lines.all)")
    }

    func testAPlayerThatAnswersInTimeIsHeard() async {
        setOverride(\Players.Type.send, to: { _ in .answer("playing") })
        let player = player
        let playing = await onQueue { Players.isPlaying(player) }
        XCTAssertTrue(playing)
        XCTAssertEqual(clock.sleeperCount, 0, "its deadline's timer was cancelled, not left to run out")
    }

    func testAScriptErrorIsNotPlaying() async {
        setOverride(\Players.Type.send, to: { _ in .failed("Not authorized to send Apple events") })
        let player = player
        let playing = await onQueue { Players.isPlaying(player) }
        XCTAssertFalse(playing)
    }
}
