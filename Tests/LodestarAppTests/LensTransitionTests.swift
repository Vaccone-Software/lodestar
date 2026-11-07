import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// One lens handing the keys to another, or to Keep, or to a chain: the
/// one that ends must end whole, and the one that begins must stand whole.
/// The real engine, the real select controller, the real scroller and the
/// real strip, on the stage's window world; only the screen's reading is
/// replaced, because a scenario has no screen.
final class LensTransitionTests: XCTestCase {
    private final class MarkLens: EditorLens {
        var enabled = true
        var lensMarks: [EditorController.Mark]
        init(count: Int) {
            lensMarks = (0..<count).map { i in
                EditorController.Mark(
                    issue: EditorIssue(range: NSRange(location: 10 * i, length: 4), original: "wrd\(i)",
                                       replacement: "word\(i)", kind: .spelling),
                    rect: CGRect(x: 10 + 60 * CGFloat(i), y: 300, width: 50, height: 18))
            }
        }

        func fix(_ mark: EditorController.Mark, completion: @escaping (Bool) -> Void) {
            lensMarks.removeAll { $0 == mark }
            completion(true)
        }
        func fixAll(_ marks: [EditorController.Mark], completion: @escaping (Int) -> Void) {
            lensMarks.removeAll { marks.contains($0) }
            completion(marks.count)
        }
        func ignore(_ mark: EditorController.Mark) { lensMarks.removeAll { $0 == mark } }
        func learn(_ mark: EditorController.Mark) { lensMarks.removeAll { $0 == mark } }
        func undoLastFix(completion: @escaping (Bool) -> Void) { completion(true) }
    }

    /// The sessions whose reading ran: each is the generation it ran for.
    /// A session that was ended before its reading ran never appears.
    private final class Sensor {
        var generations: [Int] = []
        var runs: Int { generations.count }
    }

    private func stand(_ stage: Stage) {
        stage.model.stand(WindowModel.Window(
            id: 9, element: AXUIElementCreateSystemWide(), pid: 1, appName: "Slack",
            bundleID: "com.tinyspeck.slackmacgap", title: "editor",
            frame: CGRect(x: 0, y: 0, width: 900, height: 700),
            isMinimized: false, isAlive: true, lastFocused: Date()))
    }

    private func rig(marks: Int = 2) -> (Stage, MarkLens, Sensor) {
        let stage = Stage()
        stand(stage)
        let lens = MarkLens(count: marks)
        stage.engine.appEditor = lens
        stage.engine.select.holdsFix = { _ in false }
        let sensor = Sensor()
        stage.engine.select.sensing = { _, generation in sensor.generations.append(generation) }
        return (stage, lens, sensor)
    }

    private func scrolls(_ stage: Stage) -> [ObservationEvent] {
        stage.observations.flush()
        return stage.observations.log.recent(days: 30, now: stage.clock.now.addingTimeInterval(1))
            .filter { $0.kind == .scroll }
    }

    private func state(_ stage: Stage) -> String { stage.engine.stateDescription }

    // MARK: - One lens to another: the one that begins must stand

    /// `lode /` with the editor's lens up. The new select session reads
    /// the screen; the old lens's ending must not take that away.
    func testHintsToSelectLeavesASessionThatReads() {
        let (stage, lens, sensor) = rig()
        withExtendedLifetime(lens) {
            stage.lode("tab")
            XCTAssertTrue(state(stage).contains("hints"))
            XCTAssertEqual(sensor.runs, 0, "the editor's lens reads no screen")
            stage.lode("/")
            stage.settle(turns: 5)
            XCTAssertEqual(state(stage), "select")
            XCTAssertEqual(sensor.runs, 1, "select's session reads the screen: the old lens ending did not end it")
        }
    }

    /// `lode ;` with select up.
    func testSelectToHintsLeavesASessionThatReads() {
        let (stage, lens, sensor) = rig()
        withExtendedLifetime(lens) {
            stage.lode("/")
            stage.settle(turns: 5)
            XCTAssertEqual(sensor.runs, 1)
            stage.lode(";")
            stage.settle(turns: 5)
            XCTAssertEqual(state(stage), "hints")
            XCTAssertEqual(sensor.runs, 2, "the click door's session reads the screen: select ending did not end it")
        }
    }

    /// `lode ⇥` with the editor's lens up: the new lens wears its pill
    /// and its chips.
    func testHintsToEditorLeavesALensThatIsDrawn() {
        let (stage, lens, _) = rig()
        withExtendedLifetime(lens) {
            stage.lode("tab")
            XCTAssertTrue(stage.engine.pill.isVisible)
            stage.lode("tab")
            stage.settle(turns: 5)
            XCTAssertTrue(state(stage).contains("hints"))
            XCTAssertFalse(stage.engine.select.shownChips.isEmpty, "the new lens letters its marks")
            XCTAssertTrue(stage.engine.pill.isVisible, "and wears its pill")
        }
    }

    /// The aim band, then `lode /`: select begins and the aim band ends.
    func testScrollAimToSelectLeavesASessionThatReads() {
        let (stage, lens, sensor) = rig()
        withExtendedLifetime(lens) {
            stage.lode("`")
            stage.press("/")
            stage.settle(turns: 5)
            XCTAssertEqual(state(stage), "scroll+aim")
            XCTAssertEqual(sensor.runs, 1)
            stage.lode("/")
            stage.settle(turns: 5)
            XCTAssertEqual(state(stage), "select")
            XCTAssertEqual(sensor.runs, 2, "select's session reads the screen: the aim band ending did not end it")
        }
    }

    func testScrollAimToHintsLeavesASessionThatReads() {
        let (stage, lens, sensor) = rig()
        withExtendedLifetime(lens) {
            stage.lode("`")
            stage.press("/")
            stage.settle(turns: 5)
            XCTAssertEqual(sensor.runs, 1)
            stage.lode(";")
            stage.settle(turns: 5)
            XCTAssertEqual(state(stage), "hints")
            XCTAssertEqual(sensor.runs, 2, "the click door's session reads the screen: the aim band ending did not end it")
        }
    }

    func testScrollAimToEditorLeavesALensThatIsDrawn() {
        let (stage, lens, _) = rig()
        withExtendedLifetime(lens) {
            stage.lode("`")
            stage.press("/")
            stage.settle(turns: 5)
            stage.lode("tab")
            stage.settle(turns: 5)
            XCTAssertTrue(state(stage).contains("hints"))
            XCTAssertFalse(stage.engine.select.shownChips.isEmpty, "the editor's lens letters its marks")
            XCTAssertTrue(stage.engine.pill.isVisible, "and wears its pill")
        }
    }

    /// Scroll straight to the editor's lens: the pill the lens showed is
    /// not the one scroll's ending takes down.
    func testScrollToEditorLeavesALensThatIsDrawn() {
        let (stage, lens, _) = rig()
        withExtendedLifetime(lens) {
            stage.lode("`")
            XCTAssertTrue(stage.engine.pill.isVisible)
            stage.lode("tab")
            stage.settle(turns: 5)
            XCTAssertTrue(state(stage).contains("hints"))
            XCTAssertTrue(stage.engine.pill.isVisible, "the editor's lens wears its pill")
            XCTAssertFalse(stage.engine.select.shownChips.isEmpty, "and letters its marks")
        }
    }

    func testScrollToSelectLeavesASessionThatReads() {
        let (stage, lens, sensor) = rig()
        withExtendedLifetime(lens) {
            stage.lode("`")
            stage.lode("/")
            stage.settle(turns: 5)
            XCTAssertEqual(state(stage), "select")
            XCTAssertEqual(sensor.runs, 1, "select's session reads the screen")
        }
    }

    func testScrollToHintsLeavesASessionThatReads() {
        let (stage, lens, sensor) = rig()
        withExtendedLifetime(lens) {
            stage.lode("`")
            stage.lode(";")
            stage.settle(turns: 5)
            XCTAssertEqual(state(stage), "hints")
            XCTAssertEqual(sensor.runs, 1, "the click door's session reads the screen")
        }
    }

    /// `lode `` inside scroll ends the session it is in and begins another.
    /// The one it ends keeps the counts it earned; the one it begins is
    /// recorded when it ends in its turn.
    func testBacktickInScrollRecordsTheSessionItEndsAndTheOneItBegins() {
        let (stage, lens, _) = rig()
        withExtendedLifetime(lens) {
            stage.lode("`")
            stage.press("d")
            stage.press("k")
            stage.lode("`")
            XCTAssertEqual(state(stage), "scroll")
            stage.press("escape")
            let records = scrolls(stage)
            XCTAssertEqual(records.first?.action, "toggle")
            XCTAssertEqual(records.first?.pages, 1, "the session the toggle ended keeps its page")
            XCTAssertEqual(records.first?.keys, 1, "and its key")
            XCTAssertEqual(records.map(\.action), ["toggle", "escape"], "the session it began is recorded when it ends")
        }
    }

    /// A lens that is refused starts nothing: no door taken, no verb counted.
    func testARefusedEditorEntryTouchesNothing() {
        let (stage, lens, _) = rig(marks: 0)
        withExtendedLifetime(lens) {
            stage.lode("tab")
            XCTAssertEqual(state(stage), "idle")
            XCTAssertEqual(stage.engine.select.door, .anchor, "no session began")
            stage.observations.flush()
            let verbs = stage.observations.log.recent(days: 30, now: stage.clock.now.addingTimeInterval(1))
                .filter { $0.kind == .verb }.map(\.verb)
            XCTAssertTrue(verbs.isEmpty, "and no verb was counted: \(verbs)")
        }
    }

    /// The guide scroll shows names the app the session reads: the session
    /// has started by the time the guide is drawn.
    func testScrollsPillNamesTheAppItReads() {
        let (stage, lens, _) = rig()
        withExtendedLifetime(lens) {
            stage.lode("`")
            XCTAssertEqual(stage.engine.pill.state?.app, "Slack")
        }
    }

    /// The session `lode backtick` begins finds its panes, as one begun
    /// from idle does.
    func testAToggledScrollSessionDiscoversItsPanes() {
        let (stage, lens, _) = rig()
        withExtendedLifetime(lens) {
            var discovered = 0
            stage.lode("`")
            stage.scroller.onPanesDiscovered = { discovered += 1 }
            stage.lode("`")
            stage.pump(until: { discovered > 0 }, within: 5)
            XCTAssertGreaterThan(discovered, 0, "discovery of the new session was not cut off by the old one's exit")
        }
    }
}
