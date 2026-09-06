import AppKit
import LodestarCore

/// An image card, open across the display.
///
/// The text card's door is the draft; an image has no text to edit, so
/// its door is the image itself, on the launcher's glass across the whole
/// visible display with the strip gone beneath it. It opens fitted, so
/// the whole picture is seen first, and from there the trackpad does what
/// it does to any image: a pinch zooms about the pointer, two fingers
/// pan, and the picture never leaves its frame. No slider, no buttons —
/// the panel takes gestures and nothing else, and never becomes key, so
/// the app underneath keeps its cursor. The strip's grammar keeps every
/// key: `esc` and `⏎` step back, `S` goes on to the save band.
final class ImageDoor {
    let panel: NSPanel
    private let root = NSView()
    private var backdrop: NSView?
    private let scroll = NSScrollView()
    private let clip = CenteringClipView()
    private let imageView = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let keys = NSTextField(labelWithString: "")

    private static let margin: CGFloat = 22
    private static let pad: CGFloat = 22
    private static let footerHeight: CGFloat = 26
    /// How far a pinch may go past one point per pixel; past this the
    /// picture is blocks, and blocks are not what anyone zoomed in for.
    private static let maxMagnification: CGFloat = 8

    var isVisible: Bool { panel.isVisible }
    /// What the screen shows, for the tests: the image as first drawn, in
    /// points, the magnification that drew it, and the line under it.
    private(set) var shownImageSize: NSSize?
    private(set) var shownMagnification: CGFloat?
    private(set) var shownCaption: String?
    /// The current magnification, for the tests and the record.
    var magnification: CGFloat { scroll.magnification }

    init() {
        panel = Glass.makePanel(level: .statusBar)
        // Gestures reach the picture: a pinch and a two-finger pan land
        // in the scroll view. The panel still never becomes key.
        panel.ignoresMouseEvents = false
        panel.contentView = root
        backdrop = Glass.installBackdrop(in: root, cornerRadius: BarTheme.glassRadius)

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

        caption.font = BarTheme.secondaryFont
        caption.textColor = BarTheme.secondaryColor
        caption.lineBreakMode = .byTruncatingTail
        keys.font = BarTheme.footerFont
        keys.textColor = BarTheme.secondaryColor
        keys.alignment = .right
        keys.stringValue = "pinch to zoom · S save · esc back"
        root.addSubview(scroll)
        root.addSubview(caption)
        root.addSubview(keys)
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

    func show(image: NSImage, pixels: CGSize, caption text: String) {
        let screen = ActivePolicy.presentationFrame
        let frame = screen.insetBy(dx: Self.margin, dy: Self.margin)
        let room = CGSize(width: frame.width - Self.pad * 2,
                          height: frame.height - Self.pad * 2 - Self.footerHeight)
        let size = Self.fit(pixels: pixels, within: room)
        let fit = pixels.width > 0 ? size.width / pixels.width : 1
        shownImageSize = size
        shownMagnification = fit
        shownCaption = text

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        panel.setFrame(frame, display: false)
        root.frame = NSRect(origin: .zero, size: frame.size)
        backdrop?.frame = root.bounds

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

        caption.stringValue = text
        caption.sizeToFit()
        keys.sizeToFit()
        let footerY = ((Self.footerHeight - caption.frame.height) / 2 + 6).rounded()
        keys.frame = NSRect(x: frame.width - Self.pad - keys.frame.width, y: footerY,
                            width: keys.frame.width, height: keys.frame.height)
        caption.frame = NSRect(x: Self.pad, y: footerY,
                               width: max(0, keys.frame.minX - Self.pad * 1.5),
                               height: caption.frame.height)

        panel.orderFrontRegardless()
        CATransaction.commit()
        NSAnimationContext.endGrouping()
    }

    func hide() {
        panel.orderOut(nil)
        imageView.image = nil
        shownImageSize = nil
        shownMagnification = nil
        shownCaption = nil
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
