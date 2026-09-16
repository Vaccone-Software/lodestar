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

    func testFingersFollowTheTouchTypingColumns() {
        XCTAssertEqual(Keys.finger(for: 0), .pinky)   // a
        XCTAssertEqual(Keys.finger(for: 1), .ring)    // s
        XCTAssertEqual(Keys.finger(for: 2), .middle)  // d
        XCTAssertEqual(Keys.finger(for: 3), .index)   // f
        XCTAssertEqual(Keys.finger(for: 5), .index)   // g
        XCTAssertEqual(Keys.finger(for: 4), .index)   // h
        XCTAssertEqual(Keys.finger(for: 38), .index)  // j
        XCTAssertEqual(Keys.finger(for: 40), .middle) // k
        XCTAssertEqual(Keys.finger(for: 37), .ring)   // l
        XCTAssertEqual(Keys.finger(for: 41), .pinky)  // ;
        XCTAssertEqual(Keys.finger(for: 49), .thumb)  // space
        XCTAssertEqual(Keys.finger(for: 56), .pinky)  // left shift
        XCTAssertEqual(Keys.finger(for: 59), .pinky)  // left control
        XCTAssertEqual(Keys.finger(for: 58), .ring)   // left option
        XCTAssertEqual(Keys.finger(for: 55), .thumb)  // left command
        XCTAssertEqual(Keys.finger(for: 123), .unknown, "arrows are not guessed")
    }

    func testModifiersAreTheirOwnKindAndHaveAHand() {
        XCTAssertEqual(Keys.modifier(for: 56), .shift)
        XCTAssertEqual(Keys.modifier(for: 60), .shift)
        XCTAssertEqual(Keys.modifier(for: 55), .command)
        XCTAssertEqual(Keys.modifier(for: 62), .control)
        XCTAssertEqual(Keys.modifier(for: 63), .fn)
        XCTAssertNil(Keys.modifier(for: 0))
        XCTAssertEqual(Keys.kind(for: 56), .modifier)
        XCTAssertEqual(Keys.hand(for: 56), .left)
        XCTAssertEqual(Keys.hand(for: 60), .right)
        XCTAssertFalse(Keys.Kind.modifier.isTyping)
        let press = KeyPress(down: Date(), hold: 2, hand: .left, kind: .modifier, modifiers: .control, struck: 4)
        XCTAssertFalse(press.isTyping)
        XCTAssertEqual(Keys.Modifiers.chording, [.command, .option, .control])
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
        XCTAssertEqual(Keys.kind(for: 63), .modifier) // fn is a modifier now, with its own record
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
