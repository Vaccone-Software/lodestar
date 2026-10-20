import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import lodestar

/// One file opened large in the image door, as arithmetic and as views that
/// are never put on a screen: which view a file gets, which keys are drawn
/// for it, how a PDF's view is set up, and how its keys move it. The door's
/// own panel is never shown here.
final class FileDoorTests: XCTestCase {
    // MARK: - What a file is shown as

    func testAFileIsShownByWhatItIs() {
        XCTAssertEqual(ImageDoor.Content.of(.pdf), .pdf)
        for type in [UTType.png, .jpeg, .heic, .gif, .svg] {
            XCTAssertEqual(ImageDoor.Content.of(type), .image, type.identifier)
        }
        for type in [UTType.movie, .mpeg4Movie, .mp3, .plainText, .folder, .zip, .rtf,
                     UTType(filenameExtension: "docx"), UTType(filenameExtension: "xlsx")] {
            XCTAssertEqual(ImageDoor.Content.of(type), .preview, type?.identifier ?? "")
        }
        XCTAssertEqual(ImageDoor.Content.of(nil), .preview, "a type nobody could read is the system's to show")
    }

    func testTheRecordKeepsTheKindAsAWord() {
        XCTAssertEqual([ImageDoor.Content.image, .pdf, .preview].map(\.logName), ["image", "pdf", "preview"])
    }

    // MARK: - The keys under it

    private func keys(_ content: ImageDoor.Content, saves: Bool) -> [[String]] {
        ImageDoor.footer(content, saves: saves).map(\.keys)
    }

    func testOnlyAKeptPictureOffersToSave() {
        let move = ["H", "J", "K", "L"]
        XCTAssertEqual(keys(.image, saves: true), [move, ["⇧"], ["+", "−"], ["S"], ["esc"]],
                       "the picture's keys are what they were")
        XCTAssertEqual(keys(.image, saves: false), [move, ["⇧"], ["+", "−"], ["esc"]], "an image file has no save")
        XCTAssertEqual(keys(.pdf, saves: false), [move, ["⇧"], ["+", "−"], ["esc"]])
        XCTAssertEqual(keys(.preview, saves: false), [["esc"]], "a preview answers to none of ours")
    }

    // MARK: - An image file

    func testTheSizeIsTheWayUpItIsShown() {
        let upright: [CFString: Any] = [kCGImagePropertyPixelWidth: 4000, kCGImagePropertyPixelHeight: 3000]
        XCTAssertEqual(ImageDoor.pixelSize(of: upright), CGSize(width: 4000, height: 3000))
        for turn in 1...4 {
            XCTAssertEqual(ImageDoor.pixelSize(of: upright.merging([kCGImagePropertyOrientation: turn]) { $1 }),
                           CGSize(width: 4000, height: 3000), "orientation \(turn)")
        }
        for turn in 5...8 {
            XCTAssertEqual(ImageDoor.pixelSize(of: upright.merging([kCGImagePropertyOrientation: turn]) { $1 }),
                           CGSize(width: 3000, height: 4000), "orientation \(turn) lies on its side")
        }
        XCTAssertNil(ImageDoor.pixelSize(of: [:]))
        XCTAssertNil(ImageDoor.pixelSize(of: [kCGImagePropertyPixelWidth: 0, kCGImagePropertyPixelHeight: 5]))
    }

    private func scratch() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-filedoor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// A solid JPEG of the given pixels, stored with the given orientation.
    private func jpeg(at url: URL, width: Int, height: Int, orientation: Int) throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testAnImageFileIsReadFromTheDiskWithItsSizeAsShown() throws {
        let folder = try scratch()
        let flat = folder.appendingPathComponent("flat.jpg")
        try jpeg(at: flat, width: 40, height: 20, orientation: 1)
        let loaded = try XCTUnwrap(ImageDoor.loadImage(at: flat))
        XCTAssertEqual(loaded.pixels, CGSize(width: 40, height: 20))

        let turned = folder.appendingPathComponent("turned.jpg")
        try jpeg(at: turned, width: 40, height: 20, orientation: 6)
        XCTAssertEqual(ImageDoor.loadImage(at: turned)?.pixels, CGSize(width: 20, height: 40))

        let notAnImage = folder.appendingPathComponent("note.txt")
        try "not a picture".write(to: notAnImage, atomically: true, encoding: .utf8)
        XCTAssertNil(ImageDoor.loadImage(at: notAnImage), "so the door previews it instead")
        XCTAssertNil(ImageDoor.loadImage(at: folder.appendingPathComponent("missing.png")))
    }

    // MARK: - A PDF

    func testAPDFStandsAsPagesOnTheGlassFittedToTheWidth() throws {
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        ImageDoor.configure(view, showing: try pdf(pages: 2))
        XCTAssertEqual(view.displayMode, .singlePageContinuous, "pages one above another, scrolling")
        XCTAssertEqual(view.displayDirection, .vertical)
        XCTAssertTrue(view.displaysPageBreaks, "a little space between pages")
        let margin = ImageDoor.pageMargin
        XCTAssertEqual(view.pageBreakMargins.top, margin)
        XCTAssertEqual(view.pageBreakMargins.bottom, margin)
        XCTAssertEqual(view.pageBreakMargins.left, margin)
        XCTAssertEqual(view.pageBreakMargins.right, margin)
        XCTAssertTrue(view.autoScales, "fitted to the room's width")
        XCTAssertEqual(view.backgroundColor, .clear, "the glass shows between the pages")
        XCTAssertFalse(view.pageShadowsEnabled, "the system's shadows are not the door's")
        XCTAssertFalse(view.acceptsDraggedFiles)
        XCTAssertEqual(view.minScaleFactor, ImageDoor.pdfScales.lowerBound)
        XCTAssertEqual(view.maxScaleFactor, ImageDoor.pdfScales.upperBound)
    }

    /// A PDF of `pages` pages of letter size, made in memory.
    private func pdf(pages: Int) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 100, y: 100, width: 200, height: 200))
            context.endPDFPage()
        }
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    /// A configured view with a document in it, laid out without a window.
    private func laidOut(pages: Int = 6) throws -> PDFView {
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 612, height: 600))
        ImageDoor.configure(view, showing: try pdf(pages: pages))
        view.layoutDocumentView()
        return view
    }

    func testPlusAndMinusZoomAPDFByTheDoorsStepAndStayWithinItsLimits() throws {
        let view = try laidOut()
        let fit = view.scaleFactor
        XCTAssertGreaterThan(fit, 0)
        ImageDoor.zoom(view, in: true)
        XCTAssertEqual(view.scaleFactor, fit * ImageDoor.zoomStep, accuracy: 0.001)
        XCTAssertFalse(view.autoScales, "a chosen scale is kept")
        ImageDoor.zoom(view, in: false)
        XCTAssertEqual(view.scaleFactor, fit, accuracy: 0.001)
        for _ in 0..<60 { ImageDoor.zoom(view, in: true) }
        XCTAssertEqual(view.scaleFactor, ImageDoor.pdfScales.upperBound, accuracy: 0.001)
        for _ in 0..<120 { ImageDoor.zoom(view, in: false) }
        XCTAssertEqual(view.scaleFactor, ImageDoor.pdfScales.lowerBound, accuracy: 0.001)
    }

    func testJAndKScrollAPDFByAStrideAndShiftMultipliesIt() throws {
        let view = try laidOut()
        let scroller = try XCTUnwrap(view.documentView?.enclosingScrollView, "the pages scroll in a scroll view")
        let clipView = scroller.contentView
        // The pages are laid out at their own scale inside the clip view, so
        // its units are not points; a stride is counted in points all the same.
        let perPoint = clipView.bounds.width / clipView.frame.width
        XCTAssertNotEqual(perPoint, 1, accuracy: 0.001, "the fit puts the pages at a scale of their own")
        let top = clipView.bounds.origin
        ImageDoor.slide(scroller, "j", fast: false)
        let one = clipView.bounds.origin
        XCTAssertEqual(abs(one.y - top.y), ImageDoor.moveStep * perPoint, accuracy: 0.5, "one stride")
        ImageDoor.slide(scroller, "k", fast: false)
        XCTAssertEqual(clipView.bounds.origin.y, top.y, accuracy: 0.5, "and k takes it back")
        ImageDoor.slide(scroller, "j", fast: true)
        XCTAssertEqual(abs(clipView.bounds.origin.y - top.y),
                       ImageDoor.moveStep * ImageDoor.fastMultiplier * perPoint,
                       accuracy: 0.5, "shift is faster by scroll mode's factor")
    }

    func testJReadsOnDownTheDocumentAndKBackUpIt() throws {
        let view = try laidOut(pages: 6)
        let scroller = try XCTUnwrap(view.documentView?.enclosingScrollView)
        let document = try XCTUnwrap(scroller.documentView)
        let clipView = scroller.contentView
        // How far the visible part has gone from the document's top edge,
        // whichever way the document counts its rows.
        func fromTop() -> CGFloat {
            document.isFlipped ? clipView.bounds.minY - document.frame.minY
                               : document.frame.maxY - clipView.bounds.maxY
        }
        let start = fromTop()
        ImageDoor.slide(scroller, "j", fast: false)
        XCTAssertGreaterThan(fromTop(), start, "j brings what is below into view")
        ImageDoor.slide(scroller, "k", fast: false)
        XCTAssertEqual(fromTop(), start, accuracy: 0.5, "and k takes it back")
        ImageDoor.slide(scroller, "k", fast: false)
        XCTAssertEqual(fromTop(), start, accuracy: 0.5, "past the top there is nothing")
    }

    func testHAndLMoveAPDFOnlyWhenItIsWiderThanTheRoom() throws {
        let view = try laidOut()
        let scroller = try XCTUnwrap(view.documentView?.enclosingScrollView)
        let clipView = scroller.contentView
        let fitted = clipView.bounds.origin.x
        ImageDoor.slide(scroller, "l", fast: false)
        XCTAssertEqual(clipView.bounds.origin.x, fitted, accuracy: 0.5, "fitted to the width, nowhere to go")
        for _ in 0..<4 { ImageDoor.zoom(view, in: true) }
        view.layoutDocumentView()
        let zoomed = clipView.bounds.origin.x
        ImageDoor.slide(scroller, "l", fast: false)
        XCTAssertGreaterThan(clipView.bounds.origin.x, zoomed, "zoomed in, l brings what is to the right")
        ImageDoor.slide(scroller, "h", fast: false)
        XCTAssertEqual(clipView.bounds.origin.x, zoomed, accuracy: 0.5)
    }

    // MARK: - Which way a key slides

    func testAKeyMovesWhatIsShownTheWayScrollModeDoes() {
        let origin = NSPoint(x: 100, y: 100)
        XCTAssertEqual(ImageDoor.slid(origin, "l", stride: 10, flipped: false), NSPoint(x: 110, y: 100))
        XCTAssertEqual(ImageDoor.slid(origin, "h", stride: 10, flipped: false), NSPoint(x: 90, y: 100))
        // A picture counts upward, so below is a smaller y; pages count down.
        XCTAssertEqual(ImageDoor.slid(origin, "j", stride: 10, flipped: false), NSPoint(x: 100, y: 90))
        XCTAssertEqual(ImageDoor.slid(origin, "k", stride: 10, flipped: false), NSPoint(x: 100, y: 110))
        XCTAssertEqual(ImageDoor.slid(origin, "j", stride: 10, flipped: true), NSPoint(x: 100, y: 110))
        XCTAssertEqual(ImageDoor.slid(origin, "k", stride: 10, flipped: true), NSPoint(x: 100, y: 90))
        XCTAssertNil(ImageDoor.slid(origin, "x", stride: 10, flipped: true))
    }

    func testAPreviewIsScrolledOnlyWhenItHasAScrollViewToScroll() {
        let plain = NSView()
        plain.addSubview(NSView())
        XCTAssertNil(ImageDoor.firstScroller(in: plain), "most previews are drawn in another process")
        let scroller = NSScrollView()
        let nested = NSView()
        nested.addSubview(NSView())
        nested.subviews[0].addSubview(scroller)
        XCTAssertTrue(ImageDoor.firstScroller(in: nested) === scroller)
        ImageDoor.slide(nil, "j", fast: false) // nothing to scroll is nothing done
    }
}
