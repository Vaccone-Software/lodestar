import AppKit
import XCTest
@testable import lodestar

/// The click door's press goes to the smallest target under the point,
/// never to the wrapper that happens to come first in the tree.
final class HintOwnerTests: XCTestCase {
    private func target(_ rect: CGRect, viaAction: Bool = false) -> HintTargets.Target {
        HintTargets.Target(element: AXUIElementCreateSystemWide(), frame: rect,
                           isTextInput: false, viaAction: viaAction)
    }

    func testTheSmallestEnclosingTargetOwnsThePoint() {
        let wrapper = target(CGRect(x: 0, y: 0, width: 600, height: 200), viaAction: true)
        let button = target(CGRect(x: 500, y: 20, width: 67, height: 28))
        let elsewhere = target(CGRect(x: 0, y: 300, width: 50, height: 50))
        let owner = HintTargets.owner(of: CGPoint(x: 533, y: 34), among: [wrapper, button, elsewhere])
        XCTAssertEqual(owner?.frame, button.frame, "the button, not the wrapper listed before it")
    }

    func testAtEqualSizeTheRoleNamedTargetWins() {
        let byAction = target(CGRect(x: 10, y: 10, width: 40, height: 40), viaAction: true)
        let byRole = target(CGRect(x: 10, y: 10, width: 40, height: 40))
        XCTAssertEqual(HintTargets.owner(of: CGPoint(x: 30, y: 30), among: [byAction, byRole])?.viaAction, false)
    }

    func testNoTargetUnderThePointMeansNone() {
        XCTAssertNil(HintTargets.owner(of: CGPoint(x: 5, y: 5),
                                       among: [target(CGRect(x: 100, y: 100, width: 10, height: 10))]))
    }
}
