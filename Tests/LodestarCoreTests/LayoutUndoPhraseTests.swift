import XCTest
@testable import LodestarCore

/// A chord phrase is one gesture to undo: its joining letter rides the step
/// the phrase's own first letter recorded. A letter that records nothing
/// (a window already in the layout, a display at its cap) joins nothing and
/// leaves nothing standing for the next gesture, and a letter whose phrase
/// recorded no step of its own makes one, never riding the hand's earlier
/// gesture.
final class LayoutUndoPhraseTests: XCTestCase {
    private let display = CGRect(x: 0, y: 0, width: 1600, height: 900)
    private var model: PhraseFakeWindows!
    private var layout: LayoutController!

    override func setUp() {
        model = PhraseFakeWindows()
        let mover = PhraseFakeMover(model: model)
        let oracle = DisplayOracle(
            ordered: { [Displays.DisplayInfo(id: 1, bounds: self.display)] },
            visibleFrame: { _ in self.display },
            displayContaining: { _ in Displays.DisplayInfo(id: 1, bounds: self.display) },
            uuid: { _ in "uuid" })
        layout = LayoutController(model: model, parking: ParkingLot(mover: mover, bounds: { [self.display] }),
                                  mover: mover, displays: oracle)
        layout.reconcileDisplays()
        for id in 10...60 { model.addWindow(CGWindowID(id)) }
    }

    /// A placement as `Actions.place` makes it: the layout verb between the
    /// scope's begin and end. A phrase's first letter, and any placement
    /// outside a phrase, is not joining.
    private func letter(_ verb: () -> Void) {
        layout.beginPlacement(joining: false)
        defer { layout.endPlacement() }
        verb()
    }

    /// A phrase's later letter.
    private func joiningLetter(_ verb: () -> Void) {
        layout.beginPlacement(joining: true)
        defer { layout.endPlacement() }
        verb()
    }

    private func standing() {
        layout.replace(with: 10, on: 1)
        layout.add(20, on: 1)
    }

    func testAJoiningLetterForAWindowAlreadyInTheLayoutFoldsNothingIntoTheNextGesture() {
        standing()
        letter { layout.add(30, on: 1) } // the phrase's first letter, its own step
        XCTAssertEqual(layout.members(on: 1), [10, 20, 30])

        joiningLetter { _ = layout.add(20, on: 1) } // already a member: nothing recorded
        XCTAssertEqual(layout.members(on: 1), [10, 20, 30])

        // Minutes later, an unrelated gesture.
        letter { layout.replace(with: 40, on: 1) }
        _ = layout.undo()
        XCTAssertEqual(layout.members(on: 1), [10, 20, 30], "one undo takes back the replace alone")
    }

    func testAJoiningLetterRefusedAtTheCapFoldsNothingIntoTheNextGesture() {
        layout.replace(with: 10, on: 1)
        for id in 11..<(10 + CGWindowID(LayoutController.maxWindows)) { layout.add(id, on: 1) }
        XCTAssertEqual(layout.members(on: 1).count, LayoutController.maxWindows)
        let full = layout.members(on: 1)

        joiningLetter { XCTAssertFalse(layout.add(50, on: 1), "the tenth window is refused") }

        letter { layout.replace(with: 40, on: 1) }
        _ = layout.undo()
        XCTAssertEqual(layout.members(on: 1), full, "one undo takes back the replace alone")
    }

    func testAJoiningLetterThatNamesAWindowOnAnotherDisplayFoldsNothingIntoTheNextGesture() {
        // A visit touches no layout at all: the scope opens and closes on
        // nothing, as `Actions.place` does for it.
        standing()
        joiningLetter {}
        letter { layout.replace(with: 40, on: 1) }
        _ = layout.undo()
        XCTAssertEqual(layout.members(on: 1), [10, 20], "one undo takes back the replace alone")
    }

    func testAPhraseWhoseFirstLetterRecordedNothingJoinsNoEarlierGesture() {
        standing()
        letter { layout.add(30, on: 1) } // the hand's earlier gesture
        // The phrase: its first letter names a window already in the layout.
        letter { _ = layout.add(20, on: 1) }
        joiningLetter { _ = layout.add(40, on: 1) }
        XCTAssertEqual(layout.members(on: 1), [10, 20, 30, 40])

        _ = layout.undo()
        XCTAssertEqual(layout.members(on: 1), [10, 20, 30], "the phrase's letter is undone alone")
        _ = layout.undo()
        XCTAssertEqual(layout.members(on: 1), [10, 20], "and the earlier gesture is a step of its own")
    }

    func testAFirstLetterWhoseStepWasTheSameAsTheOneBeforeItLeavesThePhraseWithNoStep() {
        standing()
        layout.remove(20) // the world took it; the step that added it still stands on top
        letter { layout.add(20, on: 1) } // the same step again: nothing is recorded
        joiningLetter { layout.add(30, on: 1) }
        XCTAssertEqual(layout.members(on: 1), [10, 20, 30])

        _ = layout.undo()
        XCTAssertEqual(layout.members(on: 1), [10, 20], "the later letter makes a step of its own")
    }

    func testALetterThatRecordedNothingLeavesTheNextOneJoiningTheFirstLettersStep() {
        standing()
        letter { layout.add(30, on: 1) } // G
        joiningLetter { _ = layout.add(30, on: 1) } // B: a member already
        joiningLetter { layout.add(40, on: 1) } // S
        XCTAssertEqual(layout.members(on: 1), [10, 20, 30, 40])

        _ = layout.undo()
        XCTAssertEqual(layout.members(on: 1), [10, 20], "G and S are one phrase, one step")
    }

    func testEveryLaterLetterOfALongPhraseJoinsTheOneStep() {
        standing()
        letter { layout.add(30, on: 1) }
        joiningLetter { layout.add(40, on: 1) }
        joiningLetter { layout.add(50, on: 1) }
        joiningLetter { layout.add(60, on: 1) }
        XCTAssertEqual(layout.members(on: 1), [10, 20, 30, 40, 50, 60])

        _ = layout.undo()
        XCTAssertEqual(layout.members(on: 1), [10, 20], "four letters, one step")
    }

    func testAThirdLetterJoinsTheSecondLettersStepWhenTheSecondHadToMakeOne() {
        standing()
        letter { _ = layout.add(20, on: 1) } // G: nothing recorded
        joiningLetter { layout.add(30, on: 1) } // B: a step of its own
        joiningLetter { layout.add(40, on: 1) } // S
        _ = layout.undo()
        XCTAssertEqual(layout.members(on: 1), [10, 20], "B and S are one phrase, one step")
        _ = layout.undo()
        XCTAssertEqual(layout.members(on: 1), [10], "and the step before them is its own")
    }

    func testAnUndoBetweenTwoLettersOfAPhraseLeavesTheNextOneItsOwnStep() {
        standing()
        letter { layout.add(30, on: 1) }
        _ = layout.undo()
        XCTAssertEqual(layout.members(on: 1), [10, 20])

        joiningLetter { layout.add(40, on: 1) }
        XCTAssertEqual(layout.members(on: 1), [10, 20, 40])
        _ = layout.undo()
        XCTAssertEqual(layout.members(on: 1), [10, 20], "the letter is undone alone, not with the step beneath it")
        _ = layout.undo()
        XCTAssertEqual(layout.members(on: 1), [10])
    }

    func testAGestureThatIsNotAPlacementBetweenTwoLettersLeavesTheNextOneItsOwnStep() {
        standing()
        letter { layout.add(30, on: 1) }
        layout.flipOrientation(on: 1)
        let flipped = layout.orientation(on: 1)
        joiningLetter { layout.add(40, on: 1) }

        _ = layout.undo()
        XCTAssertEqual(layout.members(on: 1), [10, 20, 30], "the letter is undone alone")
        XCTAssertEqual(layout.orientation(on: 1), flipped, "and the flip stands")
        _ = layout.undo()
        XCTAssertNotEqual(layout.orientation(on: 1), flipped, "the flip is a step of its own")
    }

    func testAtTheCapOfTwentyStepsAJoiningLetterStillFoldsNothingIntoAnotherGesturesStep() {
        layout.replace(with: 10, on: 1)
        for _ in 0..<25 { layout.flipOrientation(on: 1) } // past the cap, the oldest aged out
        letter { layout.add(20, on: 1) }
        layout.flipOrientation(on: 1) // the stack's depth is unchanged, its top is not
        let flipped = layout.orientation(on: 1)
        joiningLetter { layout.add(30, on: 1) }

        _ = layout.undo()
        XCTAssertEqual(layout.members(on: 1), [10, 20], "the letter is undone alone")
        XCTAssertEqual(layout.orientation(on: 1), flipped, "the flip is not undone with it")
    }

    func testAJoiningLetterThatRecordsStillClearsRedo() {
        standing()
        letter { layout.add(30, on: 1) }
        _ = layout.undo()
        joiningLetter { layout.add(40, on: 1) }
        XCTAssertNil(layout.redo(), "a new step ends the redo")
    }

    func testAJoiningLetterThatFoldsStillClearsRedo() {
        standing()
        letter { layout.add(30, on: 1) }
        joiningLetter { layout.add(40, on: 1) }
        XCTAssertNil(layout.redo(), "nothing to redo after a new gesture")
        _ = layout.undo()
        XCTAssertEqual(layout.members(on: 1), [10, 20])
        XCTAssertNotNil(layout.redo(), "and an undone phrase redoes as one")
        XCTAssertEqual(layout.members(on: 1), [10, 20, 30, 40])
    }
}

private final class PhraseFakeWindows: WindowQuerying {
    var windows: [CGWindowID: WindowModel.Window] = [:]
    var focusedWindow: WindowModel.Window?
    func window(_ id: CGWindowID) -> WindowModel.Window? { windows[id] }
    func refreshFrame(_ id: CGWindowID) {}
    func addWindow(_ id: CGWindowID,
                   frame: CGRect = CGRect(x: 50, y: 50, width: 800, height: 600)) {
        windows[id] = WindowModel.Window(
            id: id, element: AXUIElementCreateApplication(1), pid: 1,
            appName: "App\(id)", bundleID: "app.\(id)", title: "W\(id)",
            frame: frame, isMinimized: false, isAlive: true,
            lastFocused: nil, deadAt: nil)
    }
}

// Unchecked: these tests run it inline, on the test thread alone.
private final class PhraseFakeMover: WindowMoving, @unchecked Sendable {
    let model: PhraseFakeWindows
    init(model: PhraseFakeWindows) { self.model = model }
    func setFrame(_ window: WindowModel.Window, _ frame: CGRect) -> Bool {
        model.windows[window.id]?.frame = frame
        return true
    }
    func setPosition(_ window: WindowModel.Window, _ point: CGPoint) -> Bool {
        model.windows[window.id]?.frame.origin = point
        return true
    }
    func raise(_ window: WindowModel.Window) {}
}
