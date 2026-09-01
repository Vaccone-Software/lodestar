import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The find lights, read from the storage the screen reads. The first
/// build of this feature set state correctly, passed its state tests,
/// and painted nothing: it drew background washes that the glass's
/// vibrancy composited away. Only an assertion against the rendered
/// attributes catches that class of bug.
final class DraftPanelFindTests: XCTestCase {
    private func litPositions(_ panel: DraftPanel) -> [Int] {
        guard let storage = panel.textView.textStorage else { return [] }
        var lit: [Int] = []
        for i in 0..<storage.length {
            if let color = storage.attribute(.foregroundColor, at: i, effectiveRange: nil) as? NSColor,
               color == NSColor.controlAccentColor {
                lit.append(i)
            }
        }
        return lit
    }

    func testFindLightsRecolorTheRenderedLetters() {
        let panel = DraftPanel()
        var buffer = Draft.Buffer(text: "alpha\nbravo")
        buffer.setCursor(0)
        var view = DraftView(buffer: buffer, mode: .normal, speech: nil,
                             destination: nil, replacing: false)
        view.findTargets = [1, 6]
        panel.show(view)
        XCTAssertEqual(litPositions(panel), [1, 6],
                       "the letters the screen shows are the ones recolored")
        panel.hide()
    }

    func testNoLightsWhileTheGhostStands() {
        let panel = DraftPanel()
        var buffer = Draft.Buffer(text: "alpha")
        buffer.setCursor(5)
        buffer.showGhost("bravo")
        var view = DraftView(buffer: buffer, mode: .insert, speech: nil,
                             destination: nil, replacing: false)
        view.findTargets = [1]
        panel.show(view)
        XCTAssertTrue(litPositions(panel).isEmpty,
                      "the ghost shifts every position, so nothing may be painted over it")
        panel.hide()
    }
    /// The layout oracle behind visual `j`/`k`: it answers from the same
    /// line fragments the screen draws.
    func testVisualMoveWalksTheRenderedLines() {
        let panel = DraftPanel()
        var buffer = Draft.Buffer(text: "one\ntwo")
        buffer.setCursor(0)
        let view = DraftView(buffer: buffer, mode: .normal, speech: nil,
                             destination: nil, replacing: false)
        panel.show(view)
        let down = panel.visualMove(from: 0, down: true, in: buffer)
        XCTAssertEqual(down, 4, "one visual line down from o lands on t")
        XCTAssertNil(panel.visualMove(from: 5, down: true, in: buffer),
                     "below the last line the layout has no answer")
        XCTAssertEqual(panel.visualMove(from: 4, down: false, in: buffer), 0)
        panel.hide()
    }
}
