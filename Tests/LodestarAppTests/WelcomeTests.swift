import AppKit
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

    /// The daily count is said once, on the welcome, as a caption: the
    /// meta size in the secondary colour, after everything else, with no
    /// mark and nothing to press.
    func testTheWelcomeSaysTheDailyCountOnceAndQuietly() throws {
        XCTAssertEqual(WalkController.countNote, DailyCount.welcomeNote)
        let (view, kept) = try GalleryChrome.walk(0)
        defer { withExtendedLifetime(kept) {} }
        var fields: [NSTextField] = []
        func read(_ view: NSView) {
            if let field = view as? NSTextField { fields.append(field) }
            view.subviews.forEach(read)
        }
        read(view)
        let notes = fields.filter { $0.stringValue == DailyCount.welcomeNote }
        XCTAssertEqual(notes.count, 1, "said once: \(fields.map(\.stringValue))")
        let note = try XCTUnwrap(notes.first)
        XCTAssertEqual(note.textColor, BarTheme.secondaryColor, "quiet")
        XCTAssertEqual(note.typeStyle?.role, .meta, "the caption's size")
        let lowest = fields.filter { !$0.stringValue.isEmpty && !$0.isHidden }
            .min { $0.convert($0.bounds, to: nil).minY < $1.convert($1.bounds, to: nil).minY }
        XCTAssertTrue(lowest === note, "the window's last line")
    }

    func testTheGrammarOfferSaysWhatItCosts() {
        XCTAssertEqual(AppDelegate.walkEngineAnswer("standard").hasPrefix("download Standard, "), true)
        XCTAssertTrue(AppDelegate.walkEngineAnswer("minimal").contains("Apple"),
                      "Minimal downloads nothing and says whose model it is")
    }
}
