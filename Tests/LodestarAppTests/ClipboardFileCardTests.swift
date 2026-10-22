import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// Where a card of files puts its sheets. Pure geometry: no window is made,
/// so the numbers can be held without a strip on the display.
final class ClipboardFileCardTests: XCTestCase {
    /// The body of a card the narrowest a card gets and the shortest: what
    /// `makeCard` lays out in, twelve in from each side.
    private let body = NSRect(x: 12, y: 26, width: 126, height: 86)

    func testTheSheetsStandInACascadeTheFirstInFrontAtTheLowerLeft() {
        let sheets = ClipboardStrip.cascadeSheets(count: 4, in: body)
        XCTAssertEqual(sheets.count, 4)
        XCTAssertTrue(sheets.allSatisfy { $0.size == NSSize(width: 50, height: 64) }, "50 by 64")
        XCTAssertEqual(sheets[0].origin, NSPoint(x: 16, y: 28), "the first file at the lower left")
        for index in 1..<4 {
            XCTAssertEqual(sheets[index].minX - sheets[index - 1].minX, Grid.group, "each next a group to the right")
            XCTAssertEqual(sheets[index].minY - sheets[index - 1].minY, Grid.close, "and a step higher (y is up)")
        }
    }

    func testTheSheetsKeepToWholePointsAndTheCardsBody() {
        for count in 0...Clipboard.thumbnailedFiles {
            let sheets = ClipboardStrip.cascadeSheets(count: count, in: body)
            XCTAssertEqual(sheets.count, count)
            for sheet in sheets {
                XCTAssertEqual(sheet, sheet.integral, "whole points")
                XCTAssertLessThanOrEqual(sheet.maxX, body.maxX, "inside the card's width")
                // The key stands six points above the body; the highest
                // sheet may use that room and no more.
                XCTAssertLessThanOrEqual(sheet.maxY, body.maxY + 6)
            }
        }
    }

    func testTheOneFilesSheetIsLargerAtTheLeftAndCentredInTheBody() {
        let frame = ClipboardStrip.soloSheetFrame(in: body)
        XCTAssertEqual(frame.size, NSSize(width: 64, height: 84))
        XCTAssertEqual(frame.minX, body.minX)
        XCTAssertEqual(frame.minY, body.minY + 1)
        XCTAssertEqual(frame, frame.integral)
        let tall = NSRect(x: 12, y: 26, width: 300, height: 131)
        XCTAssertEqual(ClipboardStrip.soloSheetFrame(in: tall).midY, tall.midY, accuracy: 0.5, "centred on a taller card")
        let squat = NSRect(x: 12, y: 26, width: 126, height: 40)
        XCTAssertEqual(ClipboardStrip.soloSheetFrame(in: squat).minY, squat.minY, "never below the body")
    }

    func testTheFileNameIsSetFirmOnTheTypeScale() {
        XCTAssertEqual(BarTheme.Role.name.size, BarTheme.Scale.meta, "a size the scale already has")
        XCTAssertGreaterThan(BarTheme.Role.name.weight.rawValue, BarTheme.Role.meta.weight.rawValue,
                             "and firmer than the caption")
    }
}

/// The card itself, built and looked into without being shown: a strip's
/// panel is made and never ordered front, so nothing reaches the display.
final class ClipboardFileCardLayoutTests: XCTestCase {
    private let wide = NSSize(width: 314, height: 189)
    private let narrow = NSSize(width: 152, height: 150)

    private func fact(_ name: String, kind: String = "PDF document", bytes: Int? = 3_000_000,
                      detail: String? = nil, pictured: Bool? = nil) -> Clipboard.FileFact {
        Clipboard.FileFact(name: name, folder: "Documents", kind: kind, type: "com.adobe.pdf",
                           bytes: bytes, detail: detail, pictured: pictured)
    }

    private func clip(_ facts: [Clipboard.FileFact], count: Int? = nil) -> Clipboard.Clip {
        let file = [Clipboard.fileURLType]
        return Clipboard.Clip(id: "f", kind: .file, created: Date(), sourceBundleID: "com.apple.finder",
                              sourceAppName: "Finder", preview: facts.map { "/x/\($0.name)" }.joined(separator: "\n"),
                              bytes: 10, nativeTypes: file,
                              otherItemTypes: Array(repeating: file, count: max(0, (count ?? facts.count) - 1)),
                              fileFacts: facts)
    }

    private func picture() -> NSImage {
        let image = NSImage(size: NSSize(width: 100, height: 128))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 100, height: 128).fill()
        image.unlockFocus()
        return image
    }

    private func build(_ clip: Clipboard.Clip, size: NSSize, pictures: [NSImage?]? = nil,
                       present: [Bool]? = nil) -> (strip: ClipboardStrip, card: NSView) {
        let strip = ClipboardStrip()
        let sheets = min(Clipboard.thumbnailedFiles, clip.itemCount)
        let card = strip.makeCard(clip: clip, key: "J", lit: true, size: size, face: .body, lift: .float,
                                  reading: nil, thumbnail: nil,
                                  files: .init(pictures: pictures ?? Array(repeating: nil, count: sheets), present: present),
                                  raised: false)
        return (strip, card)
    }

    /// What the card shows of its files is one view; the sheets and the
    /// names are in it. Everything else on the card is its own.
    private func content(of card: NSView) -> NSView? {
        card.subviews.first { !($0 is ObjectSurface) && !($0 is NSTextField) && !($0 is KeyFace) && $0.subviews.contains { $0 is ObjectSurface } }
    }
    private func sheets(in card: NSView) -> [NSView] { content(of: card)?.subviews.filter { $0 is ObjectSurface } ?? [] }
    private func texts(in card: NSView) -> [NSTextField] {
        (content(of: card)?.subviews ?? []).compactMap { $0 as? NSTextField } + card.subviews.compactMap { $0 as? NSTextField }
    }
    private func labels(in card: NSView) -> [String] { texts(in: card).map(\.stringValue) }

    func testSeveralFilesStandAsACascadeWithTheirNamesBeside() {
        let made = clip([fact("Report.pdf"), fact("Beach.jpg"), fact("Demo.mov")])
        let (strip, card) = build(made, size: wide)
        XCTAssertEqual(strip.shownFiles[made.id], ["Report.pdf", "Beach.jpg", "Demo.mov"], "all three, no more line")
        XCTAssertEqual(strip.shownSheets[made.id], 3)
        let stood = sheets(in: card)
        XCTAssertEqual(stood.count, 3)
        // The first file is the last drawn: in front of the others.
        XCTAssertEqual(stood.last?.frame.size, NSSize(width: 50, height: 64))
        XCTAssertEqual(stood.map(\.frame.minX), stood.map(\.frame.minX).sorted(by: >), "later files stand further right, behind")
        XCTAssertTrue(labels(in: card).contains("3 files"), "the count stays beside the key")
        XCTAssertEqual(strip.shownCaptions[made.id], "9 MB · just now")
        XCTAssertEqual(strip.shownCards[made.id], card)
    }

    func testMoreThanThreeFilesListTwoAndHowManyMoreAndStandFourSheets() {
        let names = ["Report.pdf", "Beach.jpg", "Demo.mov", "Notes.txt", "Data.zip", "A.txt", "B.txt"]
        let made = clip(names.map { fact($0) })
        let (strip, card) = build(made, size: wide)
        XCTAssertEqual(strip.shownFiles[made.id], ["Report.pdf", "Beach.jpg", "and 5 more"])
        XCTAssertEqual(strip.shownSheets[made.id], 4, "a stack of four at most")
        XCTAssertEqual(sheets(in: card).count, 4)
        let more = texts(in: card).first { $0.stringValue == "and 5 more" }
        XCTAssertEqual(more?.textColor, BarTheme.secondaryColor, "the count is grey")
        XCTAssertEqual(texts(in: card).first { $0.stringValue == "Report.pdf" }?.textColor,
                       BarTheme.ink, "and the names are the ink")
    }

    func testOneFileStandsLargeWithItsNameFolderAndDetail() {
        let made = clip([fact("Annual report 2026.pdf", detail: "12 pages")])
        let (strip, card) = build(made, size: wide)
        XCTAssertEqual(strip.shownFiles[made.id], ["Annual report 2026.pdf", "Documents", "12 pages"])
        XCTAssertEqual(sheets(in: card).first?.frame.size, NSSize(width: 64, height: 84))
        XCTAssertFalse(labels(in: card).contains { $0.hasSuffix(" files") }, "one file has no count")
        let title = texts(in: card).first { $0.stringValue == "Annual report 2026.pdf" }
        XCTAssertEqual(title?.typeStyle?.role, .name)
        XCTAssertEqual(title?.maximumNumberOfLines, 2, "the name takes two lines at most")
        XCTAssertEqual(strip.shownCaptions[made.id], "PDF document · 3 MB · just now")
    }

    func testOneFileWithNoDetailDrawsNoLineForIt() {
        let (strip, _) = build(clip([fact("a.pdf")]), size: wide)
        XCTAssertEqual(strip.shownFiles["f"], ["a.pdf", "Documents"])
    }

    func testTheKindGivesWayFirstWhenTheFootDoesNotFit() {
        let made = clip([fact("Annual report 2026.pdf", kind: "Word document", bytes: 123_000_000)])
        let (strip, _) = build(made, size: narrow)
        XCTAssertEqual(strip.shownCaptions[made.id], "123 MB · just now")
        XCTAssertNil(strip.shownSources[made.id], "and where even that leaves the source no room it is not drawn as an ellipsis")
        let (roomy, _) = build(made, size: wide)
        XCTAssertEqual(roomy.shownCaptions[made.id], "Word document · 123 MB · just now")
        XCTAssertEqual(roomy.shownSources[made.id], "Finder")
    }

    /// Seen on the display 2026-10-19: a card a little wider than the
    /// narrowest drew "Reven…" and "and 5…" beside its stack. A name cut to
    /// its first letters names nothing, so a card shows names only where a
    /// name can stand.
    func testACardWithRoomOnlyForTheFirstLettersOfNamesShowsNone() {
        let made = clip([fact("Revenue chart.png"), fact("Beach.jpeg"), fact("Q3 report.pdf"), fact("Notes.txt")])
        let (strip, card) = build(made, size: NSSize(width: 190, height: 150))
        XCTAssertEqual(strip.shownFiles[made.id], [])
        XCTAssertTrue(labels(in: card).contains("4 files"), "the count still says it")
    }

    func testTheMoreLineIsNeverCutAndBecomesTheNumberWhereItDoesNotFit() {
        let names = (1...130).map { "File \($0).pdf" }
        let made = clip(names.map { fact($0) })
        let (strip, _) = build(made, size: NSSize(width: 218, height: 150))
        XCTAssertEqual(strip.shownFiles[made.id]?.last, "+128", "no room for \"and 128 more\" whole")
        let (roomy, _) = build(made, size: wide)
        XCTAssertEqual(roomy.shownFiles[made.id]?.last, "and 128 more")
    }

    /// Seen on the display: "Find…" in the foot. The source is whole or absent.
    func testTheSourceOfACardOfFilesIsWholeOrNotThere() {
        let made = clip([fact("a.pdf"), fact("b.pdf")])
        for width in stride(from: 150, through: 260, by: 2) {
            let (strip, card) = build(made, size: NSSize(width: CGFloat(width), height: 150))
            guard strip.shownSources[made.id] != nil else { continue }
            let source = card.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Finder" }
            XCTAssertNotNil(source)
            if let source {
                XCTAssertGreaterThanOrEqual(source.frame.width, source.fittingSize.width - 0.5,
                                            "cut short at a card \(width) points wide")
            }
        }
    }

    func testACardTooNarrowForNamesKeepsTheStackAlone() {
        let made = clip([fact("a.pdf"), fact("b.pdf"), fact("c.pdf"), fact("d.pdf")])
        let (strip, card) = build(made, size: narrow)
        XCTAssertEqual(strip.shownFiles[made.id], [], "no names where there is no room for them")
        XCTAssertEqual(sheets(in: card).count, 4)
        XCTAssertTrue(labels(in: card).contains("4 files"))
    }

    func testACardWhoseFilesAreAllMissingIsDimmedAndSaysSo() {
        let made = clip([fact("gone.pdf"), fact("gone too.pdf")])
        let (strip, card) = build(made, size: wide, present: [false, false])
        XCTAssertTrue(strip.shownDimmed.contains(made.id))
        XCTAssertEqual(strip.shownCaptions[made.id], "Missing", "in place of its size and age")
        XCTAssertEqual(content(of: card)?.alphaValue, 0.45, "its files are dimmed as one picture, the sheets not one by one")
        XCTAssertTrue(sheets(in: card).allSatisfy { $0.alphaValue == 1 })
        // A group with one file still there is drawn as it is.
        let (partial, partialCard) = build(made, size: wide, present: [false, true])
        XCTAssertFalse(partial.shownDimmed.contains(made.id))
        XCTAssertEqual(partial.shownCaptions[made.id], "6 MB · just now")
        XCTAssertEqual(content(of: partialCard)?.alphaValue, 1)
        // And one not yet asked about is not missing.
        let (unknown, _) = build(made, size: wide, present: nil)
        XCTAssertFalse(unknown.shownDimmed.contains(made.id))
    }

    func testAFileCardBeforeItsFilesAreReadHasItsNamesFromItsPaths() {
        var made = clip([fact("Report.pdf")])
        made.fileFacts = nil
        let (strip, card) = build(made, size: wide)
        XCTAssertEqual(strip.shownFiles[made.id], ["Report.pdf"])
        XCTAssertEqual(strip.shownCaptions[made.id], "just now", "age alone until the size is known")
        XCTAssertEqual(sheets(in: card).count, 1)
    }

    func testAFilesOwnPictureFillsItsSheetAndAnIconStandsWhole() throws {
        let made = clip([fact("a.pdf", pictured: true), fact("b.pdf", pictured: false)])
        let (_, card) = build(made, size: wide, pictures: [picture(), picture()])
        let stood = sheets(in: card)
        func gravity(_ sheet: NSView) -> CALayerContentsGravity? {
            sheet.subviews.first?.layer?.sublayers?.first?.contentsGravity
        }
        XCTAssertEqual(gravity(try XCTUnwrap(stood.last)), .resizeAspectFill, "the first file, its own face, cropped to the sheet")
        XCTAssertEqual(gravity(try XCTUnwrap(stood.first)), .resizeAspect, "the second, an icon, whole")
    }

    func testASheetWithNoPictureYetShowsAnIconAndAnImageCardIsUntouched() throws {
        let made = clip([fact("a.pdf")])
        let (_, card) = build(made, size: wide)
        let sheet = try XCTUnwrap(sheets(in: card).first)
        XCTAssertNotNil(sheet.subviews.first?.layer?.sublayers?.first?.contents, "the type's icon stands in")
        let text = Clipboard.Clip(id: "t", kind: .text, created: Date(), sourceBundleID: nil, sourceAppName: nil,
                                  preview: "hello", bytes: 5)
        let strip = ClipboardStrip()
        let plain = strip.makeCard(clip: text, key: "K", lit: false, size: wide, face: .body, lift: .rest,
                                   reading: nil, thumbnail: nil, raised: false)
        XCTAssertTrue(sheets(in: plain).isEmpty, "a text card draws no sheets")
        XCTAssertNil(strip.shownFiles["t"])
    }
}
