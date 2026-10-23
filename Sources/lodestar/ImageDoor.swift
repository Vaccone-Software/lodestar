import AppKit
import ImageIO
import LodestarCore
import PDFKit
import Quartz
import UniformTypeIdentifiers

/// An image card, open across the display.
///
/// The text card's door is the draft; an image has no text to edit, so
/// its door is the image itself, on the launcher's glass across the whole
/// visible display with the strip gone beneath it. It opens fitted, so
/// the whole picture is seen first, and from there the trackpad does what
/// it does to any image: a pinch zooms about the pointer, two fingers
/// pan, and the picture never leaves its frame. No slider, no buttons.
///
/// It is the one surface in Lodestar that takes focus. macOS sends a
/// pinch to the active application and nowhere else — not to the window
/// under the pointer, not to a monitor watching from outside — so a door
/// that stays behind another app zooms for nobody. The strip and the
/// draft never activate because what they do lands in the app behind
/// them; the door's result lands nowhere but the picture, so activating
/// costs the hand nothing, and the app it took focus from gets it back
/// the moment the door closes. The strip's grammar keeps every key:
/// `esc` and `⏎` step back, `S` goes on to the save band.
///
/// One file opens in the same door, large, by what it is: an image file
/// the same way a kept picture does, a PDF as its pages stacked one above
/// another and scrolling, anything else as the system previews it (a
/// film plays, a document reads). A file is not the clipboard's to save,
/// so `S` is not among its keys.
final class ImageDoor {
    /// What the door holds, which decides the view in its room and the keys
    /// under it.
    enum Content: Equatable {
        case image, pdf, preview

        /// What a file of this type is shown as. A type nobody could read
        /// (nil) is previewed: the system knows more kinds than we do.
        static func of(_ type: UTType?) -> Content {
            guard let type else { return .preview }
            if type.conforms(to: .pdf) { return .pdf }
            if type.conforms(to: .image) { return .image }
            return .preview
        }

        /// The word the record keeps, never a name or a path.
        var logName: String {
            switch self {
            case .image: return "image"
            case .pdf: return "pdf"
            case .preview: return "preview"
            }
        }
    }

    let panel: KeyablePanel
    /// The app that was in front when the door opened, to be put back.
    private(set) var returnsFocusTo: NSRunningApplication?
    private let root = NSView()
    private var backdrop: NSView?
    private let scroll = NSScrollView()
    private let clip = CenteringClipView()
    private let imageView = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    /// The door's keys, drawn as keys: the one keycap, never letters typed
    /// into a sentence. Drawn again for each thing shown, since what the
    /// keys do depends on it.
    private var keys = NSView()
    /// A PDF's pages, or a file's preview, standing where the picture's
    /// scroll view stands. Made for each opening and closed with the door.
    private var pdfView: PDFView?
    private var previewView: QLPreviewView?
    /// The gesture watchers, live only while the door stands.
    private var monitors: [Any] = []
    /// The magnification the picture opened at: what a smart zoom (two
    /// fingers, tapped twice) returns to.
    private var fitted: CGFloat = 1

    private static let margin = Grid.section
    private static let pad = Grid.section
    private static let footerHeight = Grid.margin
    /// How far a pinch may go past one point per pixel; past this the
    /// picture is blocks, and blocks are not what anyone zoomed in for.
    private static let maxMagnification: CGFloat = 8
    /// One press of `h` `j` `k` `l`, in points of the screen; shift
    /// multiplies it by scroll mode's own factor, so a held shift moves
    /// the picture the way it moves a page.
    static let moveStep: CGFloat = 80
    static let fastMultiplier: CGFloat = 3
    /// One press of `+` or `-`.
    static let zoomStep: CGFloat = 1.25
    /// The space left around each page of a PDF, so the pages stand one
    /// above another with a little glass between them.
    static let pageMargin = Grid.group
    /// The share of the room's height a page opens at, leaving glass above and below.
    static let pageFill: CGFloat = 0.94
    /// How far a PDF may be zoomed, as a scale of its pages' own size.
    static let pdfScales: ClosedRange<CGFloat> = 0.1...maxMagnification

    var isVisible: Bool { panel.isVisible }
    /// What the screen shows, for the tests: the image as first drawn, in
    /// points, the magnification that drew it, and the line under it.
    private(set) var shownImageSize: NSSize?
    private(set) var shownMagnification: CGFloat?
    private(set) var shownCaption: String?
    private(set) var shownContent: Content?
    /// The current magnification, for the tests and the record.
    var magnification: CGFloat { scroll.magnification }

    init() {
        // The launcher's key panel, at the strip's level: titled and
        // hidden so the window server rounds it, able to become key so
        // the gestures of an active app land in it.
        panel = KeyablePanel(contentRect: BarTheme.unplaced,
                             styleMask: [], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        // Every key the grammar did not take arrives here; none has a
        // meaning, and a key window that beeps at each is not quiet.
        panel.onKeyDown = { _ in true }
        // The door floats on its drawn shadow, and takes the pointer only
        // over its glass.
        SoftShadow.host(root, in: panel, cornerRadius: BarTheme.surfaceRadius)
        backdrop = Ceramic.installPane(in: root, cornerRadius: BarTheme.surfaceRadius)

        scroll.contentView = clip
        scroll.documentView = imageView
        scroll.allowsMagnification = true
        scroll.maxMagnification = Self.maxMagnification
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.usesPredominantAxisScrolling = false
        clip.drawsBackground = false

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter

        caption.setRole(.meta, tabular: true)
        caption.textColor = BarTheme.secondaryColor
        caption.lineBreakMode = .byTruncatingTail
        root.addSubview(scroll)
        root.addSubview(caption)
    }

    /// The size the picture opens at: the largest that fits the room
    /// without inventing pixels — one point per pixel is the ceiling, so
    /// a small screenshot stands at its full sharpness and a huge one is
    /// fitted, whole, and zoomed from there.
    static func fit(pixels: CGSize, within room: CGSize) -> CGSize {
        guard pixels.width > 0, pixels.height > 0, room.width > 0, room.height > 0 else {
            return .zero
        }
        let scale = min(1, room.width / pixels.width, room.height / pixels.height)
        return CGSize(width: (pixels.width * scale).rounded(.down),
                      height: (pixels.height * scale).rounded(.down))
    }

    /// The keys that apply to what the door holds. A kept picture can be
    /// saved; a file cannot, it is one already. A preview answers to no
    /// key of ours, so it names only the way back.
    static func footer(_ content: Content, saves: Bool) -> [Keycaps.Gesture] {
        let back = Keycaps.Gesture(["esc"], "back")
        if content == .preview { return [back] }
        let moving: [Keycaps.Gesture] = [
            .init(["H", "J", "K", "L"], "move"), .init(["⇧"], "faster"), .init(["+", "−"], "zoom"),
        ]
        return moving + (saves ? [.init(["S"], "save")] : []) + [back]
    }

    /// A picture's size in pixels the way it is shown, from what ImageIO
    /// reads of its header: orientations 5 to 8 lie on their side, and the
    /// picture is the way up it is shown, not the way it is stored.
    static func pixelSize(of properties: [CFString: Any]) -> CGSize? {
        guard var width = properties[kCGImagePropertyPixelWidth] as? Int,
              var height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        if let turn = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(turn) {
            swap(&width, &height)
        }
        return CGSize(width: width, height: height)
    }

    /// An image file and its size in pixels, or nil when it cannot be read
    /// as one.
    static func loadImage(at url: URL) -> (image: NSImage, pixels: CGSize)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let pixels = pixelSize(of: properties),
              let image = NSImage(contentsOf: url) else { return nil }
        return (image, pixels)
    }

    /// The picture across the display. `saves` is false for an image file,
    /// which has its own place on disk and no business being written to
    /// another.
    func show(image: NSImage, pixels: CGSize, caption text: String, saves: Bool = true) {
        present(.image, saves: saves, caption: text) { room in
            let size = Self.fit(pixels: pixels, within: room)
            let fit = pixels.width > 0 ? size.width / pixels.width : 1
            shownImageSize = size
            shownMagnification = fit

            scroll.isHidden = false
            scroll.frame = NSRect(x: Self.pad, y: Self.footerHeight + Self.pad,
                                  width: room.width, height: room.height)
            // The document is the picture at one point per pixel; the
            // magnification is what the eye sees. Fitted first, and never so
            // far out that the picture is a stamp.
            imageView.image = image
            imageView.frame = NSRect(origin: .zero, size: pixels)
            scroll.minMagnification = max(0.02, fit * 0.5)
            scroll.magnification = fit
            clip.scroll(to: .zero)
            scroll.reflectScrolledClipView(clip)
            fitted = fit
        }
    }

    /// A PDF's pages, one above another, scrolling, fitted to the room's
    /// width. The system's own pinch and two-finger scroll work as they do
    /// anywhere, because the door is the key window.
    func show(pdf document: PDFDocument, caption text: String) {
        present(.pdf, saves: false, caption: text) { room in
            let view = PDFView(frame: NSRect(x: Self.pad, y: Self.footerHeight + Self.pad,
                                             width: room.width, height: room.height))
            Self.configure(view, showing: document)
            root.addSubview(view)
            pdfView = view
            // A page opens whole, a sheet on the glass with the next one
            // below it, from the top of the first: fitted to the width it
            // stood one page across the display, opened somewhere inside it.
            if let first = document.page(at: 0) {
                let page = first.bounds(for: view.displayBox)
                view.autoScales = false
                view.scaleFactor = Self.pageScale(page: page.size, room: room)
                view.go(to: PDFDestination(page: first, at: NSPoint(x: page.minX, y: page.maxY)))
            }
        }
    }

    /// The scale a page opens at: the whole page in the room's height, with
    /// a margin of glass above and below, and never wider than the room.
    static func pageScale(page: CGSize, room: CGSize) -> CGFloat {
        guard page.width > 0, page.height > 0, room.width > 0, room.height > 0 else { return 1 }
        return min(room.height * Self.pageFill / page.height, room.width / page.width)
    }

    /// Anything else, as the system previews it: a film plays, a document
    /// reads, a folder shows what it is.
    func show(preview url: URL, caption text: String) {
        present(.preview, saves: false, caption: text) { room in
            guard let view = QLPreviewView(frame: NSRect(x: Self.pad, y: Self.footerHeight + Self.pad,
                                                         width: room.width, height: room.height),
                                           style: .normal) else { return }
            view.autostarts = true
            // Closed by the door, not by a window that stays: the door
            // is hidden, never closed, and a preview left open keeps
            // playing.
            view.shouldCloseWithWindow = false
            view.previewItem = url as NSURL
            root.addSubview(view)
            previewView = view
        }
    }

    /// One file, shown as what it is. The type is what the file is now, and
    /// the one it had when it was copied (`kind`) stands in when the disk
    /// will not say. A file that cannot be read as the kind it claims (an
    /// image no decoder knows, a damaged PDF) is previewed by the system
    /// instead, which knows more. The kind shown is returned for the record.
    @discardableResult
    func show(file url: URL, kind copied: String?, caption text: String) -> Content {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .ubiquitousItemDownloadingStatusKey])
        let type = values?.contentType ?? copied.flatMap { UTType($0) }
        // A file whose content is not on this Mac would be fetched by the
        // read on this thread, and the app would wait on the network: the
        // system's preview fetches it in its own process instead.
        let here = !FileSense.dataless(url, values?.ubiquitousItemDownloadingStatus)
        switch here ? Content.of(type) : .preview {
        case .image:
            if let (image, pixels) = Self.loadImage(at: url) {
                show(image: image, pixels: pixels, caption: text, saves: false)
                return .image
            }
        case .pdf:
            if let document = PDFDocument(url: url) {
                show(pdf: document, caption: text)
                return .pdf
            }
        case .preview:
            break
        }
        show(preview: url, caption: text)
        return .preview
    }

    /// How a PDF stands in the room: pages stacked with a little space
    /// between them, scrolling without end, scaled to the room's width,
    /// on the glass itself with no ground of its own and none of PDFKit's
    /// shadows, which are the system's and not the door's.
    static func configure(_ view: PDFView, showing document: PDFDocument) {
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: pageMargin, left: pageMargin,
                                             bottom: pageMargin, right: pageMargin)
        view.pageShadowsEnabled = false
        view.backgroundColor = .clear
        view.acceptsDraggedFiles = false
        // The document comes before the limits, because a view given a
        // document goes back to its own (a hundredfold); and setting a limit
        // turns the fit off, so the fit comes last.
        view.document = document
        // Its scroll bars float over the pages, as the picture's do: a bar
        // that keeps its own strip (System Settings' "always") takes the
        // width the pages were fitted to, and they stand a bar's width too
        // wide, sliding sideways for nothing. Seen on CI, 2026-10-20.
        if let scroll = view.documentView?.enclosingScrollView {
            scroll.scrollerStyle = .overlay
            // The room is measured again at once, so the fit below is taken
            // with the bar floating, not with the strip it had kept.
            scroll.tile()
        }
        view.minScaleFactor = pdfScales.lowerBound
        view.maxScaleFactor = pdfScales.upperBound
        view.autoScales = true
    }

    /// The frame, the line under the room, the keys, and the focus, which
    /// every kind of thing shown shares; `body` puts the thing itself in
    /// the room.
    private func present(_ content: Content, saves: Bool, caption text: String,
                         body: (CGSize) -> Void) {
        let screen = ActivePolicy.presentationFrame
        let frame = screen.insetBy(dx: Self.margin, dy: Self.margin)
        let room = CGSize(width: frame.width - Self.pad * 2,
                          height: frame.height - Self.pad * 2 - Self.footerHeight)
        // A second opening without a closing starts from nothing.
        clearRoom()
        shownContent = content
        shownCaption = text

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        panel.setPaneFrame(frame, display: false)
        backdrop?.frame = root.bounds
        scroll.isHidden = true
        body(room)

        caption.stringValue = text
        caption.sizeToFit()
        keys = Keycaps.line(Self.footer(content, saves: saves))
        keys.translatesAutoresizingMaskIntoConstraints = true
        root.addSubview(keys)
        let keySize = keys.fittingSize
        let footerY = ((Self.footerHeight - caption.frame.height) / 2).rounded()
        keys.frame = NSRect(x: frame.width - Self.pad - keySize.width,
                            y: (footerY + (caption.frame.height - keySize.height) / 2).rounded(),
                            width: keySize.width, height: keySize.height)
        caption.frame = NSRect(x: Self.pad, y: footerY,
                               width: max(0, keys.frame.minX - Grid.margin),
                               height: caption.frame.height)

        // Focus, taken deliberately and remembered: the app in front is
        // the one that gets it back.
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            returnsFocusTo = front
        }
        SystemEvents.activateLodestar()
        panel.makeKeyAndOrderFront(nil)
        CATransaction.commit()
        NSAnimationContext.endGrouping()
        // Only the picture is driven by our own gestures; a PDF and a
        // preview take the pinch and the scroll themselves.
        if content == .image { watchGestures() } else { stopWatching() }
    }

    /// Whatever the last opening left in the room.
    private func clearRoom() {
        pdfView?.removeFromSuperview()
        pdfView = nil
        previewView?.close()
        previewView?.removeFromSuperview()
        previewView = nil
        keys.removeFromSuperview()
    }

    func hide() {
        stopWatching()
        panel.orderOut(nil)
        if let back = returnsFocusTo, !back.isTerminated {
            SystemEvents.activate(back)
        }
        returnsFocusTo = nil
        clearRoom()
        imageView.image = nil
        shownImageSize = nil
        shownMagnification = nil
        shownCaption = nil
        shownContent = nil
    }
}

// MARK: - Gestures

extension ImageDoor {
    /// A pinch reaches the active application, and Lodestar is never
    /// active: the event goes to whatever app is in front, and a window
    /// that never becomes key never sees it. So the door listens the way
    /// the strip listens for clicks — a global monitor, live only while
    /// the door stands, reading gestures made over the door and driving
    /// the zoom itself. A local monitor covers the one case where the
    /// event does reach this process, and swallows it there so the scroll
    /// view's own handler cannot apply the same pinch twice. Two-finger
    /// scrolling goes to the window under the pointer whichever app is
    /// active, so the scroll view pans natively; the global watcher only
    /// steps in when a scroll was routed elsewhere.
    private func watchGestures() {
        guard monitors.isEmpty else { return }
        let gestures: NSEvent.EventTypeMask = [.magnify, .smartMagnify]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: gestures.union(.scrollWheel),
                                                          handler: { [weak self] event in
            self?.gesture(event)
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: gestures,
                                                        handler: { [weak self] event in
            guard let self, self.gesture(event) else { return event }
            return nil
        }) {
            monitors.append(local)
        }
    }

    private func stopWatching() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    /// True when the event was made over the door and was applied.
    @discardableResult
    private func gesture(_ event: NSEvent) -> Bool {
        guard isVisible else { return false }
        let pointer = NSEvent.mouseLocation
        guard panel.paneFrame.contains(pointer) else { return false }
        switch event.type {
        case .magnify:
            pinch(by: event.magnification, at: pointer)
        case .smartMagnify:
            smartZoom(at: pointer)
        case .scrollWheel:
            pan(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
                precise: event.hasPreciseScrollingDeltas)
        default:
            return false
        }
        return true
    }

    /// One pinch: the magnification scaled by the gesture's own factor,
    /// held between the door's floor and ceiling, about the point under
    /// the pointer so what the fingers are on stays under them.
    func pinch(by factor: CGFloat, at screenPoint: NSPoint) {
        let target = Self.zoomed(scroll.magnification, by: factor,
                                 floor: scroll.minMagnification, ceiling: scroll.maxMagnification)
        scroll.setMagnification(target, centeredAt: documentPoint(at: screenPoint))
        scroll.reflectScrolledClipView(clip)
    }

    /// Two fingers tapped twice: to one point per pixel from the fitted
    /// size, back to fitted from anywhere else.
    func smartZoom(at screenPoint: NSPoint) {
        let target: CGFloat = abs(scroll.magnification - fitted) < 0.001 ? max(fitted, 1) : fitted
        scroll.setMagnification(min(scroll.maxMagnification, target),
                                centeredAt: documentPoint(at: screenPoint))
        scroll.reflectScrolledClipView(clip)
    }

    func pan(dx: CGFloat, dy: CGFloat, precise: Bool) {
        let step: CGFloat = precise ? 1 : 10
        var origin = clip.bounds.origin
        origin.x -= dx * step / scroll.magnification
        origin.y += dy * step / scroll.magnification
        let bounds = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size))
        clip.scroll(to: bounds.origin)
        scroll.reflectScrolledClipView(clip)
    }

    static func zoomed(_ current: CGFloat, by factor: CGFloat,
                       floor: CGFloat, ceiling: CGFloat) -> CGFloat {
        min(ceiling, max(floor, current * (1 + factor)))
    }

    /// `h` `j` `k` `l`: the picture slides a stride under the eye, the
    /// way a page does in scroll mode — `j` brings what is below into
    /// view, `l` what is to the right.
    func move(_ key: String, fast: Bool) {
        switch shownContent {
        case .pdf: return Self.slide(pdfView?.documentView?.enclosingScrollView, key, fast: fast)
        case .preview: return Self.slide(previewView.flatMap { Self.firstScroller(in: $0) }, key, fast: fast)
        case .image, nil: break
        }
        let stride = Self.moveStep * (fast ? Self.fastMultiplier : 1) / scroll.magnification
        var origin = clip.bounds.origin
        switch key {
        case "h": origin.x -= stride
        case "l": origin.x += stride
        case "j": origin.y -= stride
        case "k": origin.y += stride
        default: return
        }
        let bounds = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size))
        clip.scroll(to: bounds.origin)
        scroll.reflectScrolledClipView(clip)
    }

    /// `+` and `-`: one step about the center of what is shown.
    func zoom(in zoomIn: Bool) {
        switch shownContent {
        case .pdf:
            if let view = pdfView { Self.zoom(view, in: zoomIn) }
            return
        case .preview: return // the system's preview zooms by what it is
        case .image, nil: break
        }
        let factor = zoomIn ? Self.zoomStep - 1 : 1 / Self.zoomStep - 1
        let target = Self.zoomed(scroll.magnification, by: factor,
                                 floor: scroll.minMagnification, ceiling: scroll.maxMagnification)
        let center = NSPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        scroll.setMagnification(target, centeredAt: center)
        scroll.reflectScrolledClipView(clip)
    }

    /// `h` `j` `k` `l` for a view that scrolls by itself: one stride, in
    /// points of the screen however the view counts its own.
    static func slide(_ scroller: NSScrollView?, _ key: String, fast: Bool) {
        guard let scroller, let document = scroller.documentView else { return }
        let clipView = scroller.contentView
        let perPoint = clipView.frame.width > 0 ? clipView.bounds.width / clipView.frame.width : 1
        let stride = moveStep * (fast ? fastMultiplier : 1) * perPoint
        guard let origin = slid(clipView.bounds.origin, key, stride: stride,
                                     flipped: document.isFlipped) else { return }
        let bounds = clipView.constrainBoundsRect(NSRect(origin: origin, size: clipView.bounds.size))
        clipView.scroll(to: bounds.origin)
        scroller.reflectScrolledClipView(clipView)
    }

    /// `+` and `-` for a PDF: one step of the door's, held between the
    /// view's own limits.
    static func zoom(_ view: PDFView, in zoomIn: Bool) {
        let target = zoomed(view.scaleFactor, by: zoomIn ? zoomStep - 1 : 1 / zoomStep - 1,
                            floor: view.minScaleFactor, ceiling: view.maxScaleFactor)
        // Setting a scale turns the fit off (measured), so a chosen scale is a
        // scale kept; the test holds that to be true of this system.
        view.scaleFactor = target
    }

    /// Where the view's origin goes for a key: `j` brings what is below
    /// into view, `l` what is to the right. A flipped document counts its
    /// rows downward, so below is a larger y there and a smaller one in
    /// an unflipped picture. Nil for a key that is not a direction.
    static func slid(_ origin: NSPoint, _ key: String, stride: CGFloat, flipped: Bool) -> NSPoint? {
        var next = origin
        let down = flipped ? stride : -stride
        switch key {
        case "h": next.x -= stride
        case "l": next.x += stride
        case "j": next.y += down
        case "k": next.y -= down
        default: return nil
        }
        return next
    }

    /// The first scroll view inside a preview, when the preview is drawn
    /// in this process; most are drawn in another and have none.
    static func firstScroller(in view: NSView) -> NSScrollView? {
        if let scroller = view as? NSScrollView { return scroller }
        for child in view.subviews {
            if let found = firstScroller(in: child) { return found }
        }
        return nil
    }

    /// Where the picture is scrolled to, in document points, for the
    /// tests.
    var visibleOrigin: NSPoint { clip.bounds.origin }

    private func documentPoint(at screenPoint: NSPoint) -> NSPoint {
        let inWindow = panel.convertPoint(fromScreen: screenPoint)
        return imageView.convert(inWindow, from: nil)
    }
}

/// A clip view that keeps a picture smaller than itself in the middle,
/// at every magnification, so zooming out never leaves the image pinned
/// to a corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let frame = document.frame
        if rect.width > frame.width {
            rect.origin.x = frame.minX - (rect.width - frame.width) / 2
        }
        if rect.height > frame.height {
            rect.origin.y = frame.minY - (rect.height - frame.height) / 2
        }
        return rect
    }
}
