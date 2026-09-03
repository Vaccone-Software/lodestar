import XCTest
import CoreText
import ImageIO
@testable import LodestarCore

/// The pixel sensor against images we control: text drawn with CoreText,
/// recognized by Vision, mapped into screen space. What these lock down:
/// the recognizer reads clean UI-sized text verbatim (identifiers
/// included — language correction must stay off), the geometry lands
/// where the text was drawn, and character-range rectangles are narrower
/// than their lines. Terminal-style light-on-dark is tested because
/// terminals are the tier this sensor exists to rescue.
final class OCRSenseTests: XCTestCase {
    /// Draw lines of text into a bitmap, top to bottom, and return the
    /// image plus each line's drawn y-position (top-left origin, points).
    private func render(lines: [String], width: Int = 900, height: Int = 300,
                        dark: Bool = false) -> (CGImage, [(text: String, top: CGFloat)]) {
        let scale = 2
        let context = CGContext(
            data: nil, width: width * scale, height: height * scale,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        context.setFillColor(dark
            ? CGColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)
            : CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Menlo" as CFString, 16, nil)
        let color = dark
            ? CGColor(red: 0.9, green: 0.92, blue: 0.95, alpha: 1)
            : CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        var drawn: [(String, CGFloat)] = []
        for (index, text) in lines.enumerated() {
            let top = CGFloat(30 + index * 40)
            let attributed = NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: color,
            ])
            let line = CTLineCreateWithAttributedString(attributed)
            // CG context origin is bottom-left; our bookkeeping is top-left.
            context.textPosition = CGPoint(x: 24, y: CGFloat(height) - top - 16)
            CTLineDraw(line, context)
            drawn.append((text, top))
        }
        return (context.makeImage()!, drawn)
    }

    func testCleanProseIsReadVerbatimWithHonestGeometry() {
        let windowFrame = CGRect(x: 100, y: 200, width: 900, height: 300)
        let (image, drawn) = render(lines: [
            "The quick brown fox jumps over it",
            "the second line carries plain words",
            "brew install --cask lodestar",
        ])
        let lines = OCRSense.recognize(image: image, windowFrame: windowFrame)
        XCTAssertGreaterThanOrEqual(lines.count, 3, "three drawn lines, three read")

        for (expected, top) in drawn {
            guard let line = lines.first(where: {
                OCRSense.normalized($0.text) == OCRSense.normalized(expected)
            }) else {
                return XCTFail("verbatim read failed for '\(expected)' — got \(lines.map(\.text))")
            }
            // Geometry: the line's screen rect sits at the drawn height,
            // inside the window.
            XCTAssertEqual(line.frame.minY, windowFrame.minY + top, accuracy: 14,
                           "line lands where it was drawn")
            XCTAssertTrue(windowFrame.insetBy(dx: -2, dy: -2).contains(line.frame.origin))
        }
    }

    func testGroundingRepairsTheGlyphConfusionRecognitionActuallyMakes() {
        // Reproduced live by this very suite: "7f3a9c1e" read as
        // "7f3a9cle". The grounding layer must hand back the truth when
        // accessibility read the same region.
        let truth = "deploy STAGING-7f3a9c1e now"
        let windowFrame = CGRect(x: 0, y: 0, width: 900, height: 300)
        let (image, _) = render(lines: [truth])
        guard let line = OCRSense.recognize(image: image, windowFrame: windowFrame)
            .max(by: { $0.text.count < $1.text.count }) else { return XCTFail() }
        let grounded = OCRSense.ground(line.text, in: [truth])
        XCTAssertEqual(grounded.map(OCRSense.normalized),
                       OCRSense.normalized(truth),
                       "one substituted glyph, repaired from ground truth")
    }

    func testGroundingRefusesToGuess() {
        XCTAssertNil(OCRSense.ground("completely unrelated words",
                                     in: ["deploy STAGING-7f3a9c1e now"]),
                     "no plausible alignment: keep the pixels, corrupt nothing")
        XCTAssertEqual(OCRSense.ground("STAGING-7f3a9c1e",
                                       in: ["deploy STAGING-7f3a9c1e now"]),
                       "STAGING-7f3a9c1e", "an exact hit confirms the span unchanged")
    }

    func testGroundingDeclinesWhenTwoRepairsDisagree() {
        // Two near-identical values share the window. Aligning on the
        // anchor's first occurrence alone would confidently return the
        // earlier one — the wrong one half the time. Ambiguity keeps the
        // pixels.
        XCTAssertNil(OCRSense.ground("value: 4821",
                                     in: ["value: 4826 then value: 4829"]),
                     "two passing windows that disagree is a guess")
    }

    func testIdentifiersSurviveWithoutLanguageCorrection() {
        // The copy path's whole fidelity case: an identifier must come out
        // character-for-character, not "corrected" into a word.
        let windowFrame = CGRect(x: 0, y: 0, width: 900, height: 300)
        let (image, _) = render(lines: ["token: xK9-40Ilq-2026 end"])
        let lines = OCRSense.recognize(image: image, windowFrame: windowFrame)
        let joined = OCRSense.normalized(lines.map(\.text).joined(separator: " "))
        XCTAssertTrue(joined.contains("xK9-40Ilq-2026"),
                      "identifier mangled: \(joined)")
    }

    func testTerminalStyleLightOnDarkReads() {
        let windowFrame = CGRect(x: 0, y: 0, width: 900, height: 300)
        let (image, _) = render(lines: [
            "vac@mac lodestar % swift test",
            "Executed 511 tests, with 0 failures",
        ], dark: true)
        let lines = OCRSense.recognize(image: image, windowFrame: windowFrame)
        let joined = OCRSense.normalized(lines.map(\.text).joined(separator: " "))
        XCTAssertTrue(joined.contains("swift test"), "terminal read: \(joined)")
        XCTAssertTrue(joined.contains("0 failures"))
    }

    func testFastLevelStillReadsPlainWords() {
        // The first of the two passes: present within ~100ms, replaced by
        // the accurate pass moments later. It must be good enough to
        // search against, not perfect.
        let windowFrame = CGRect(x: 0, y: 0, width: 900, height: 300)
        let (image, _) = render(lines: ["the quick brown fox jumps here"])
        let lines = OCRSense.recognize(image: image, windowFrame: windowFrame,
                                       level: .fast)
        let joined = OCRSense.normalized(lines.map(\.text).joined(separator: " "))
        XCTAssertTrue(joined.contains("quick"), "fast read: \(joined)")
    }

    func testCharacterRangeRectsAreNarrowerThanTheirLine() {
        let windowFrame = CGRect(x: 0, y: 0, width: 900, height: 300)
        let (image, _) = render(lines: ["alpha beta gamma delta epsilon zeta"])
        guard let line = OCRSense.recognize(image: image, windowFrame: windowFrame)
            .max(by: { $0.text.count < $1.text.count }) else { return XCTFail() }
        let word = (line.text as NSString).range(of: "gamma")
        guard word.location != NSNotFound else { return XCTFail("gamma unread: \(line.text)") }
        let rects = line.rects(for: word)
        XCTAssertEqual(rects.count, 1)
        XCTAssertLessThan(rects[0].width, line.frame.width * 0.4,
                          "a word's rect is a word wide, not a line wide")
        XCTAssertTrue(line.frame.insetBy(dx: -4, dy: -4).contains(rects[0].origin))
    }

    // MARK: - The copy's second readings

    func testAgreementIgnoresTheConfusablesAndNothingElse() {
        XCTAssertTrue(OCRSense.agrees("invoice 2291", "invoice 229l"), "l for 1 is the sensor's wobble")
        XCTAssertTrue(OCRSense.agrees("user_id = O0l1", "user_id = 0011"))
        XCTAssertTrue(OCRSense.agrees("the  quick   fox", "the quick fox"), "whitespace never disagrees")
        XCTAssertTrue(OCRSense.agrees("modern", "rnodern"), "rn reads as m")
        XCTAssertFalse(OCRSense.agrees("invoice 2291", "invoice 2291 due Friday"), "a longer span is a different span")
        XCTAssertFalse(OCRSense.agrees("invoice 2291", "receipt 2291"), "a different word is a disagreement")
        XCTAssertFalse(OCRSense.agrees("anything", ""), "an empty copy confirms nothing")
        XCTAssertTrue(OCRSense.agrees("a fairly long sentence about the weather", "a fairly long sentence abuot the weather"),
                      "one edit in forty characters is within the allowance")
    }

    func testNumericTokensDropTheirLoneLetters() {
        XCTAssertEqual(OCRSense.repairTokens("build 2O24 done"), "build 2024 done")
        XCTAssertEqual(OCRSense.repairTokens("port 1l0"), "port 110")
        XCTAssertEqual(OCRSense.repairTokens("v2l"), "v2l", "letters carrying a digit are an identifier")
        XCTAssertEqual(OCRSense.repairTokens("0x1f"), "0x1f", "balanced tokens are left alone")
        XCTAssertEqual(OCRSense.repairTokens("ghostty"), "ghostty")
        XCTAssertEqual(OCRSense.repairTokens("id: 4O7-2l"), "id: 407-2l",
                       "repairs land inside tokens only, and a two-glyph token is too ambiguous to touch")
    }

    func testCandidatesResolveByTokenShape() {
        XCTAssertEqual(OCRSense.resolveConfusables(["build 2O24", "build 2024"]), "build 2024")
        XCTAssertEqual(OCRSense.resolveConfusables(["hello", "he11o"]), "hello", "a word keeps its letters")
        XCTAssertEqual(OCRSense.resolveConfusables(["total: 1l0"]), "total: 110", "a lone candidate is still repaired")
        XCTAssertNil(OCRSense.resolveConfusables([]))
    }

    func testTheAppsCopyIsCutToThePixelsExtent() {
        XCTAssertEqual(OCRSense.reconcile(pixel: "SESSION_ID_4c9f1b today", app: "SESSION_ID_4c9f1b today."),
                       "SESSION_ID_4c9f1b today", "the period the drag grabbed is not part of the promise")
        XCTAssertEqual(OCRSense.reconcile(pixel: "invoice 229l", app: "(invoice 2291)"), "invoice 2291",
                       "the app's glyphs, the pixels' extent")
        XCTAssertEqual(OCRSense.reconcile(pixel: "modern", app: "rnodern"), "rnodern",
                       "rn and m align as one glyph")
        XCTAssertEqual(OCRSense.reconcile(pixel: "quokka", app: "quokka"), "quokka")
        XCTAssertNil(OCRSense.reconcile(pixel: "invoice 2291", app: "receipt 2291"), "a different word is a different span")
        XCTAssertNil(OCRSense.reconcile(pixel: "quokka", app: ""), "an empty copy confirms nothing")
        XCTAssertEqual(OCRSense.reconcile(pixel: "a fairly long line of prose here",
                                          app: "a fairly long line of prose hero"),
                       "a fairly long line of prose hero",
                       "same count, one real glyph apart: the app is the truth")
    }

    func testTheSecondReadingKeepsTheFirstReadingsShape() {
        XCTAssertEqual(OCRSense.overlay(reading: "SESSION_ID = 4c9f1b", onto: "SESSION_lD =  4c9f1b"),
                       "SESSION_ID =  4c9f1b", "glyphs move over; the pixels' own spacing stays")
        XCTAssertEqual(OCRSense.overlay(reading: "port 110\nnext", onto: "port 1l0\nnext"), "port 110\nnext")
        XCTAssertNil(OCRSense.overlay(reading: "SESSION _ID", onto: "SESSIONID"),
                     "a reading with more glyphs read something else")
        XCTAssertNil(OCRSense.overlay(reading: "short", onto: "a longer first reading"))
    }

    func testRereadingACroppedLineReadsThatLine() {
        let lines = ["first line of prose", "SESSION_ID = 4c9f1b", "third line here"]
        let (image, drawn) = render(lines: lines, width: 700, height: 200)
        let frame = CGRect(x: 100, y: 50, width: 700, height: 200)
        let second = drawn[1]
        let rect = CGRect(x: frame.minX + 10, y: frame.minY + second.top - 2, width: 400, height: 24)
        let text = OCRSense.reread(image: image, rect: rect, windowFrame: frame)
        XCTAssertEqual(text, "SESSION_ID = 4c9f1b", "the crop reads the one line under it, identifiers intact")
    }

    // MARK: - An image says what it shows

    func testAnImageSaysWhatItShows() throws {
        let (image, _) = render(lines: ["Fatal error: index out of range", "at main.swift line 42"])
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let text = try XCTUnwrap(OCRSense.readText(imageData: data as Data))
        XCTAssertTrue(text.lowercased().contains("fatal error"), text)
        XCTAssertTrue(text.contains("\n"), "two drawn lines, two read lines: \(text)")
        XCTAssertNil(OCRSense.readText(imageData: Data([1, 2, 3])),
                     "bytes that are not a picture read as nothing, and never as a crash")
        XCTAssertNil(OCRSense.readText(imageData: Data()))
    }
}
