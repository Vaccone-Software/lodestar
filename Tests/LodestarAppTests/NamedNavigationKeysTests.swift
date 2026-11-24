import XCTest
@testable import lodestar
@testable import LodestarCore

/// Forward delete, Home, End, Page Up and Page Down have names, so the tap
/// sees them. Unnamed, they passed to the app beneath every surface, and
/// fn ⌫ deleted a character in the field behind the draft. Each surface now
/// answers for them as it does for any key it has no use for, except where
/// passing them on is the surface's own job.
final class NamedNavigationKeysTests: XCTestCase {
    private let keys = ["forwarddelete", "home", "end", "pageup", "pagedown"]

    private func swallowed(_ setup: (Stage) -> Void, _ key: String) -> Bool {
        let stage = Stage()
        setup(stage)
        return stage.press(key)
    }

    func testTheDraftTakesThemAllInBothStylesAndEveryMode() {
        let setups: [(String, (Stage) -> Void)] = [
            ("Standard", { $0.draft.editingStyle = .standard; $0.lode(".") }),
            ("Vim insert", { $0.lode(".") }),
            ("Vim normal", { $0.lode("."); $0.press("escape") }),
        ]
        for (name, setup) in setups {
            for key in keys { XCTAssertTrue(swallowed(setup, key), "\(name): \(key)") }
        }
    }

    func testTheClipboardStripAndAChainTakeThemToo() {
        for key in keys {
            XCTAssertTrue(swallowed({ $0.seedClip("a"); $0.openStrip() }, key), "strip: \(key)")
            XCTAssertTrue(swallowed({ $0.hold(); $0.press("b") }, key), "a chain under lode: \(key)")
        }
    }

    func testAnIdleKeyboardAndAHeldLodeStillPassThem() {
        for key in keys {
            XCTAssertFalse(swallowed({ _ in }, key), "idle: \(key)")
            XCTAssertFalse(swallowed({ $0.hold() }, key), "⌘ with the keys of a text field: \(key)")
        }
    }

    func testScrollModeKeepsPassingTheFourThatScrollAPage() {
        for key in keys where key != "forwarddelete" {
            XCTAssertFalse(swallowed({ $0.lode("`") }, key), "scroll: \(key)")
        }
        XCTAssertTrue(swallowed({ $0.lode("`") }, "forwarddelete"), "mode discipline for the rest")
    }
}
