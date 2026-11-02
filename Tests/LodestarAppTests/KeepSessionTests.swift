import XCTest
@testable import lodestar
@testable import LodestarCore

/// What the record says about how Keep's openings ended. One opening is
/// one record: turning to Bring and stepping back is the same opening, and
/// renaming a keepsake is something done, not an opening left.
final class KeepSessionTests: XCTestCase {
    private func pastes(_ stage: Stage) -> [ObservationEvent] {
        stage.observations.flush()
        return stage.observations.log.recent(days: 30, now: stage.clock.now.addingTimeInterval(1))
            .filter { $0.kind == .paste }
    }

    private func bringStage() -> Stage {
        let stage = Stage()
        stage.engine.bringFront = { 4242 }
        stage.engine.bringTypes = { _, _ in }
        stage.engine.bringWindows = {
            [BringReader.Window(source: Bring.Source(app: "Ghostty", window: "~/web", rank: 0), pid: 1,
                                lines: ["ssh build-02.internal"])]
        }
        stage.seedClip("a clip")
        stage.openStrip()
        return stage
    }

    func testBringAndBackIsOneOpeningThatActedByBring() {
        let stage = bringStage()
        stage.clock.advance(by: 1)
        stage.press("=")
        stage.clock.advance(by: 5)
        stage.press("escape")
        XCTAssertEqual(stage.engine.grammarState, .paste(searching: false), "back in Keep")
        XCTAssertTrue(pastes(stage).isEmpty, "the opening is not over")
        stage.clock.advance(by: 3)
        stage.press("escape")
        XCTAssertEqual(stage.engine.grammarState, .idle)
        let events = pastes(stage)
        XCTAssertEqual(events.count, 1, "not an opening acted by Bring and a second one abandoned")
        XCTAssertEqual(events.first?.action, "acted")
        XCTAssertEqual(events.first?.row, "bring")
        XCTAssertEqual(events.first?.seconds ?? 0, 1, accuracy: 0.01, "timed to the turn to Bring")
    }

    func testAPasteAfterTheReturnFromBringIsThatOpeningsPaste() {
        let stage = bringStage()
        stage.clock.advance(by: 1)
        stage.press("=")
        stage.clock.advance(by: 5)
        stage.press("escape")
        stage.clock.advance(by: 2)
        stage.press("j")
        XCTAssertEqual(stage.stripPastes, 1)
        let events = pastes(stage)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.action, "pasted", "the paste wins over the Bring that came before it")
        XCTAssertEqual(events.first?.seconds ?? 0, 8, accuracy: 0.01, "the whole opening")
    }

    func testAPickInBringEndsTheOpeningThere() {
        let stage = bringStage()
        stage.press("=")
        for key in ["s", "s", "h"] { stage.press(key) }
        stage.press("return")
        XCTAssertEqual(stage.engine.grammarState, .idle)
        let events = pastes(stage)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.action, "acted")
        XCTAssertEqual(events.first?.row, "bring")
    }

    func testRenamingAKeepsakeIsAnActNotAnAbandonedOpening() {
        let stage = Stage()
        let kept = stage.seedClip("a prompt worth keeping")
        XCTAssertTrue(stage.clipboard.history.pin(kept.id))
        stage.openStrip()
        stage.chord("4", .maskCommand)
        XCTAssertEqual(stage.engine.grammarState, .pastePanel(searching: false))
        stage.press("r")
        XCTAssertEqual(stage.engine.grammarState, .pasteName(searching: false))
        stage.press("return")
        stage.press("escape")
        XCTAssertEqual(stage.engine.grammarState, .idle)
        let events = pastes(stage)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.action, "acted")
        XCTAssertEqual(events.first?.row, "rename")
    }
}
