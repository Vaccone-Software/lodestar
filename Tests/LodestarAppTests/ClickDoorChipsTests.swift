import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The click door's chips are spent once. The harvest answers twice — the
/// chips, then the owners its walk found past them — and words can land
/// between the two; none of that may move a chip under a hand that has
/// begun to read them, or a capital fires a different target.
final class ClickDoorChipsTests: XCTestCase {
    private var stage: Stage!
    private var answer: (([HintTargets.Target]) -> Void)?

    override func setUp() {
        stage = Stage()
        stage.model.stand(WindowModel.Window(
            id: 9, element: AXUIElementCreateSystemWide(), pid: 1, appName: "Brave Browser",
            bundleID: "com.brave.Browser", title: "page",
            frame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            isMinimized: false, isAlive: true, lastFocused: Date()))
        stage.engine.select.sensing = { _, _ in }
        stage.engine.select.harvesting = { [weak self] _, _, completion in self?.answer = completion }
    }

    override func tearDown() {
        stage.engine.select.exit()
        stage = nil
    }

    private func target(_ frame: CGRect, viaAction: Bool) -> HintTargets.Target {
        HintTargets.Target(element: AXUIElementCreateSystemWide(), frame: frame,
                           isTextInput: false, viaAction: viaAction)
    }

    private var chips: [String: CGRect] {
        Dictionary(uniqueKeysWithValues: zip(stage.engine.select.entryLabels,
                                             stage.engine.select.entryLabeled.map(\.frame)))
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// A full harvest: a role-named button first, then pressables found
    /// by their action. No words yet, so the chips are spent when the wait
    /// for them runs out; then a word lands on the button, and the walk's
    /// second answer brings an owner. The chips stand as they were.
    func testTheSecondAnswerAndLateWordsNeverMoveAChip() throws {
        let capacity = HintLabels.capacity(alphabet: stage.engine.select.letters)
        let button = CGRect(x: 10, y: 10, width: 120, height: 30)
        var first = [target(button, viaAction: false)]
        for index in 1..<capacity {
            first.append(target(CGRect(x: 10 + CGFloat(index % 20) * 70, y: 60 + CGFloat(index / 20) * 40,
                                       width: 60, height: 30), viaAction: true))
        }
        XCTAssertTrue(stage.engine.select.enter(door: .click))
        let deliver = try XCTUnwrap(answer, "the door asked the tree")
        deliver(first)
        wait(0.6)
        let spent = chips
        XCTAssertEqual(spent.count, capacity, "every target is unreachable with no words, so each wears a chip")
        XCTAssertEqual(spent[stage.engine.select.entryLabels[0]], button)

        stage.engine.select.adopt([(element: AXUIElementCreateSystemWide(),
                                    frame: CGRect(x: 20, y: 15, width: 60, height: 20), text: "Share",
                                    settable: false, bounded: true, lineTier: false)])
        let owner = target(CGRect(x: 10, y: 900, width: 80, height: 30), viaAction: false)
        deliver(first + [owner])
        wait(0.1)

        XCTAssertEqual(chips, spent, "no chip moved")
        XCTAssertEqual(stage.engine.select.entryTargets.count, capacity + 1,
                       "the owner joins the targets a typed pick can land on")
    }
}
