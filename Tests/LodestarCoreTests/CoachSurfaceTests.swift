import XCTest
@testable import LodestarCore

/// The seam where the coach's chip meets the glass it shares with the
/// chain guide.
///
/// This is where the coach's first real bug lived, and it lived there
/// because the decision had been left in the untested part of the app:
/// `Coach` owned every policy and was covered, while "who has the panel"
/// was an ad-hoc list in the controller that one effect had fallen off.
/// `.hideGuide` draws nothing, so it did not look like a claim — but every
/// completed chain emits one, and it orders the panel out. A chip drawn at
/// a boundary was erased by the next chain three hundred milliseconds
/// later, and billed as a full offer ten seconds after that. Twice, to a
/// user who reported seeing nothing.
///
/// So these are the tests that keep the decision where it can be checked.
final class CoachSurfaceTests: XCTestCase {

    // MARK: - Which effects take the glass

    /// The regression itself. A completed graph chain emits
    /// `[.hideGuide, .summonGraph]`, so if `hideGuide` does not claim the
    /// surface, navigating away silently erases the chip.
    func testHideGuideClaimsTheSurface() {
        XCTAssertTrue(EngineEffect.hideGuide.claimsSurface)
    }

    /// Everything that puts pixels on the shared panel, or takes them off
    /// it, has to say so. Listed one by one rather than in a loop: the
    /// point is that adding an effect to the panel means adding it here.
    func testEveryPanelWriterClaimsTheSurface() {
        let writers: [EngineEffect] = [
            .hideGuide,
            .showGuide(kind: .graph, letters: ["b"], deleting: false, note: nil),
            .scrollGuide,
            .hideBars,
            .showSearcher,
            .showWebBar,
            .showCommandsBar,
            .openWindowChooser,
            .enterPaste,
            .toggleCheat,
        ]
        for effect in writers {
            XCTAssertTrue(effect.claimsSurface, "\(effect) writes to the panel")
        }
    }

    /// The other half of the contract: an effect that never touches the
    /// panel must not dismiss a standing chip. A chip that yielded to every
    /// window move would never survive to be read.
    func testWindowWorkDoesNotClaimTheSurface() {
        let quiet: [EngineEffect] = [
            .summonGraph(letters: ["b", "x"], beside: false),
            .maximizeFocused(beside: false),
            .undoLayout,
            .redoLayout,
            .flipOrientation,
            .indexJump(2),
            .reorder(1),
            .moveDisplay(direction: 1, beside: false),
            .passThrough,
        ]
        for effect in quiet {
            XCTAssertFalse(effect.claimsSurface, "\(effect) leaves the panel alone")
        }
    }

    // MARK: - Handing the panel over

    func testGuideDrawnOverChipDisplacesTheCoach() {
        XCTAssertTrue(Surface.displacesCoach(from: .coach, to: .guide))
    }

    func testHidingTheChipDisplacesTheCoach() {
        XCTAssertTrue(Surface.displacesCoach(from: .coach, to: .none))
    }

    func testFlashOverChipDisplacesTheCoach() {
        XCTAssertTrue(Surface.displacesCoach(from: .coach, to: .flash))
    }

    /// Redrawing the chip is not a takeover. The coach updates its own
    /// panel and must not dismiss itself doing it.
    func testCoachRedrawingItselfIsNotATakeover() {
        XCTAssertFalse(Surface.displacesCoach(from: .coach, to: .coach))
    }

    /// Only the coach outlives the gesture that drew it, so only the coach
    /// is notified. A guide replaced by a guide is the same hand working.
    func testOnlyTheCoachIsDisplaced() {
        for from: SurfaceOwner in [.none, .guide, .flash] {
            for to: SurfaceOwner in [.none, .guide, .flash, .coach] {
                XCTAssertFalse(Surface.displacesCoach(from: from, to: to),
                               "\(from) → \(to) is nobody's loss")
            }
        }
    }

    // MARK: - What it means to have been read

    /// The rule the code always claimed and did not enforce: an offer is
    /// spent by being read, not by being drawn.
    func testAReadChipCounts() {
        XCTAssertTrue(Coach.offerCounts(stoodFor: Coach.seenSeconds,
                                        ownsSurface: true, present: true))
    }

    /// The bug, as a test. The timer fires on schedule and the user is
    /// right there — but the chip was ordered off the glass seconds ago,
    /// so there was nothing to read and nothing may be charged.
    func testAnErasedChipDoesNotCount() {
        XCTAssertFalse(Coach.offerCounts(stoodFor: Coach.seenSeconds,
                                         ownsSurface: false, present: true))
    }

    func testAChipNobodyWasThereForDoesNotCount() {
        XCTAssertFalse(Coach.offerCounts(stoodFor: Coach.seenSeconds,
                                         ownsSurface: true, present: false))
    }

    /// Taken down before the checkpoint: drawn, not read.
    func testAChipTakenDownEarlyDoesNotCount() {
        XCTAssertFalse(Coach.offerCounts(stoodFor: Coach.seenSeconds - 0.1,
                                         ownsSurface: true, present: true))
    }

    // MARK: - The settle

    /// The wait has to be long enough that a chip surviving it is likely to
    /// survive to the checkpoint that charges for it, and shorter than the
    /// chip's own life, or it could never be drawn at all.
    func testSettleIsShorterThanTheChipItProtects() {
        XCTAssertGreaterThan(Coach.settleSeconds, 0)
        XCTAssertLessThan(Coach.settleSeconds, Coach.seenSeconds)
        XCTAssertLessThan(Coach.settleSeconds, Coach.chipSeconds)
    }

    /// A settle that outlasted the reshow floor would let a boundary paint
    /// a chip the floor was still holding back.
    func testSettleIsShorterThanTheReshowFloor() {
        XCTAssertLessThan(Coach.settleSeconds, Coach.reshowSeconds)
    }
}
