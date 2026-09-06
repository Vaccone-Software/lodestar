import AppKit
import LodestarCore

/// An image card, open large above the strip.
///
/// The text card's door is the draft; an image has no text to edit, so
/// its door is the image itself, drawn on the launcher's glass at the
/// largest size the display allows without inventing pixels — never past
/// one point per pixel, never past the room above the strip. The card
/// stays lit beneath it and the pin column steps aside, exactly as for
/// the clip door, so the two doors read as one idea. Nothing here is
/// clicked and nothing is typed: the panel takes no mouse events and
/// never becomes key, and the strip's grammar keeps every key.
final class ImageDoor {
    let panel: NSPanel
    private let root = NSView()
    private var backdrop: NSView?
    private let imageView = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let keys = NSTextField(labelWithString: "")

    private static let margin: CGFloat = 22
    private static let pad: CGFloat = 22
    private static let footerHeight: CGFloat = 26
    /// The narrowest the door draws, so a small image still carries its
    /// caption and its keys on one line.
    private static let minWidth: CGFloat = 420

    var isVisible: Bool { panel.isVisible }
    /// What the screen shows, for the tests: the image's drawn size in
    /// points, and the line under it.
    private(set) var shownImageSize: NSSize?
    private(set) var shownCaption: String?

    init() {
        panel = Glass.makePanel(level: .statusBar)
        panel.ignoresMouseEvents = true
        panel.contentView = root
        backdrop = Glass.installBackdrop(in: root, cornerRadius: BarTheme.glassRadius)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        caption.font = BarTheme.secondaryFont
        caption.textColor = BarTheme.secondaryColor
        caption.lineBreakMode = .byTruncatingTail
        keys.font = BarTheme.footerFont
        keys.textColor = BarTheme.secondaryColor
        keys.alignment = .right
        keys.stringValue = "S save · esc back"
        root.addSubview(imageView)
        root.addSubview(caption)
        root.addSubview(keys)
    }

    /// The largest size that fits the room without inventing pixels: the
    /// image's own pixel count is the ceiling in points, so a small
    /// screenshot stands at its full sharpness and a huge one is fitted.
    static func fit(pixels: CGSize, within room: CGSize) -> CGSize {
        guard pixels.width > 0, pixels.height > 0, room.width > 0, room.height > 0 else {
            return .zero
        }
        let scale = min(1, room.width / pixels.width, room.height / pixels.height)
        return CGSize(width: (pixels.width * scale).rounded(.down),
                      height: (pixels.height * scale).rounded(.down))
    }

    func show(image: NSImage, pixels: CGSize, caption text: String, standsAbove: CGFloat) {
        let screen = ActivePolicy.presentationFrame
        let room = CGSize(width: screen.width - Self.margin * 2 - Self.pad * 2,
                          height: screen.height - standsAbove - Self.margin * 2
                              - Self.pad * 2 - Self.footerHeight)
        let size = Self.fit(pixels: pixels, within: room)
        shownImageSize = size
        shownCaption = text

        let width = max(Self.minWidth, size.width + Self.pad * 2)
        let height = size.height + Self.pad * 2 + Self.footerHeight
        let frame = NSRect(x: (screen.midX - width / 2).rounded(),
                           y: screen.minY + Self.margin + standsAbove,
                           width: width, height: height)

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        panel.setFrame(frame, display: false)
        root.frame = NSRect(origin: .zero, size: frame.size)
        backdrop?.frame = root.bounds

        imageView.image = image
        imageView.frame = NSRect(x: ((width - size.width) / 2).rounded(),
                                 y: Self.footerHeight + Self.pad,
                                 width: size.width, height: size.height)

        caption.stringValue = text
        caption.sizeToFit()
        keys.sizeToFit()
        let footerY = ((Self.footerHeight - caption.frame.height) / 2 + 6).rounded()
        keys.frame = NSRect(x: width - Self.pad - keys.frame.width, y: footerY,
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
        shownImageSize = nil
        shownCaption = nil
    }
}
