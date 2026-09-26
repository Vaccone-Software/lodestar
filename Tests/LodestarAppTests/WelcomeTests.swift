import XCTest
@testable import lodestar
@testable import LodestarCore

/// The first launch's words: one reason per door, said before macOS asks,
/// and the note for an administrator.
final class WelcomeTests: XCTestCase {
    func testEveryDoorSaysWhatItNeedsAccessibilityFor() {
        for door in Walk.Door.allCases {
            let reason = WalkController.permissionReason(door)
            XCTAssertTrue(reason.contains("Accessibility"), "\(door): the permission is named")
            XCTAssertTrue(reason.hasSuffix("."), "\(door): a reason is a sentence")
        }
        XCTAssertTrue(WalkController.permissionReason(.speak).contains("microphone"),
                      "Speak says the microphone comes later, and when")
    }

    func testTheWelcomeLinesAreDescriptionsWithoutAPeriod() {
        for door in Walk.Door.allCases {
            let line = WalkController.doorLine(door)
            XCTAssertFalse(line.hasSuffix("."), "\(door)")
            XCTAssertFalse(line.isEmpty)
        }
    }

    func testTheNoteForITNamesTheOnePermissionAndWhere() {
        XCTAssertTrue(WalkController.itNote.contains("Accessibility"))
        XCTAssertTrue(WalkController.itNote.contains("Privacy & Security"))
        XCTAssertTrue(WalkController.standardAccountNote.contains("administrator"))
    }

    func testTheGrammarOfferSaysWhatItCosts() {
        XCTAssertEqual(AppDelegate.walkEngineAnswer("standard").hasPrefix("download Standard, "), true)
        XCTAssertTrue(AppDelegate.walkEngineAnswer("minimal").contains("Apple"),
                      "Minimal downloads nothing and says whose model it is")
    }
}
