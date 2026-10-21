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

    /// A door is pressed and chosen, so each tile is a key on a side and the
    /// chosen one is the slab: never a well, never an accent ring.
    func testEveryDoorTileIsAKeyAndTheChosenOneIsTheSlab() {
        let walk = WalkController()
        let none = walk.doorTilesForTesting(chosen: nil)
        XCTAssertEqual(none.count, Walk.Door.allCases.count)
        XCTAssertTrue(none.allSatisfy { $0.stance == .key }, "pressed things stand on a side")
        let tiles = walk.doorTilesForTesting(chosen: .speak)
        let at = Walk.Door.allCases.firstIndex(of: .speak)!
        XCTAssertEqual(tiles.map(\.stance), Walk.Door.allCases.indices.map { $0 == at ? .slab : .key },
                       "the chosen door is the slab, the rest keys")
        XCTAssertNotNil(tiles[at].appearance, "and everything on the slab is in the other look")
        XCTAssertNil(tiles[(at + 1) % tiles.count].appearance)
    }
}
