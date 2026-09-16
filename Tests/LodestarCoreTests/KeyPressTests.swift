import XCTest
@testable import LodestarCore

/// The keycode is read once, to name a hand and a kind, and no more.
final class KeyPressTests: XCTestCase {
    func testTheHomeRowSplitsByHand() {
        XCTAssertEqual(Keys.hand(for: Keys.codes["a"]!), .left)
        XCTAssertEqual(Keys.hand(for: Keys.codes["f"]!), .left)
        XCTAssertEqual(Keys.hand(for: Keys.codes["j"]!), .right)
        XCTAssertEqual(Keys.hand(for: Keys.codes[";"]!), .right)
        XCTAssertEqual(Keys.hand(for: Keys.codes["space"]!), .thumb)
        XCTAssertEqual(Keys.hand(for: Keys.codes["return"]!), .other)
        XCTAssertEqual(Keys.hand(for: Keys.codes["6"]!), .right)
        XCTAssertEqual(Keys.hand(for: Keys.codes["5"]!), .left)
    }

    func testEveryNamedKeyHasAKind() {
        for (code, name) in Keys.ansi {
            let kind = Keys.kind(for: code)
            switch name {
            case "space": XCTAssertEqual(kind, .space)
            case "delete": XCTAssertEqual(kind, .backspace)
            case "return": XCTAssertEqual(kind, .enter)
            case "tab": XCTAssertEqual(kind, .tab)
            case "escape": XCTAssertEqual(kind, .escape)
            case "left", "right", "up", "down": XCTAssertEqual(kind, .navigation)
            default:
                if name.count == 1, name.first!.isLetter { XCTAssertEqual(kind, .letter, name) }
                else if name.count == 1, name.first!.isNumber { XCTAssertEqual(kind, .digit, name) }
                else { XCTAssertEqual(kind, .punctuation, name) }
            }
        }
        XCTAssertEqual(Keys.kind(for: 122), .function) // F1
        XCTAssertEqual(Keys.kind(for: 82), .keypad) // keypad 0
        XCTAssertEqual(Keys.kind(for: 63), .other) // fn
    }

    func testTypingIsTheHabitAndNothingElse() {
        let now = Date()
        XCTAssertTrue(KeyPress(down: now, hold: 0.1, hand: .left, kind: .letter).isTyping)
        XCTAssertTrue(KeyPress(down: now, hold: 0.1, hand: .thumb, kind: .space, shift: true).isTyping)
        XCTAssertFalse(KeyPress(down: now, hold: 0.1, hand: .left, kind: .letter, chord: true).isTyping)
        XCTAssertFalse(KeyPress(down: now, hold: 0.1, hand: .left, kind: .letter, gesture: true).isTyping)
        XCTAssertFalse(KeyPress(down: now, hold: 0.1, hand: .left, kind: .letter, repeated: true).isTyping)
        XCTAssertFalse(KeyPress(down: now, hold: 0.1, hand: .other, kind: .backspace).isTyping)
    }

    func testTheInstallIdIsWrittenOnceAndKept() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = Install.id(in: dir)
        XCTAssertEqual(first.count, 36)
        XCTAssertEqual(Install.id(in: dir), first)
    }
}
