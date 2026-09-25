import XCTest
@testable import LodestarCore

/// A clip that is only a color is shown as the color; anything that only
/// looks like one is left as text.
final class ClipColorTests: XCTestCase {
    private func hex(_ text: String) -> String? { ClipColor.parse(text)?.hex }

    func testHexInEveryShape() {
        XCTAssertEqual(hex("#FF4F00"), "#FF4F00")
        XCTAssertEqual(hex("#ff4f00"), "#FF4F00")
        XCTAssertEqual(hex("#f40"), "#FF4400")
        XCTAssertEqual(hex("#ff4f0080"), "#FF4F0080")
        XCTAssertEqual(hex("#f408"), "#FF440088")
        XCTAssertEqual(hex("  #000000;\n"), "#000000", "whitespace and a trailing semicolon")
        XCTAssertEqual(hex("0xFF4F00"), "#FF4F00")
    }

    func testBareHexAsDesignToolsCopyIt() {
        XCTAssertEqual(hex("FF4F00"), "#FF4F00", "Figma copies without the #")
        XCTAssertEqual(hex("FFFFFF"), "#FFFFFF", "capitals: a color, not a word")
        XCTAssertEqual(hex("ff4f00"), "#FF4F00", "a digit in it")
    }

    func testThingsThatOnlyLookLikeColors() {
        XCTAssertNil(ClipColor.parse("123456"), "a number")
        XCTAssertNil(ClipColor.parse("facade"), "a word")
        XCTAssertNil(ClipColor.parse("decade"))
        XCTAssertNil(ClipColor.parse("a1b2c3d4"), "eight bare characters: a hash")
        XCTAssertNil(ClipColor.parse("#123"), "an issue number")
        XCTAssertNil(ClipColor.parse("#1234"), "an issue number")
        XCTAssertNil(ClipColor.parse("the color is #ff4f00"), "a sentence with a color in it")
        XCTAssertNil(ClipColor.parse("#ff4f00\n#000000"), "two lines")
        XCTAssertNil(ClipColor.parse("#gg0000"))
        XCTAssertNil(ClipColor.parse("rgb(1, 2)"))
    }

    func testCSSFunctions() {
        XCTAssertEqual(hex("rgb(255, 79, 0)"), "#FF4F00")
        XCTAssertEqual(hex("rgba(255, 79, 0, 0.5)"), "#FF4F0080")
        XCTAssertEqual(hex("rgb(255 79 0 / 50%)"), "#FF4F0080")
        XCTAssertEqual(hex("rgb(100% 0% 0%)"), "#FF0000")
        XCTAssertEqual(hex("hsl(0, 100%, 50%)"), "#FF0000")
        XCTAssertEqual(hex("hsl(120deg 100% 25%)"), "#008000")
        XCTAssertEqual(hex("hsla(240, 100%, 50%, 0.25)"), "#0000FF40")
    }

    func testLuminanceChoosesReadableText() {
        XCTAssertGreaterThan(ClipColor.parse("#FFFFFF")!.luminance, 0.9)
        XCTAssertLessThan(ClipColor.parse("#000000")!.luminance, 0.01)
    }

    func testOnlyTextClipsAreColors() {
        let text = Clipboard.Clip(id: "a", kind: .text, created: Date(), sourceBundleID: nil, sourceAppName: nil,
                                  preview: "#FF4F00", bytes: 7)
        XCTAssertEqual(text.color?.hex, "#FF4F00")
    }
}
