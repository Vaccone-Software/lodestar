import XCTest
@testable import lodestar
@testable import LodestarCore

/// Scripted keystrokes against the real engine, the real glass, and the
/// real coach, wired the way the app wires them.
///
/// `CoachSurfaceTests` (LodestarCore) pins the decisions one at a time:
/// which effects claim the panel, which handovers displace the coach, what
/// a read chip costs. These are the other half — the same decisions
/// reached by way of a keystroke, through `HotkeyEngine.handle`, the
/// effect loop, `HUD.handOver`, and `SurfaceWiring`, which is the seam the
/// unit tests could not see and where the 0.24.4 bug actually lived. Each
/// test asks two things of every moment: what the glass shows, and what
/// the coach believes it shows. They must agree.
final class SurfaceScenarioTests: XCTestCase {

    // MARK: - The regression, end to end

    /// A chip is standing; `lode s` completes a one-letter chain, whose
    /// effects are `[.hideGuide, .summonGraph]`. The glass goes dark, and
    /// the coach must know it did: no offer may be billed for a chip that
    /// stood five seconds.
    func testACompletedChainTakesTheGlassAndTheCoachKnows() {
        let stage = Stage()
        stage.raiseChip()

        stage.lode("s")

        XCTAssertEqual(stage.actions.summoned.map(\.target), [.app("Slack")])
        XCTAssertEqual(stage.hud.owner, .none)
        XCTAssertFalse(stage.coach.chipVisible)
        stage.clock.advance(by: Coach.seenSeconds + 1)
        XCTAssertNil(stage.ledger, "an erased chip was never read, so nothing is spent")
    }

    /// The same chip, and a letter that is nowhere on the graph. The miss
    /// flashes, and a flash is a takeover too.
    func testAMissFlashesOverTheChipAndTheChipYields() {
        let stage = Stage()
        stage.raiseChip()

        stage.lode("q")

        XCTAssertEqual(stage.hud.owner, .flash)
        XCTAssertFalse(stage.coach.chipVisible)
        // A flash stays as long as its words take to read; the ceiling is
        // four seconds, and past it every flash is gone.
        stage.clock.advance(by: 4.1)
        XCTAssertEqual(stage.hud.owner, .none, "a flash fades on its own")
        XCTAssertTrue(stage.actions.summoned.isEmpty)
    }

    /// A flash that no claim preceded — `lode ⇥` with nothing focused —
    /// reaches the coach through the glass itself. The engine never said
    /// it was taking the panel; the panel did, and that is the only road
    /// a flash from anywhere else in the app has.
    func testAFlashWithNoClaimBeforeItStillDisplacesTheChip() {
        let stage = Stage()
        stage.actions.focused = nil
        stage.raiseChip()

        stage.lode("tab")

        XCTAssertEqual(stage.hud.owner, .flash)
        XCTAssertFalse(stage.coach.chipVisible)
    }

    /// A chain guide over a chip is the hand working; the chip yields and
    /// escape clears the guide.
    func testAChainGuideDisplacesTheChipAndEscapeClearsIt() {
        let stage = Stage()
        stage.raiseChip()

        stage.hold()
        stage.press("b")
        XCTAssertEqual(stage.hud.owner, .guide)
        XCTAssertFalse(stage.coach.chipVisible)
        XCTAssertEqual(stage.engine.stateDescription, "chain(graph, 'b')")

        stage.press("escape")
        stage.release()
        XCTAssertEqual(stage.hud.owner, .none)
        XCTAssertEqual(stage.engine.stateDescription, "idle")
    }

    /// Holding lode peeks the graph on the same glass. Releasing it gives
    /// the glass back — and not to the chip, which has already yielded.
    func testThePeekTakesTheGlassAndReleaseGivesItBack() {
        let stage = Stage()
        stage.raiseChip()

        stage.hold()
        stage.clock.advance(by: 0.5)
        XCTAssertTrue(stage.engine.isPeeking)
        XCTAssertEqual(stage.hud.owner, .guide)
        XCTAssertFalse(stage.coach.chipVisible)

        stage.release()
        XCTAssertFalse(stage.engine.isPeeking)
        XCTAssertEqual(stage.hud.owner, .none)
    }

    /// The launcher is a surface of its own, but opening it claims the
    /// shared glass all the same: a chip must not stand behind a bar.
    func testOpeningABarDisplacesTheChip() {
        let stage = Stage()
        stage.raiseChip()

        stage.lode("space")

        XCTAssertTrue(stage.searcher.isVisible)
        XCTAssertFalse(stage.coach.chipVisible)
        XCTAssertFalse(stage.engine.isQuiet)

        stage.lode("space")
        XCTAssertFalse(stage.searcher.isVisible)
        XCTAssertTrue(stage.engine.isQuiet)
    }

    // MARK: - What leaves the chip alone

    /// Window work never touches the panel. `lode 2` jumps a window and
    /// the chip stays; ten seconds on, it is read and billed.
    func testWindowWorkLeavesTheChipStanding() {
        let stage = Stage()
        stage.raiseChip()

        stage.lode("2")

        XCTAssertEqual(stage.actions.indexJumps, [2])
        XCTAssertEqual(stage.hud.owner, .coach)
        XCTAssertTrue(stage.coach.chipVisible)
        stage.clock.advance(by: Coach.seenSeconds)
        XCTAssertEqual(stage.ledger?.offers, 1)
    }

    /// Redrawing the chip — the menu item re-presenting it — is not a
    /// takeover, and a viewing the user asked for spends nothing extra.
    func testTheChipRedrawnIsNotATakeover() {
        let stage = Stage()
        stage.raiseChip()

        stage.coach.presentParked()

        XCTAssertEqual(stage.hud.owner, .coach)
        XCTAssertTrue(stage.coach.chipVisible)
        stage.clock.advance(by: Coach.seenSeconds)
        XCTAssertEqual(stage.ledger?.offers, 1)
    }

    // MARK: - The chip's own life

    /// Read at ten seconds, billed once. Unanswered at sixty, it comes
    /// down and the ledger says it stood its whole life — the one fact the
    /// retry leash is priced on.
    func testAReadChipIsBilledOnceAndAnUnansweredOneStoodFull() {
        let stage = Stage()
        stage.raiseChip()

        stage.clock.advance(by: Coach.seenSeconds)
        XCTAssertEqual(stage.ledger?.offers, 1)
        XCTAssertEqual(stage.ledger?.lastShowingStood, false)

        stage.clock.advance(by: Coach.chipSeconds)
        XCTAssertFalse(stage.coach.chipVisible)
        XCTAssertEqual(stage.hud.owner, .none)
        XCTAssertEqual(stage.ledger?.offers, 1, "expiry is not a second offer")
        XCTAssertEqual(stage.ledger?.lastShowingStood, true)
        XCTAssertEqual(stage.ledger?.status, "offered", "ignoring is not an answer")
        XCTAssertNotNil(stage.coach.standing, "the suggestion stays on offer")
    }

    /// A boundary that arrives mid-chain waits: the engine is not quiet.
    /// Once the chain is cleared, the next boundary speaks.
    func testABoundaryMidChainWaitsForQuiet() {
        let stage = Stage()
        stage.stand()

        stage.hold()
        stage.press("b")
        stage.boundary()
        stage.clock.advance(by: Coach.settleSeconds + 1)
        XCTAssertEqual(stage.hud.owner, .guide)
        XCTAssertFalse(stage.coach.chipVisible)

        stage.press("escape")
        stage.release()
        stage.boundary()
        stage.clock.advance(by: Coach.settleSeconds + 0.1)
        XCTAssertEqual(stage.hud.owner, .coach)
        XCTAssertTrue(stage.coach.chipVisible)
    }

    /// The settle measures quiet since the most recent boundary, so a
    /// second navigation inside the wait starts it over.
    func testASecondBoundaryRestartsTheSettle() {
        let stage = Stage()
        stage.stand()

        stage.boundary()
        stage.clock.advance(by: 3)
        stage.boundary()
        stage.clock.advance(by: 3)
        XCTAssertFalse(stage.coach.chipVisible, "only three seconds since the last boundary")
        stage.clock.advance(by: Coach.settleSeconds - 3 + 0.1)
        XCTAssertTrue(stage.coach.chipVisible)
        XCTAssertEqual(stage.hud.owner, .coach)
    }

    // MARK: - The two gestures

    /// lode ⌫ with a chip up: answered, recorded, and the key swallowed —
    /// it must never reach the app in front as ⌘⌫.
    func testLodeDeleteAnswersAStandingChipAndSwallowsTheKey() {
        let stage = Stage()
        stage.raiseChip()

        let swallowed = stage.lode("delete")

        XCTAssertTrue(swallowed)
        XCTAssertEqual(stage.ledger?.status, "never")
        XCTAssertFalse(stage.coach.chipVisible)
        XCTAssertNil(stage.coach.standing)
        XCTAssertEqual(stage.hud.owner, .flash, "the small flash is the receipt")
    }

    /// The same key with nothing standing passes through untouched.
    func testLodeDeleteWithNothingStandingPassesThrough() {
        let stage = Stage()

        let swallowed = stage.lode("delete")

        XCTAssertFalse(swallowed)
        XCTAssertEqual(stage.hud.owner, .none)
    }

    /// Two taps of lode: assent. Exactly one config line is asked for,
    /// the ledger records the accept, and the chip is gone.
    func testADoubleTapAssentsAndWritesOneLine() {
        let stage = Stage()
        stage.raiseChip()

        stage.doubleTapLode()

        XCTAssertEqual(stage.edits, [.bindTarget(chain: ["n"], target: "Notes")])
        XCTAssertEqual(stage.ledger?.status, "accepted")
        XCTAssertFalse(stage.coach.chipVisible)
        XCTAssertEqual(stage.hud.owner, .none)
        XCTAssertNil(stage.coach.standing)
    }

    /// Assent writes config, so it must be a hand's: a posted double tap
    /// agrees to nothing, and the chip stands on.
    func testAPostedDoubleTapAgreesToNothing() {
        let stage = Stage()
        stage.raiseChip()

        stage.doubleTapLode(posted: true)

        XCTAssertTrue(stage.edits.isEmpty)
        XCTAssertTrue(stage.coach.chipVisible)
        XCTAssertEqual(stage.hud.owner, .coach)
    }

    /// A navigation driven by another process is a boundary with nobody
    /// in the chair. The coach holds; the next human one speaks.
    func testAPostedNavigationDoesNotSpeak() {
        let stage = Stage()
        stage.stand()

        stage.lode("s", posted: true)
        stage.clock.advance(by: Coach.settleSeconds + 1)
        XCTAssertEqual(stage.actions.summoned.count, 1, "the summon itself still happens")
        XCTAssertFalse(stage.coach.chipVisible)
        XCTAssertEqual(stage.hud.owner, .none)

        stage.lode("s")
        stage.clock.advance(by: Coach.settleSeconds + 0.1)
        XCTAssertTrue(stage.coach.chipVisible)
        XCTAssertEqual(stage.hud.owner, .coach)
    }

    // MARK: - The floor

    /// Every voice shares the lode-lode grammar, and the coach is asked
    /// last. A voice above it that takes the gesture leaves the coach's
    /// offer exactly as it was.
    func testAVoiceAboveTheCoachTakesTheGesture() {
        var assents = 0
        var dismissals = 0
        let voice = Voice(assent: { assents += 1; return true },
                          dismiss: { dismissals += 1; return true })
        let stage = Stage(voices: [voice])
        stage.raiseChip()

        stage.doubleTapLode()
        XCTAssertEqual(assents, 1)
        XCTAssertTrue(stage.edits.isEmpty)
        XCTAssertNotNil(stage.coach.standing)

        XCTAssertTrue(stage.lode("delete"), "a taken dismissal is still swallowed")
        XCTAssertEqual(dismissals, 1)
        XCTAssertNotEqual(stage.ledger?.status, "never")
        XCTAssertNotNil(stage.coach.standing)
    }

    /// A voice that declines the gesture is passed over, and the coach
    /// answers as if it were alone.
    func testAVoiceThatDeclinesIsPassedOver() {
        let voice = Voice(assent: { false }, dismiss: { false })
        let stage = Stage(voices: [voice])
        stage.raiseChip()

        stage.doubleTapLode()

        XCTAssertEqual(stage.edits.count, 1)
        XCTAssertEqual(stage.ledger?.status, "accepted")
    }
}
