import XCTest
@testable import LodestarCore

/// Where a key sits on one keyboard, declared, and what that declaration
/// is allowed to touch: the finger column, and nothing the windows read.
final class FingerMapTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// A press the way the tap names it from a keycode.
    private func press(code: Int64, at seconds: Double = 0, hold: Double? = 0.1) -> KeyPress {
        let modifier = Keys.modifier(for: code)
        return KeyPress(down: start.addingTimeInterval(seconds), hold: hold,
                        hand: Keys.hand(for: code),
                        kind: modifier == nil ? Keys.kind(for: code) : .modifier,
                        finger: Keys.finger(for: code),
                        modifiers: modifier ?? [])
    }

    // MARK: - The words

    func testAPlacementReadsAsSideAndFinger() {
        let placed = FingerMap.Placement(.right, .thumb)
        XCTAssertEqual(placed.text, "right thumb")
        XCTAssertEqual(placed.label, "Right thumb")
        XCTAssertEqual(FingerMap.Placement(parsing: "right thumb"), placed)
        XCTAssertEqual(FingerMap.Placement(parsing: "Either Pinky"), FingerMap.Placement(.either, .pinky))
        XCTAssertEqual(FingerMap.Placement(parsing: "left-index"), FingerMap.Placement(.left, .index))
        XCTAssertNil(FingerMap.Placement(parsing: "thumb"))
        XCTAssertNil(FingerMap.Placement(parsing: "right unknown"))
        XCTAssertNil(FingerMap.Placement(parsing: "up thumb"))
        XCTAssertNil(FingerMap.Placement(parsing: "right thumb please"))
        XCTAssertEqual(FingerMap.Placement.all.count, 15, "three sides, five fingers")
        for placed in FingerMap.Placement.all {
            XCTAssertEqual(FingerMap.Placement(parsing: placed.text), placed, "\(placed.text) round-trips")
        }
    }

    // MARK: - The keys the record can name

    /// The two ways in agree: the keycode at the tap and the stored
    /// press name the same key, for every key the map covers.
    func testASpecialKeyIsNamedTheSameFromTheKeycodeAndFromTheRow() {
        for key in Keys.SpecialKey.allCases {
            XCTAssertEqual(Keys.SpecialKey(keycode: key.keycode), key)
            XCTAssertEqual(Keys.SpecialKey(press: press(code: key.keycode)), key, "\(key) from its row")
        }
        XCTAssertEqual(Keys.SpecialKey(keycode: 117), .backspace, "forward delete is backspace in the record")
        XCTAssertEqual(Keys.SpecialKey(keycode: 76), .enter, "the keypad's enter is enter")
    }

    func testLettersDigitsAndPunctuationAreNeverSpecial() {
        for code in [0, 3, 38, 18, 29, 41, 50, 44] as [Int64] {
            XCTAssertNil(Keys.SpecialKey(keycode: code), "keycode \(code)")
            XCTAssertNil(Keys.SpecialKey(press: press(code: code)), "row for keycode \(code)")
        }
        XCTAssertNil(Keys.SpecialKey(keycode: 123), "arrows are not placed")
    }

    /// The convention the map deviates from, read from the same tables
    /// the tap reads, so the two can never disagree.
    func testTheStandardPlacementIsTheConventions() {
        XCTAssertEqual(Keys.SpecialKey.enter.standard, FingerMap.Placement(.right, .pinky))
        XCTAssertEqual(Keys.SpecialKey.backspace.standard, FingerMap.Placement(.right, .pinky))
        XCTAssertEqual(Keys.SpecialKey.tab.standard, FingerMap.Placement(.left, .pinky))
        XCTAssertEqual(Keys.SpecialKey.escape.standard, FingerMap.Placement(.left, .pinky))
        XCTAssertEqual(Keys.SpecialKey.space.standard, FingerMap.Placement(.either, .thumb),
                       "a space bar spans both hands")
        XCTAssertEqual(Keys.SpecialKey.leftCommand.standard, FingerMap.Placement(.left, .thumb))
        XCTAssertEqual(Keys.SpecialKey.rightCommand.standard, FingerMap.Placement(.right, .thumb))
        XCTAssertEqual(Keys.SpecialKey.leftShift.standard, FingerMap.Placement(.left, .pinky))
        XCTAssertEqual(Keys.SpecialKey.rightOption.standard, FingerMap.Placement(.right, .ring))
        XCTAssertEqual(Keys.SpecialKey.fn.standard, FingerMap.Placement(.left, .pinky))
        for key in Keys.SpecialKey.allCases {
            XCTAssertEqual(key.standard.finger, Keys.finger(for: key.keycode), "\(key)")
        }
    }

    // MARK: - What the map touches

    /// A split board's enter is under the right thumb: the finger moves,
    /// the hand column — the windows' class — stays exactly as it was.
    func testTheMapMovesTheFingerAndNeverTheHand() {
        let map = FingerMap(["kb": [.enter: FingerMap.Placement(.right, .thumb),
                                    .leftCommand: FingerMap.Placement(.either, .thumb),
                                    .space: FingerMap.Placement(.right, .thumb)]])
        let enter = map.apply(to: press(code: 36), keyboard: "kb")
        XCTAssertEqual(enter.finger, .thumb)
        XCTAssertEqual(enter.hand, .other, "the hand column is the windows' class and does not move")
        XCTAssertEqual(enter.kind, .enter)
        let command = map.apply(to: press(code: 55), keyboard: "kb")
        XCTAssertEqual(command.finger, .thumb)
        XCTAssertEqual(command.hand, .left, "a modifier's side stays the keycode's")
        let space = map.apply(to: press(code: 49), keyboard: "kb")
        XCTAssertEqual(space.hand, .thumb, "the space bar keeps its own class")
        XCTAssertEqual(space.finger, .thumb)
    }

    func testAKeyTheMapDoesNotNameAndABoardItHasNotHeardOfComeBackUntouched() {
        let map = FingerMap(["kb": [.enter: FingerMap.Placement(.right, .thumb)]])
        let letter = press(code: 0)
        XCTAssertEqual(map.apply(to: letter, keyboard: "kb"), letter)
        let shift = press(code: 56)
        XCTAssertEqual(map.apply(to: shift, keyboard: "kb"), shift)
        let elsewhere = press(code: 36)
        XCTAssertEqual(map.apply(to: elsewhere, keyboard: "other"), elsewhere)
        XCTAssertEqual(elsewhere.relabeled(by: map, keyboard: "other"), elsewhere)
        XCTAssertEqual(press(code: 36).relabeled(by: map, keyboard: "kb").finger, .thumb)
    }

    func testTheSideForTheLoadViewIsTheDeclarationThenTheHandColumn() {
        let map = FingerMap(["kb": [.enter: FingerMap.Placement(.right, .thumb),
                                    .leftCommand: FingerMap.Placement(.either, .thumb)]])
        XCTAssertEqual(map.side(of: press(code: 36), keyboard: "kb"), .right)
        XCTAssertEqual(map.side(of: press(code: 55), keyboard: "kb"), .either)
        XCTAssertEqual(map.side(of: press(code: 0), keyboard: "kb"), .left, "a letter's hand is its side")
        XCTAssertEqual(map.side(of: press(code: 38), keyboard: "kb"), .right)
        XCTAssertNil(map.side(of: press(code: 49), keyboard: "kb"), "the space bar has no declared side here")
        XCTAssertNil(map.side(of: press(code: 36), keyboard: "other"), "enter on an undeclared board")
    }

    func testEffectiveIsTheDeclarationOrTheStandard() {
        let map = FingerMap(["kb": [.enter: FingerMap.Placement(.right, .thumb)]])
        XCTAssertEqual(map.effective(of: .enter, keyboard: "kb"), FingerMap.Placement(.right, .thumb))
        XCTAssertEqual(map.effective(of: .tab, keyboard: "kb"), Keys.SpecialKey.tab.standard)
        XCTAssertEqual(map.differing(on: "kb"), 1)
        XCTAssertEqual(map.differing(on: "other"), 0)
        XCTAssertFalse(map.isEmpty)
        XCTAssertTrue(FingerMap().isEmpty)
        XCTAssertTrue(FingerMap(["kb": [:]]).isEmpty, "a board with nothing declared declares nothing")
    }

    /// The fingerprint joins the era's: the same declaration in any
    /// order is the same era, and nothing declared adds nothing.
    func testTheFingerprintIsOrderFreeAndEmptyWhenNothingIsDeclared() {
        XCTAssertEqual(FingerMap().fingerprint, "")
        XCTAssertEqual(FingerMap(["kb": [:]]).fingerprint, "")
        let a = FingerMap(["kb": [.enter: FingerMap.Placement(.right, .thumb),
                                  .space: FingerMap.Placement(.right, .thumb)],
                           "other": [.tab: FingerMap.Placement(.left, .ring)]])
        let b = FingerMap(["other": [.tab: FingerMap.Placement(.left, .ring)],
                           "kb": [.space: FingerMap.Placement(.right, .thumb),
                                  .enter: FingerMap.Placement(.right, .thumb)]])
        XCTAssertEqual(a.fingerprint, b.fingerprint)
        XCTAssertEqual(a.fingerprint, "kb=enter:right thumb,space:right thumb|other=tab:left ring")
        var c = a
        c.keyboards["kb"]?[.enter] = FingerMap.Placement(.left, .thumb)
        XCTAssertNotEqual(c.fingerprint, a.fingerprint)
    }

    // MARK: - The windows are not moved

    /// The doctrine test: a window fed relabeled presses puts enter in
    /// the thumb bin and reports the sides and the pairs identically.
    func testAWindowKeepsItsSidesAndPairsUnderTheMap() {
        let map = FingerMap(["kb": [.enter: FingerMap.Placement(.right, .thumb),
                                    .space: FingerMap.Placement(.right, .thumb),
                                    .leftShift: FingerMap.Placement(.left, .thumb)]])
        var presses: [KeyPress] = []
        let codes: [Int64] = [0, 38, 1, 40, 49, 36, 56, 2, 37, 49, 3, 41, 36]
        for (i, code) in codes.enumerated() {
            presses.append(press(code: code, at: Double(i) * 0.15, hold: code == 56 ? 0.3 : 0.09))
        }
        let plain = HoldWindow.stats(start: start, presses: presses)
        let mapped = HoldWindow.stats(start: start,
                                      presses: presses.map { $0.relabeled(by: map, keyboard: "kb") })
        XCTAssertEqual(mapped.left, plain.left)
        XCTAssertEqual(mapped.right, plain.right)
        XCTAssertEqual(mapped.ll, plain.ll)
        XCTAssertEqual(mapped.lr, plain.lr)
        XCTAssertEqual(mapped.rl, plain.rl)
        XCTAssertEqual(mapped.rr, plain.rr)
        XCTAssertEqual(mapped.typing, plain.typing)
        XCTAssertEqual(mapped.hold, plain.hold)
        XCTAssertEqual(mapped.modifierHold, plain.modifierHold)
        let thumb = Int(Keys.Finger.thumb.rawValue), pinky = Int(Keys.Finger.pinky.rawValue)
        XCTAssertEqual(plain.fingers?[pinky], 5, "a, two enters, a shift, a semicolon")
        XCTAssertEqual(mapped.fingers?[pinky], 2, "a, semicolon")
        XCTAssertEqual(mapped.fingers?[thumb], (plain.fingers?[thumb] ?? 0) + 3,
                       "two enters and a shift moved to the thumb")
    }

    // MARK: - The file

    private func build(_ json: String) throws -> (Config, [String]) {
        var problems: [String] = []
        let root = try Json.parse(json)
        return (Config.build(from: root, problems: &problems), problems)
    }

    func testTheFileDeclaresAKeyboardsKeysBySideAndFinger() throws {
        let (config, problems) = try build(#"""
        {"health": {"keyboards": {"7504:24926:782ec294": {
            "enter": "right thumb", "space": "right thumb", "left-command": "either thumb"}}}}
        """#)
        XCTAssertEqual(problems, [])
        let keys = config.fingerMap.keyboards["7504:24926:782ec294"]
        XCTAssertEqual(keys?[.enter], FingerMap.Placement(.right, .thumb))
        XCTAssertEqual(keys?[.space], FingerMap.Placement(.right, .thumb))
        XCTAssertEqual(keys?[.leftCommand], FingerMap.Placement(.either, .thumb))
        XCTAssertEqual(config.fingerMap.differing(on: "7504:24926:782ec294"), 3)
    }

    func testAnUnknownKeyOrAPlacementThatIsNotASideAndAFingerIsReportedNotSwallowed() throws {
        let (config, problems) = try build(#"""
        {"health": {"keyboards": {"kb": {"enter": "right thumb", "a": "left index", "tab": "thumb"}}}}
        """#)
        XCTAssertEqual(config.fingerMap.keyboards["kb"]?.count, 1, "the good line lands")
        XCTAssertTrue(problems.contains { $0.contains("health.keyboards.kb.a") && $0.contains("unknown key") },
                      "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("health.keyboards.kb.tab") && $0.contains("right thumb") },
                      "\(problems)")
    }

    func testAKeyboardThatIsNotASectionIsReported() throws {
        let (config, problems) = try build(#"{"health": {"keyboards": {"kb": "right thumb"}}}"#)
        XCTAssertTrue(config.fingerMap.isEmpty)
        XCTAssertTrue(problems.contains { $0.contains("health.keyboards.kb") }, "\(problems)")
    }

    func testTheSchemaKnowsTheSectionAndValidatesItClean() throws {
        let root = try Json.parse(#"{"health": {"keyboards": {"kb": {"enter": "right thumb"}}}}"#)
        XCTAssertEqual(ConfigSchema.validate(root, against: Config.schema), [])
    }
}
