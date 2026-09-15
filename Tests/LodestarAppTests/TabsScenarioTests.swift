import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// `lode ⇥`: a letter on every tab of the window, the letter presses it,
/// and a window with no tabs says so and stands down.
final class TabsScenarioTests: XCTestCase {
    private var harvested: [HintTargets.Target] = []

    override func setUp() {
        harvested = []
        // Lands a turn later, the way the real walk does: a harvest that
        // answered inside the keystroke would mutate the engine mid-key.
        HintTargets.harvestTabs = { [unowned self] _, done in DispatchQueue.main.async { done(self.harvested) } }
    }

    /// A window in front, so the door has something to open onto.
    private func stand(_ stage: Stage) {
        stage.model.stand(WindowModel.Window(
            id: 7, element: AXUIElementCreateSystemWide(), pid: 1, appName: "Ghostty",
            bundleID: "com.mitchellh.ghostty", title: "tabs",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMinimized: false, isAlive: true, lastFocused: Date()))
    }

    private func tab(x: CGFloat) -> HintTargets.Target {
        HintTargets.Target(element: AXUIElementCreateSystemWide(),
                           frame: CGRect(x: x, y: 40, width: 120, height: 32),
                           isTextInput: false, viaAction: true)
    }

    func testEveryTabWearsALetterAndALetterPressesIt() throws {
        harvested = [tab(x: 10), tab(x: 140), tab(x: 270)]
        let stage = Stage()
        stand(stage)
        stage.lode("tab")
        stage.clock.advance(by: 0.1)
        XCTAssertTrue(stage.engine.stateDescription.contains("hints"), "the click door's machine, at the tabs door")
        XCTAssertEqual(stage.engine.select.door, .tabs)
        let chips = stage.engine.select.shownChips
        XCTAssertEqual(chips.count, 3, "one chip per tab the tree named, none on the current one")
        XCTAssertEqual(Set(chips.map(\.label)).count, 3, "every letter distinct")
        let first = try XCTUnwrap(chips.first).label
        XCTAssertEqual(first.count, 1, "a single letter with three tabs")
        XCTAssertTrue(stage.press(first), "a lowercase letter is a pick: there is no search here")
        XCTAssertFalse(stage.engine.stateDescription.contains("hints"), "pressed, and the mode is over")
    }

    func testAWindowWithNoTabsSaysSoAndStandsDown() {
        harvested = []
        let stage = Stage()
        stand(stage)
        stage.lode("tab")
        stage.clock.advance(by: 0.1)
        XCTAssertFalse(stage.engine.stateDescription.contains("hints"), "nothing to letter, nothing to stand in")
        XCTAssertEqual(stage.hud.owner, .flash)
    }

    func testShiftTabStillListsTheWindows() {
        let stage = Stage()
        stand(stage)
        stage.lode("tab", shift: true)
        XCTAssertFalse(stage.engine.stateDescription.contains("hints"))
        XCTAssertTrue(stage.searcher.isVisible, "the chooser is the launcher in its windows mode")
    }
}
