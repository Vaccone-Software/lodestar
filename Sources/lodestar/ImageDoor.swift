import AppKit
import LodestarCore

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
final class ImageDoor {
    let panel: KeyablePanel
    /// The app that was in front when the door opened, to be put back.
    private(set) var returnsFocusTo: NSRunningApplication?
    private let root = NSView()
    private var backdrop: NSView?
    private let scroll = NSScrollView()
    private let clip = CenteringClipView()
    private let imageView = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let keys = NSTextField(labelWithString: "")
    /// The gesture watchers, live only while the door stands.
    private var monitors: [Any] = []
    /// The magnification the picture opened at: what a smart zoom (two
    /// fingers, tapped twice) returns to.
    private var fitted: CGFloat = 1

    private static let margin: CGFloat = 22
    private static let pad: CGFloat = 22
    private static let footerHeight: CGFloat = 26
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

    var isVisible: Bool { panel.isVisible }
    /// What the screen shows, for the tests: the image as first drawn, in
    /// points, the magnification that drew it, and the line under it.
    private(set) var shownImageSize: NSSize?
    private(set) var shownMagnification: CGFloat?
    private(set) var shownCaption: String?
    /// The current magnification, for the tests and the record.
    var magnification: CGFloat { scroll.magnification }

    init() {
        // The launcher's key panel, at the strip's level: titled and
        // hidden so the window server rounds it, able to become key so
        // the gestures of an active app land in it.
        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: [], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = false
        // Every key the grammar did not take arrives here; none has a
        // meaning, and a key window that beeps at each is not quiet.
        panel.onKeyDown = { _ in true }
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
        keys.stringValue = "h j k l move · ⇧ faster · + − zoom · S save · esc back"
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

        fitted = fit
        // Focus, taken deliberately and remembered: the app in front is
        // the one that gets it back.
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            returnsFocusTo = front
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        CATransaction.commit()
        NSAnimationContext.endGrouping()
        watchGestures()
    }

    func hide() {
        stopWatching()
        panel.orderOut(nil)
        if let back = returnsFocusTo, !back.isTerminated {
            back.activate()
        }
        returnsFocusTo = nil
        imageView.image = nil
        shownImageSize = nil
        shownMagnification = nil
        shownCaption = nil
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
        guard panel.frame.contains(pointer) else { return false }
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
        let factor = zoomIn ? Self.zoomStep - 1 : 1 / Self.zoomStep - 1
        let target = Self.zoomed(scroll.magnification, by: factor,
                                 floor: scroll.minMagnification, ceiling: scroll.maxMagnification)
        let center = NSPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        scroll.setMagnification(target, centeredAt: center)
        scroll.reflectScrolledClipView(clip)
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
