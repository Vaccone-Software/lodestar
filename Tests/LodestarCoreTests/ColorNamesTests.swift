import XCTest
@testable import LodestarCore

/// A color is called what people call it: the nearest name in the survey,
/// never a name of the wrong hue, and a grey only ever by a grey.
final class ColorNamesTests: XCTestCase {
    private func name(_ hex: String) -> String { ClipColor.parse(hex)!.name }

    func testTheNamesPeopleGiveThem() {
        XCTAssertEqual(name("#FF4F00"), "International Orange", "the accent Settings already calls so")
        XCTAssertEqual(name("#FF0000"), "Fire Engine Red")
        XCTAssertEqual(name("#34C759"), "Shamrock Green")
        XCTAssertEqual(name("#FF9500"), "Tangerine")
        XCTAssertEqual(name("#002FA7"), "Klein Blue")
        XCTAssertEqual(name("#FFFFFF"), "White")
        XCTAssertEqual(name("#000000"), "Black")
        XCTAssertEqual(name("#808080"), "Medium Grey")
    }

    func testAGreyIsNamedByAGrey() {
        for level in stride(from: 0, through: 255, by: 15) {
            let color = ClipColor(red: Double(level) / 255, green: Double(level) / 255, blue: Double(level) / 255)
            XCTAssertNotNil(color.name.range(of: #"Grey|Black|White|Silver|Charcoal"#, options: .regularExpression),
                            "\(color.hex) is \(color.name)")
        }
        XCTAssertEqual(name("#1E1E1E"), "Almost Black", "not Dark Brown, which the nearest name alone said")
    }

    func testAColorIsNeverNamedAcrossItsHue() {
        XCTAssertFalse(name("#002222").contains("Brown"), "a dark teal is not brown: \(name("#002222"))")
        XCTAssertFalse(name("#3478F6").contains("Grey"), "a blue is not a grey")
    }

    func testTheCurationHolds() {
        XCTAssertEqual(ColorNames.entries.count, 812, "every line of the table parses")
        for entry in ColorNames.entries {
            XCTAssertNil(entry.name.range(of: #"(?i)puke|poo|vomit|snot|booger|ugly|nasty|kermit|barbie|barney|tiffany"#,
                                           options: .regularExpression), entry.name)
        }
    }
}
