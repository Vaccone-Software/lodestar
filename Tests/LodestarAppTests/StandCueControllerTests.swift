import XCTest
import LodestarCore
@testable import lodestar

/// The walk's controller on a clock the test turns: input from the tap's
/// clock and the draft, stopping points from app switches, the cue shown
/// only when due and quiet, and taken down off the tap.
final class StandCueControllerTests: XCTestCase {
    private var time = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var lastKey = Date.distantPast
    private var settles: [DispatchWorkItem] = []
    private var shown: [(sentence: String, share: Double)] = []
    private var hidden: [String] = []
    private var quiet = true
    private var draftOpen = false
    private var enabled = true

    private func controller() -> StandCueController {
        let stand = StandCueController()
        stand.now = { [unowned self] in self.time }
        stand.after = { [unowned self] _, work in self.settles.append(work) }
        stand.lastKeyAt = { [unowned self] in self.lastKey }
        stand.quiet = { [unowned self] in self.quiet }
        stand.draftOpen = { [unowned self] in self.draftOpen }
        stand.enabled = { [unowned self] in self.enabled }
        stand.show = { [unowned self] sentence, _, share in self.shown.append((sentence, share)) }
        stand.hide = { [unowned self] sentence in self.hidden.append(sentence) }
        return stand
    }

    /// Typing every ten seconds for `minutes`, as the tap's clock reports it.
    private func type(_ stand: StandCueController, minutes: Double) {
        let end = time.addingTimeInterval(minutes * 60)
        while time < end {
            time = time.addingTimeInterval(10)
            lastKey = time
            stand.tick()
        }
    }

    /// The hand stops, another app comes to the front, and the settle the
    /// controller scheduled runs once the hand has proved it stopped.
    private func switchApps(_ stand: StandCueController, to pid: pid_t) {
        time = time.addingTimeInterval(1)
        stand.activated(pid: pid)
        time = time.addingTimeInterval(3)
        let pending = settles
        settles = []
        for work in pending { work.perform() }
    }

    private func drainMain() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    func testAnAppSwitchAfterThirtyMinutesShowsTheCue() {
        let stand = controller()
        stand.activated(pid: 101)
        type(stand, minutes: 31)
        XCTAssertTrue(shown.isEmpty, "typing alone is not a stopping point")
        switchApps(stand, to: 202)
        XCTAssertEqual(shown.map(\.sentence), ["Thirty minutes without a break"])
        XCTAssertEqual(shown.first?.share, 0.5)
    }

    func testTheNextKeyTakesTheCueDownOnlyAfterTheTapHasReturned() {
        let stand = controller()
        stand.activated(pid: 101)
        type(stand, minutes: 31)
        switchApps(stand, to: 202)
        XCTAssertEqual(shown.count, 1)
        time = time.addingTimeInterval(5)
        stand.keyPressed()
        XCTAssertEqual(hidden, [], "hiding is window work and must not run inside the tap")
        drainMain()
        XCTAssertEqual(hidden, ["Thirty minutes without a break"])
    }

    func testNothingBeforeThirtyMinutes() {
        let stand = controller()
        stand.activated(pid: 101)
        type(stand, minutes: 25)
        switchApps(stand, to: 202)
        XCTAssertTrue(shown.isEmpty)
    }

    func testABreakStartsTheStretchOver() {
        let stand = controller()
        stand.activated(pid: 101)
        type(stand, minutes: 25)
        time = time.addingTimeInterval(180)
        type(stand, minutes: 10)
        switchApps(stand, to: 202)
        XCTAssertTrue(shown.isEmpty, "a three minute gap was the break")
    }

    func testNoCueWhileTheMomentIsNotQuiet() {
        let stand = controller()
        stand.activated(pid: 101)
        type(stand, minutes: 31)
        quiet = false
        switchApps(stand, to: 202)
        XCTAssertTrue(shown.isEmpty)
    }

    func testNoCueWhileTheDraftIsOpen() {
        let stand = controller()
        stand.activated(pid: 101)
        type(stand, minutes: 31)
        draftOpen = true
        switchApps(stand, to: 202)
        XCTAssertTrue(shown.isEmpty)
    }

    func testTheDraftClosingIsAStoppingPoint() {
        let stand = controller()
        type(stand, minutes: 31)
        draftOpen = true
        time = time.addingTimeInterval(5)
        stand.tick()
        draftOpen = false
        time = time.addingTimeInterval(5)
        stand.tick()
        let pending = settles
        settles = []
        time = time.addingTimeInterval(3)
        for work in pending { work.perform() }
        XCTAssertEqual(shown.map(\.sentence), ["Thirty minutes without a break"])
    }

    func testTwoCuesAStretchAndNoMore() {
        let stand = controller()
        stand.activated(pid: 101)
        type(stand, minutes: 31)
        switchApps(stand, to: 202)
        type(stand, minutes: 30)
        switchApps(stand, to: 101)
        type(stand, minutes: 30)
        switchApps(stand, to: 202)
        XCTAssertEqual(shown.map(\.sentence), ["Thirty minutes without a break", "Sixty minutes without a break"])
        XCTAssertEqual(shown.map(\.share), [0.5, 1])
    }

    func testOffMeansSilent() {
        let stand = controller()
        enabled = false
        stand.activated(pid: 101)
        type(stand, minutes: 31)
        switchApps(stand, to: 202)
        XCTAssertTrue(shown.isEmpty)
    }

    func testAQuickSwitchIsNotAStoppingPoint() {
        let stand = controller()
        stand.activated(pid: 101)
        type(stand, minutes: 31)
        // Over to another app and straight on typing: the settle finds the
        // hand busy and lets it pass.
        stand.activated(pid: 202)
        time = time.addingTimeInterval(1)
        lastKey = time
        time = time.addingTimeInterval(2)
        settles.forEach { $0.perform() }
        settles = []
        type(stand, minutes: 0.5)
        // Back within the dwell: a glance at 202, not leaving work.
        switchApps(stand, to: 101)
        XCTAssertTrue(shown.isEmpty)
        XCTAssertTrue(settles.isEmpty)
    }
}
