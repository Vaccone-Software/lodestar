import XCTest
import LodestarCore
import Stoic
import StoicTesting
import StoicTime
@testable import lodestar

/// The walk's controller on a clock the test turns: input from the tap's
/// clock and the draft, stopping points from app switches, the cue shown
/// only when due and quiet, and taken down off the tap.
@MainActor final class StandCueControllerTests: XCTestCase {
    private let clock = TestClock()
    private var time: Date { clock.wallClockNow.date }
    private var lastKey = Date.distantPast
    private var shown: [(sentence: String, share: Double)] = []
    private var hidden: [String] = []
    private var quiet = true
    private var draftOpen = false
    private var enabled = true

    private func controller() -> StandCueController {
        let stand = StandCueController()
        stand.lastKeyAt = { [unowned self] in self.lastKey }
        stand.quiet = { [unowned self] in self.quiet }
        stand.draftOpen = { [unowned self] in self.draftOpen }
        stand.enabled = { [unowned self] in self.enabled }
        stand.show = { [unowned self] sentence, _, share in self.shown.append((sentence, share)) }
        stand.hide = { [unowned self] sentence in self.hidden.append(sentence) }
        return stand
    }

    /// The controller, on the test's time.
    private func held(_ body: (StandCueController) async -> Void) async {
        await withAmbient({ $0.clock = clock.erased; $0.wallClock = clock.wallClock }) {
            await body(controller())
        }
    }

    private func pass(_ seconds: Double) async { await clock.advance(by: .seconds(seconds)) }

    /// The settle that was scheduled is asleep, so the time that passes next
    /// is the time it waits; and once that has passed, it has run.
    private func settle(after mark: Int) async {
        await clock.waitForSleepers(newerThan: mark)
        await pass(3)
        for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(clock.sleeperCount, 0, "the settle is still waiting")
    }

    /// Typing every ten seconds for `minutes`, as the tap's clock reports it.
    private func type(_ stand: StandCueController, minutes: Double) async {
        let end = time.addingTimeInterval(minutes * 60)
        while time < end {
            await pass(10)
            lastKey = time
            stand.tick()
        }
    }

    /// The hand stops, another app comes to the front, and the settle the
    /// controller scheduled, if it scheduled one, runs once the hand has
    /// proved it stopped.
    private func switchApps(_ stand: StandCueController, to pid: pid_t, settles: Bool = true) async {
        await pass(1)
        let mark = clock.totalSleeps
        stand.activated(pid: pid)
        if settles {
            await settle(after: mark)
        } else {
            for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(1)) }
            XCTAssertEqual(clock.totalSleeps, mark, "nothing was due, and a settle was scheduled")
            await pass(3)
        }
    }

    func testAnAppSwitchAfterThirtyMinutesShowsTheCue() async {
        await held { stand in
            stand.activated(pid: 101)
            await type(stand, minutes: 31)
            XCTAssertTrue(shown.isEmpty, "typing alone is not a stopping point")
            await switchApps(stand, to: 202)
            XCTAssertEqual(shown.map(\.sentence), ["Thirty minutes without a break"])
            XCTAssertEqual(shown.first?.share, 0.5)
        }
    }

    func testTheNextKeyTakesTheCueDownOnlyAfterTheTapHasReturned() async {
        await held { stand in
            stand.activated(pid: 101)
            await type(stand, minutes: 31)
            await switchApps(stand, to: 202)
            XCTAssertEqual(shown.count, 1)
            await pass(5)
            stand.keyPressed()
            XCTAssertEqual(hidden, [], "hiding is window work and must not run inside the tap")
            let until = Date().addingTimeInterval(EditorRig.patience)
            while hidden.isEmpty, Date() < until { try? await Task.sleep(for: .milliseconds(2)) }
            XCTAssertEqual(hidden, ["Thirty minutes without a break"])
        }
    }

    func testNothingBeforeThirtyMinutes() async {
        await held { stand in
            stand.activated(pid: 101)
            await type(stand, minutes: 25)
            await switchApps(stand, to: 202, settles: false)
            XCTAssertTrue(shown.isEmpty)
        }
    }

    func testABreakStartsTheStretchOver() async {
        await held { stand in
            stand.activated(pid: 101)
            await type(stand, minutes: 25)
            await pass(180)
            await type(stand, minutes: 10)
            await switchApps(stand, to: 202, settles: false)
            XCTAssertTrue(shown.isEmpty, "a three minute gap was the break")
        }
    }

    func testNoCueWhileTheMomentIsNotQuiet() async {
        await held { stand in
            stand.activated(pid: 101)
            await type(stand, minutes: 31)
            quiet = false
            await switchApps(stand, to: 202)
            XCTAssertTrue(shown.isEmpty)
        }
    }

    func testNoCueWhileTheDraftIsOpen() async {
        await held { stand in
            stand.activated(pid: 101)
            await type(stand, minutes: 31)
            draftOpen = true
            await switchApps(stand, to: 202)
            XCTAssertTrue(shown.isEmpty)
        }
    }

    func testTheDraftClosingIsAStoppingPoint() async {
        await held { stand in
            await type(stand, minutes: 31)
            draftOpen = true
            await pass(5)
            stand.tick()
            draftOpen = false
            await pass(5)
            let mark = clock.totalSleeps
            stand.tick()
            await settle(after: mark)
            XCTAssertEqual(shown.map(\.sentence), ["Thirty minutes without a break"])
        }
    }

    func testTwoCuesAStretchAndNoMore() async {
        await held { stand in
            stand.activated(pid: 101)
            await type(stand, minutes: 31)
            await switchApps(stand, to: 202)
            await type(stand, minutes: 30)
            await switchApps(stand, to: 101)
            await type(stand, minutes: 30)
            await switchApps(stand, to: 202, settles: false)
            XCTAssertEqual(shown.map(\.sentence), ["Thirty minutes without a break", "Sixty minutes without a break"])
            XCTAssertEqual(shown.map(\.share), [0.5, 1])
        }
    }

    func testOffMeansSilent() async {
        await held { stand in
            enabled = false
            stand.activated(pid: 101)
            await type(stand, minutes: 31)
            await switchApps(stand, to: 202, settles: false)
            XCTAssertTrue(shown.isEmpty)
        }
    }

    func testAQuickSwitchIsNotAStoppingPoint() async {
        await held { stand in
            stand.activated(pid: 101)
            await type(stand, minutes: 31)
            // Over to another app and straight on typing: the settle finds the
            // hand busy and lets it pass.
            let mark = clock.totalSleeps
            stand.activated(pid: 202)
            await clock.waitForSleepers(newerThan: mark)
            await pass(1)
            lastKey = time
            await pass(2)
            await type(stand, minutes: 0.5)
            // Back within the dwell: a glance at 202, not leaving work.
            await switchApps(stand, to: 101, settles: false)
            XCTAssertTrue(shown.isEmpty)
        }
    }
}
