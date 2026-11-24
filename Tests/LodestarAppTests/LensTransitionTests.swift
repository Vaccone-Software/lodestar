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
        /// Fixes that have started and not reported, the way an app that
        /// takes typing reports late.
        var landing: [() -> Void] = []
        var deferred = false
        /// Takings back that have started and not reported.
        var undoing: [() -> Void] = []
        var deferUndo = false
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
            if deferred { landing.append { completion(true) } } else { completion(true) }
        }
        func fixAll(_ marks: [EditorController.Mark], completion: @escaping (Int) -> Void) {
            lensMarks.removeAll { marks.contains($0) }
            if deferred { landing.append { completion(marks.count) } } else { completion(marks.count) }
        }
        func ignore(_ mark: EditorController.Mark) { lensMarks.removeAll { $0 == mark } }
        func learn(_ mark: EditorController.Mark) { lensMarks.removeAll { $0 == mark } }
        func undoLastFix(completion: @escaping (Bool) -> Void) {
            if deferUndo { undoing.append { completion(true) } } else { completion(true) }
        }
        /// Fresh marks to letter, as the field has more to say after a fix.
        func refill(_ count: Int) {
            lensMarks = MarkLens(count: count).lensMarks
        }
    }

    /// What reached the app, and the completions the app still owes.
    private final class App {
        var log: [(pid: pid_t, keys: [SelectController.HeldKey], paced: Bool)] = []
        var owed: [() -> Void] = []
        var keys: [SelectController.HeldKey] { log.flatMap(\.keys) }
    }

    /// The sessions whose reading ran: each is the generation it ran for.
    /// A session that was ended before its reading ran never appears.
    private final class Sensor {
        var generations: [Int] = []
        var runs: Int { generations.count }
    }

    private func stand(_ stage: Stage, pid: pid_t = 1) {
        stage.model.stand(WindowModel.Window(
            id: 9, element: AXUIElementCreateSystemWide(), pid: pid, appName: "Slack",
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
        stage.engine.select.observations = stage.observations
        let sensor = Sensor()
        stage.engine.select.sensing = { _, generation in sensor.generations.append(generation) }
        return (stage, lens, sensor)
    }

    private func scrolls(_ stage: Stage) -> [ObservationEvent] {
        stage.observations.flush()
        return stage.observations.log.recent(days: 30, now: stage.clock.now.addingTimeInterval(1))
            .filter { $0.kind == .scroll }
    }

    private func selects(_ stage: Stage) -> [ObservationEvent] {
        stage.observations.flush()
        return stage.observations.log.recent(days: 30, now: stage.clock.now.addingTimeInterval(1))
            .filter { $0.kind == .select }
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

    // MARK: - Keep from a lens or a chain: the lens or chain ends first

    func testKeepFromScrollEndsScroll() {
        let (stage, lens, _) = rig()
        withExtendedLifetime(lens) {
            stage.seedClip("kept")
            stage.lode("`")
            stage.press("d")
            XCTAssertTrue(stage.engine.pill.isVisible)
            stage.openStrip()
            XCTAssertTrue(state(stage).hasPrefix("paste"))
            XCTAssertFalse(stage.engine.pill.isVisible, "scroll's pill goes when Keep comes")
            XCTAssertEqual(scrolls(stage).map(\.action).count, 1, "scroll's session is recorded as it ends")
            stage.press("escape")
            XCTAssertEqual(state(stage), "idle")
            XCTAssertFalse(stage.engine.pill.isVisible, "and stays gone when Keep closes")
        }
    }

    func testKeepFromScrollAimEndsBoth() {
        let (stage, lens, _) = rig()
        withExtendedLifetime(lens) {
            stage.seedClip("kept")
            stage.lode("`")
            stage.press("/")
            stage.settle(turns: 5)
            XCTAssertEqual(state(stage), "scroll+aim")
            stage.openStrip()
            XCTAssertTrue(state(stage).hasPrefix("paste"))
            XCTAssertFalse(stage.engine.pill.isVisible, "the aim band's pill goes when Keep comes")
            XCTAssertEqual(scrolls(stage).count, 1, "scroll's session is recorded as it ends")
        }
    }

    func testKeepFromHintsEndsTheLens() {
        let (stage, lens, _) = rig()
        withExtendedLifetime(lens) {
            stage.seedClip("kept")
            stage.lode("tab")
            XCTAssertFalse(stage.engine.select.shownChips.isEmpty)
            stage.openStrip()
            XCTAssertTrue(state(stage).hasPrefix("paste"))
            XCTAssertTrue(stage.engine.select.shownChips.isEmpty, "the lens's chips go when Keep comes")
            XCTAssertFalse(stage.engine.pill.isVisible, "and its pill")
        }
    }

    func testKeepFromSelectEndsTheSession() {
        let (stage, lens, _) = rig()
        withExtendedLifetime(lens) {
            stage.seedClip("kept")
            stage.lode("/")
            stage.settle(turns: 5)
            XCTAssertEqual(state(stage), "select")
            XCTAssertTrue(selects(stage).isEmpty)
            stage.openStrip()
            XCTAssertTrue(state(stage).hasPrefix("paste"))
            XCTAssertEqual(selects(stage).count, 1, "select's session is ended, and recorded as it ends")
        }
    }

    func testKeepFromAChainEndsTheChain() {
        let (stage, lens, _) = rig()
        withExtendedLifetime(lens) {
            stage.seedClip("kept")
            stage.lode("b")
            stage.clock.advance(by: 2)
            XCTAssertTrue(state(stage).hasPrefix("chain"))
            XCTAssertEqual(stage.hud.owner, .guide, "the chain's guide stands")
            stage.openStrip()
            XCTAssertTrue(state(stage).hasPrefix("paste"))
            XCTAssertNotEqual(stage.hud.owner, .guide, "the chain's guide goes when Keep comes")
        }
    }

    /// A chain Keep ends is an abandoned chain in the record, as one the
    /// escape key ends.
    func testKeepFromAChainRecordsTheAbandon() {
        let (stage, lens, _) = rig()
        withExtendedLifetime(lens) {
            stage.seedClip("kept")
            stage.lode("b")
            stage.clock.advance(by: 2)
            stage.openStrip()
            stage.observations.flush()
            let abandons = stage.observations.log.recent(days: 30, now: stage.clock.now.addingTimeInterval(1))
                .filter { $0.kind == .abandon }
            XCTAssertEqual(abandons.count, 1, "the chain Keep ended is recorded as abandoned")
            XCTAssertEqual(abandons.first?.chain ?? [], ["b"])
        }
    }

    /// With nothing to paste Keep does not open, and whatever stood stays
    /// exactly as it was.
    func testKeepWithNothingToPasteLeavesScrollAlone() {
        let (stage, lens, _) = rig()
        withExtendedLifetime(lens) {
            stage.lode("`")
            stage.openStrip()
            XCTAssertEqual(state(stage), "scroll")
            XCTAssertTrue(stage.engine.pill.isVisible)
            XCTAssertTrue(scrolls(stage).isEmpty, "the session goes on")
            stage.wheel = []
            XCTAssertTrue(stage.press("d"), "scroll's key is still scroll's")
            stage.settle(turns: 5)
            XCTAssertEqual(stage.wheel.count, 1)
        }
    }

    func testKeepWithNothingToPasteLeavesTheEditorLensAlone() {
        let (stage, lens, _) = rig()
        withExtendedLifetime(lens) {
            stage.lode("tab")
            stage.openStrip()
            XCTAssertTrue(state(stage).contains("hints"))
            XCTAssertFalse(stage.engine.select.shownChips.isEmpty)
            XCTAssertTrue(stage.engine.pill.isVisible)
        }
    }

    func testKeepWithNothingToPasteLeavesAChainAlone() {
        let (stage, lens, _) = rig()
        withExtendedLifetime(lens) {
            stage.lode("b")
            stage.clock.advance(by: 2)
            stage.openStrip()
            XCTAssertTrue(state(stage).hasPrefix("chain"))
        }
    }

    // MARK: - Typing held during a fix

    /// A fix that lands late, in an app that takes typing; the typing the
    /// hand does meanwhile is `typed`.
    private func holding(_ stage: Stage, _ lens: MarkLens, _ app: App, typed: [String] = ["h", "i"]) throws {
        lens.deferred = true
        stage.engine.select.holdsFix = { _ in true }
        stage.engine.select.replay = { pid, keys, paced, done in
            app.log.append((pid, keys, paced))
            app.owed.append(done)
        }
        stage.lode("tab")
        stage.press(try XCTUnwrap(stage.engine.select.shownChips.first?.label))
        for key in typed { stage.press(key) }
        XCTAssertTrue(app.keys.isEmpty, "held while the fix lands")
    }

    /// Esc while the fix lands: the hold goes on by itself. The keys wait
    /// for the fix (a character before it would replace the word still
    /// selected), then go in once.
    func testEscapeDuringALandingFixStillPutsTheTypingIn() throws {
        let (stage, lens, _) = rig(marks: 1)
        let app = App()
        try withExtendedLifetime(lens) {
            try holding(stage, lens, app)
            stage.press("escape")
            XCTAssertEqual(state(stage), "idle")
            stage.settle(turns: 5)
            XCTAssertTrue(app.keys.isEmpty, "not before the fix has landed")
            lens.landing.forEach { $0() }
            stage.settle(turns: 5)
            XCTAssertEqual(app.keys, [.text("hi")], "what the hand typed reaches the app, once, after esc")
            XCTAssertEqual(app.log.map(\.paced), [true], "behind the fix")
        }
    }

    func testALodeGestureDuringALandingFixStillPutsTheTypingIn() throws {
        let (stage, lens, _) = rig(marks: 1)
        let app = App()
        try withExtendedLifetime(lens) {
            try holding(stage, lens, app)
            stage.lode(";")
            XCTAssertEqual(state(stage), "idle")
            XCTAssertTrue(app.keys.isEmpty, "not before the fix has landed")
            lens.landing.forEach { $0() }
            stage.settle(turns: 5)
            XCTAssertEqual(app.keys, [.text("hi")], "what the hand typed reaches the app, once, after lode ;")
        }
    }

    /// The keys belong to the app the fix landed in, whichever window a
    /// new session has since read.
    func testADetachedHoldPutsItsKeysInTheAppItWasMadeFor() throws {
        let (stage, lens, _) = rig(marks: 1)
        let app = App()
        try withExtendedLifetime(lens) {
            try holding(stage, lens, app)
            stage.press("escape")
            stage.settle(turns: 3)
            stand(stage, pid: 7)
            stage.lode(";")
            stage.settle(turns: 3)
            XCTAssertEqual(state(stage), "hints")
            lens.landing.forEach { $0() }
            stage.settle(turns: 5)
            XCTAssertEqual(app.log.map(\.pid), [1], "the app the fix was made in, not the one in front now")
            XCTAssertEqual(app.keys, [.text("hi")])
        }
    }

    /// A fix that never reports: the limit lifts a detached hold too.
    func testADetachedHoldIsLiftedByTheLimitToo() throws {
        let (stage, lens, _) = rig(marks: 1)
        let app = App()
        try withExtendedLifetime(lens) {
            try holding(stage, lens, app)
            stage.press("escape")
            stage.pump(until: { !app.keys.isEmpty }, within: SelectController.settleLimit + 2)
            XCTAssertEqual(app.keys, [.text("hi")])
            lens.landing.forEach { $0() }
            stage.settle(turns: 5)
            XCTAssertEqual(app.keys, [.text("hi")], "and the fix reporting after the limit puts nothing in twice")
        }
    }

    /// A new select session starts while the old fix is landing: the keys
    /// go in after the landing, once, and the session stands.
    func testANewSessionDoesNotFlushOrDropADetachedHold() throws {
        let (stage, lens, _) = rig(marks: 1)
        let app = App()
        try withExtendedLifetime(lens) {
            try holding(stage, lens, app)
            stage.lode("/")
            stage.settle(turns: 5)
            XCTAssertEqual(state(stage), "select")
            XCTAssertTrue(app.keys.isEmpty, "the new session did not flush the old hold")
            lens.landing.forEach { $0() }
            stage.settle(turns: 5)
            XCTAssertEqual(app.keys, [.text("hi")], "and did not drop it")
            app.owed.forEach { $0() }
            stage.settle(turns: 5)
            XCTAssertEqual(app.keys, [.text("hi")], "once")
            XCTAssertEqual(state(stage), "select", "and the old hold finishing did not end the new session")
        }
    }

    /// The old lens's last replay is still on the accessibility queue when
    /// a new lens begins; its completion arrives into the new session.
    func testAnOldReplayCompletingDoesNotEndANewerLens() throws {
        let (stage, lens, _) = rig(marks: 1)
        let app = App()
        try withExtendedLifetime(lens) {
            try holding(stage, lens, app)
            lens.landing.forEach { $0() }
            XCTAssertEqual(app.keys, [.text("hi")], "the fix landed and the typing is going in")
            XCTAssertEqual(app.owed.count, 1)
            stage.press("escape")
            XCTAssertEqual(state(stage), "idle")
            stage.lode(";")
            stage.settle(turns: 5)
            XCTAssertEqual(state(stage), "hints", "a click door session of its own")
            app.owed.forEach { $0() }
            stage.settle(turns: 5)
            XCTAssertEqual(state(stage), "hints", "the old replay finishing is not this session's ending")
        }
    }

    /// A detached hold that kept nothing is not a reason to end, or to
    /// touch, anything.
    func testADetachedHoldThatKeptNothingLeavesNothingBehind() throws {
        let (stage, lens, _) = rig(marks: 1)
        let app = App()
        try withExtendedLifetime(lens) {
            try holding(stage, lens, app, typed: [])
            stage.press("escape")
            stage.lode(";")
            stage.settle(turns: 5)
            XCTAssertEqual(state(stage), "hints")
            lens.landing.forEach { $0() }
            stage.settle(turns: 5)
            XCTAssertEqual(state(stage), "hints", "the fix landing is not this session's ending")
            XCTAssertTrue(app.log.isEmpty, "and nothing was put in")
        }
    }

    /// The next session starts free of the hold the last one left: a key
    /// it does not own is not kept for the old fix.
    func testANewSessionDoesNotInheritTheLastHold() throws {
        let (stage, lens, _) = rig(marks: 1)
        let app = App()
        try withExtendedLifetime(lens) {
            try holding(stage, lens, app, typed: [])
            stage.press("escape")
            lens.refill(2)
            stage.lode("tab")
            XCTAssertTrue(state(stage).contains("hints"))
            stage.press("1")
            lens.landing.forEach { $0() }
            stage.settle(turns: 5)
            XCTAssertTrue(app.log.isEmpty, "the new lens's key was not held for the old fix")
            XCTAssertTrue(state(stage).contains("hints"))
            XCTAssertFalse(stage.engine.select.shownChips.isEmpty, "and its chips stand")
        }
    }

    /// The new session's own hold is independent of the detached one.
    func testANewSessionsOwnHoldIsIndependentOfTheDetachedOne() throws {
        let (stage, lens, _) = rig(marks: 1)
        let app = App()
        try withExtendedLifetime(lens) {
            try holding(stage, lens, app, typed: ["a"])
            stage.press("escape")
            lens.refill(1)
            stage.lode("tab")
            stage.press(try XCTUnwrap(stage.engine.select.shownChips.first?.label))
            stage.press("b")
            XCTAssertTrue(app.keys.isEmpty)
            XCTAssertEqual(lens.landing.count, 2)
            lens.landing[0]()
            stage.settle(turns: 5)
            XCTAssertEqual(app.keys, [.text("a")], "the old fix's landing puts the old keys in, and only those")
            XCTAssertTrue(state(stage).contains("hints"), "while the new fix is still landing")
            lens.landing[1]()
            stage.settle(turns: 5)
            XCTAssertEqual(app.keys, [.text("a"), .text("b")])
        }
    }

    /// Typing that is not typing ends a live hold at once: what was typed
    /// goes in first, and the hold does not put it in again.
    func testANonTypingKeyEndsALiveHoldAndTheTypingGoesInFirst() throws {
        let (stage, lens, _) = rig(marks: 1)
        let app = App()
        try withExtendedLifetime(lens) {
            try holding(stage, lens, app)
            XCTAssertFalse(stage.press("left"), "the arrow goes on to the app")
            XCTAssertEqual(app.keys, [.text("hi")], "after what was typed")
            XCTAssertEqual(app.log.map(\.paced), [false], "now, so it is in before the key")
            lens.landing.forEach { $0() }
            stage.settle(turns: 5)
            XCTAssertEqual(app.keys, [.text("hi")], "and once")
        }
    }

    /// A taking back that reports after its session ended belongs to that
    /// session: it relabels nothing in the next.
    func testAnOldTakingBackCompletingLettersNothingInTheNewSession() {
        let (stage, lens, _) = rig(marks: 2)
        withExtendedLifetime(lens) {
            lens.deferUndo = true
            stage.lode("tab")
            stage.press("delete")
            XCTAssertEqual(lens.undoing.count, 1)
            stage.press("escape")
            stage.lode("tab")
            XCTAssertTrue(stage.engine.select.rescansSettled)
            lens.undoing.forEach { $0() }
            XCTAssertTrue(stage.engine.select.rescansSettled, "the old session's report started no look in this one")
        }
    }
}
