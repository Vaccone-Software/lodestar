import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// A look to render in: the Mac's appearance, and nothing else the person
/// who runs the gallery could have changed.
struct GalleryLook: Equatable {
    let name: String
    let appearance: NSAppearance.Name

    static let day = GalleryLook(name: "day", appearance: .aqua)
    static let night = GalleryLook(name: "night", appearance: .darkAqua)
    static let all = [day, night]

    /// Make the process this look: the application's appearance (which the
    /// tone and every window without one of its own follow) and the accent
    /// Lodestar draws in its own orange, not whichever the Mac running the
    /// gallery has chosen, so a picture is the same on every machine.
    func apply() {
        NSApplication.shared.appearance = NSAppearance(named: appearance)
        Ceramic.followSystemAppearance()
        BarTheme.accentColor = { BarTheme.internationalOrange }
    }

    static func reset() {
        NSApplication.shared.appearance = nil
        BarTheme.accentColor = { BarTheme.internationalOrange }
        Ceramic.followSystemAppearance()
    }
}

/// Pictures of the surfaces, drawn offscreen: no app, no screen, no
/// recording permission. The one place a layer-drawn key, row or shadow is
/// seen without running the app.
enum GalleryRender {
    /// Where the pictures go: the directory the environment names, or nil
    /// when nobody asked for them.
    static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["LODESTAR_RENDER"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    }

    static let scale: CGFloat = 2

    /// A window that has the keys while it is drawn, and where it came from.
    struct Keyed {
        let window: NSWindow
        let origin: NSPoint

        /// Put it away where it was.
        func release() {
            window.orderOut(nil)
            window.setFrameOrigin(origin)
        }
    }

    /// Where a window stands while it holds the keys for a picture: off every
    /// display, so nothing reaches a screen.
    static let away = NSPoint(x: -30000, y: -30000)

    /// Whether a window that is typed in has the keys while it is drawn: a
    /// caret and a selection are drawn only in the key window, so a picture
    /// of a field with the caret in it needs one. The panel is brought in
    /// away from every display, drawn and put away, and the app is never
    /// activated.
    static func holdingKeys(_ view: NSView) -> Keyed? {
        guard let window = view.window, window.canBecomeKey, !window.isKeyWindow,
              window.firstResponder is WellText else { return nil }
        let keyed = Keyed(window: window, origin: window.frame.origin)
        window.setFrameOrigin(away)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        // A window that activates the app (Settings) cannot take the keys
        // while the app is not active: it stays away, and is drawn as a
        // window nobody can see is (`WellText.holds`).
        guard window.isKeyWindow else { keyed.release(); return nil }
        return keyed
    }
    /// The grey a window stands on, neither the day's ground nor the night's.
    static let desktop = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)

    /// A bitmap of the view as AppKit draws it, `scale` times its size and
    /// transparent where nothing is drawn. The view stands in a window, so
    /// the look is the window's, and every layer a view paints (a face, a
    /// lip, a row's rim, a shadow) is drawn by the same pass the screen takes.
    static func bitmap(of view: NSView, scale: CGFloat = GalleryRender.scale) -> NSBitmapImageRep {
        let keyed = holdingKeys(view)
        defer { keyed?.release() }
        // The compositor lays a pane's rim and edge over its content by
        // position; this draws view by view, so they are brought to the front.
        Ceramic.frontEdges(in: view)
        view.window?.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let size = view.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()),
                                   pixelsHigh: Int((size.height * scale).rounded()), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// A bitmap of a view drawn one child at a time, each with room for the
    /// shadow it casts, laid over each other in order. A view whose children
    /// each stand on their own glass is drawn whole by `cacheDisplay` with
    /// only its last child in it; drawn singly, every child is there.
    static func bitmapBySiblings(of view: NSView, scale: CGFloat = GalleryRender.scale,
                                 room: CGFloat = 40) -> NSBitmapImageRep {
        let keyed = holdingKeys(view)
        defer { keyed?.release() }
        Ceramic.frontEdges(in: view)
        view.window?.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let size = view.bounds.size
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()),
                                   pixelsHigh: Int((size.height * scale).rounded()), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        for child in view.subviews where !child.isHidden {
            let area = child.bounds.insetBy(dx: -room, dy: -room)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((area.width * scale).rounded()),
                                       pixelsHigh: Int((area.height * scale).rounded()), bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = area.size
            child.cacheDisplay(in: area, to: rep)
            rep.draw(in: child.frame.insetBy(dx: -room, dy: -room), from: .zero, operation: .sourceOver,
                     fraction: 1, respectFlipped: false, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    /// The picture a person looks at: the bitmap on the neutral desktop.
    static func onDesktop(_ rep: NSBitmapImageRep, margin: CGFloat = 0) -> NSBitmapImageRep {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let size = NSSize(width: rep.size.width + margin * 2, height: rep.size.height + margin * 2)
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded()),
                                   pixelsHigh: Int((size.height * scale).rounded()), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        desktop.setFill()
        NSRect(origin: .zero, size: size).fill()
        rep.draw(in: NSRect(origin: NSPoint(x: margin, y: margin), size: rep.size), from: .zero,
                 operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    /// The bitmap cut to where something is drawn, `margin` points round it.
    static func trimmed(_ rep: NSBitmapImageRep, margin: CGFloat = 24) -> NSBitmapImageRep {
        guard let data = rep.bitmapData else { return rep }
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where data[y * rep.bytesPerRow + x * 4 + 3] > 6 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return rep }
        let pad = Int(margin * scale)
        let x0 = max(0, minX - pad), y0 = max(0, minY - pad)
        let x1 = min(rep.pixelsWide - 1, maxX + pad), y1 = min(rep.pixelsHigh - 1, maxY + pad)
        let width = x1 - x0 + 1, height = y1 - y0 + 1
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        out.size = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        guard let target = out.bitmapData else { return rep }
        for row in 0..<height {
            memcpy(target + row * out.bytesPerRow, data + (y0 + row) * rep.bytesPerRow + x0 * 4, width * 4)
        }
        return out
    }

    static func write(_ rep: NSBitmapImageRep, name: String) throws {
        guard let directory = outputDirectory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
