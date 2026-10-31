import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// One surface of the gallery in one look: built once for the process
/// (`GalleryBuilds`), laid out, and read by every rule of every sweep.
struct GalleryPicture {
    let shot: GalleryShot
    let look: GalleryLook
    let root: NSView
    let keep: [AnyObject]

    /// "surface-state-look": how every failure line names what broke.
    var name: String { shot.name(in: look) }
}

/// The sweeps over the gallery: every rule of the design is held against the
/// pictures the gallery takes, and a sweep is only the walk over them.
///
/// The walk is the same for all of them, so it is written once: each look is
/// put in force and let land, each picture is taken from the process's one
/// build of it (never waited for again) and laid out explicitly, and what a
/// rule finds wrong is reported under the surface that broke it, not as one
/// line for the whole gallery.
enum GallerySweep {
    /// Which of Eye comfort's hours a sweep draws for real.
    ///
    /// The palette at an hour is arithmetic, and `EyeComfortLooksTests` holds
    /// every floor of both looks at every hour of the day (and at every level
    /// between); what a sweep reads off the glass needs one dimmed hour to see
    /// the dimming reach it, and takes bedtime, the deepest, where every floor
    /// is closest. So a sweep draws the full level and bedtime (`.drawn`, the
    /// default) and not the evening's pictures, and one that wants those too
    /// says `.every`.
    enum Hours {
        case drawn, every

        func includes(_ shot: GalleryShot) -> Bool {
            switch self {
            case .every: return true
            case .drawn: return shot.level != GalleryShots.evening
            }
        }
    }

    /// Every picture the gallery takes, in each look it takes it in, for the
    /// shots `include` accepts: each look is put in force and let land, and
    /// each picture comes from the process's one build of it, laid out.
    ///
    /// - `eyeComfort`: the level a shot was taken at is in force while its
    ///   picture is read (a sweep that measures colour needs the palette it was
    ///   drawn in), and full again after; without it the level is full, and a
    ///   dimmed shot is read as drawn at full.
    /// - `drawing`: the sweep draws the picture or changes it. A shot with a
    ///   caret in it is then built afresh instead of served (see `GalleryBuilds`).
    /// - A shot that cannot be built is a failure naming it, not a picture
    ///   quietly left out: a rule that never looked is not a rule.
    static func pictures(looks: [GalleryLook] = GalleryLook.all, eyeComfort: Bool = false, hours: Hours = .drawn,
                         drawing: Bool = false,
                         where include: @escaping (GalleryShot) -> Bool = { _ in true },
                         file: StaticString = #filePath, line: UInt = #line) -> AnySequence<GalleryPicture> {
        AnySequence {
            Walk(looks: looks, eyeComfort: eyeComfort, hours: hours, drawing: drawing, include: include, file: file, line: line)
        }
    }

    private struct Walk: IteratorProtocol {
        let eyeComfort: Bool
        let hours: Hours
        let drawing: Bool
        let include: (GalleryShot) -> Bool
        let file: StaticString
        let line: UInt
        private var looks: ArraySlice<GalleryLook>
        private var look: GalleryLook?
        private var shots: [GalleryShot] = []
        private var index = 0
        private var dimmed = false

        init(looks: [GalleryLook], eyeComfort: Bool, hours: Hours, drawing: Bool,
             include: @escaping (GalleryShot) -> Bool, file: StaticString, line: UInt) {
            self.looks = looks[...]
            self.eyeComfort = eyeComfort
            self.hours = hours
            self.drawing = drawing
            self.include = include
            self.file = file
            self.line = line
        }

        mutating func next() -> GalleryPicture? {
            if dimmed { EyeComfortState.shared.set(enabled: false, level: 1); dimmed = false }
            while true {
                if index >= shots.count {
                    guard let following = looks.popFirst() else { return nil }
                    look = following
                    following.apply()
                    // Whatever the look's turn left on the main queue lands once, here,
                    // and not one picture at a time.
                    GalleryHost.drain()
                    shots = GalleryShots.all.filter { $0.looks.contains(following) && hours.includes($0) && include($0) }
                    index = 0
                    continue
                }
                let shot = shots[index]
                index += 1
                guard let look else { return nil }
                if eyeComfort {
                    EyeComfortState.shared.set(enabled: shot.level < 1 || shot.receded, level: shot.level)
                    dimmed = true
                }
                do {
                    let made = try shot.built(in: look, drawing: drawing)
                    GalleryHost.layOut(made.view)
                    return GalleryPicture(shot: shot, look: look, root: made.view, keep: made.keep)
                } catch {
                    XCTFail("\(shot.name(in: look)) could not be built: \(error)", file: file, line: line)
                    if dimmed { EyeComfortState.shared.set(enabled: false, level: 1); dimmed = false }
                }
            }
        }
    }

    /// What the sweeps found, grouped under the surface that broke each rule: a
    /// message is "<surface>: <what is wrong>", as the sweeps write them, and
    /// the same finding twice is one.
    static func grouped(_ wrong: [String]) -> [String: [String]] {
        var bySurface: [String: [String]] = [:]
        for message in Set(wrong) {
            let split = message.range(of: ": ")
            let surface = split.map { String(message[..<$0.lowerBound]) } ?? "(unnamed)"
            bySurface[surface, default: []].append(split.map { String(message[$0.upperBound...]) } ?? message)
        }
        return bySurface.mapValues { $0.sorted() }
    }

    /// One failure for each surface that has something found in it, naming the
    /// surface, the rule, and everything the rule found there: a red says what
    /// broke where, and a surface that is slow or broken is no longer one line
    /// for the whole gallery.
    static func expectNone(_ wrong: [String], _ rule: String, file: StaticString = #filePath, line: UInt = #line) {
        let bySurface = grouped(wrong)
        for surface in bySurface.keys.sorted() {
            let found = bySurface[surface, default: []]
            XCTFail("\(surface) breaks \"\(rule)\": \(found.count) found\n  " + found.joined(separator: "\n  "), file: file, line: line)
        }
    }
}

/// A bitmap read pixel by pixel as the sRGB colour the sweeps measure.
///
/// `colorAt(x:y:)` makes a colour of every pixel and `usingColorSpace` converts
/// it, and a rule that scans the ink of every word on every surface at the
/// bitmap's own resolution does that a few million times: most of what a
/// sweep that reads pixels costs. A picture is a few flat grounds and the
/// edges between them, so the same four bytes come up again and again; the
/// conversion is made once for each and the answer kept. The answer is the one
/// `colorAt(x:y:)?.usingColorSpace(.sRGB)` gives for those bytes, nothing
/// else (`GalleryHostTests` holds that).
enum GalleryPixels {
    private nonisolated(unsafe) static var converted: [UInt32: NSColor] = [:]

    /// `rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)`.
    static func srgb(_ rep: NSBitmapImageRep, x: Int, y: Int) -> NSColor? {
        guard rep.bitsPerPixel == 32, !rep.isPlanar, rep.samplesPerPixel == 4, rep.bitsPerSample == 8,
              (0..<rep.pixelsWide).contains(x), (0..<rep.pixelsHigh).contains(y),
              let data = rep.bitmapData else { return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) }
        let at = data + y * rep.bytesPerRow + x * 4
        let key = UInt32(at[0]) << 24 | UInt32(at[1]) << 16 | UInt32(at[2]) << 8 | UInt32(at[3])
        if let known = converted[key] { return known }
        guard let made = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
        converted[key] = made
        return made
    }
}

/// The part of a picture a rule reads, drawn alone.
///
/// A rule that reads a slab's face and the words standing on it reads a few
/// rows of a picture that is a window and the shadow round it, and drawing all
/// of it (the shadow is blurred, at twice the points) was most of what such a
/// sweep cost. The region is the rectangles the rule says it reads, a little
/// round them, drawn by the same pass as the whole picture, so each pixel in
/// it is the pixel the whole picture has there, bar the odd one a level of 255
/// off (four in nine million, `GalleryHostTests`). Every pixel the slab rules
/// read, three million of them in the gallery, was held against the whole
/// picture's, drawn with the keys, when this was written: none differed. A
/// region is drawn without the keys (`keys: false`): the rules read no caret,
/// and only one window in the Mac has the keys, so a panel waited for them,
/// up to three seconds, while another process held them.
/// A pixel asked for outside the region, in the picture, is a failure naming
/// it, never a quiet nothing: what a rule did not say it reads, it cannot miss.
///
/// Coordinates are the picture's: points counted from its top, as the rules
/// write them, and pixels counted the same way at `GalleryRender.scale`.
struct GalleryRegion {
    let rep: NSBitmapImageRep
    let name: String
    /// Pixels to a point, as the whole picture has them (`width` over the view's width).
    let scale: CGFloat
    /// The region's first column and row, in the picture's pixels.
    let left: Int
    let top: Int
    /// The picture's size in pixels, as drawn whole.
    let width: Int
    let height: Int

    /// `view` drawn over `rects` (points, from the top of the view) and `margin` round them.
    /// A view whose size is not a whole number of pixels at the picture's scale is drawn
    /// at a scale of its own, which a part of it does not share: it is drawn whole.
    static func render(_ view: NSView, covering rects: [NSRect], margin: CGFloat = 2, keys: Bool = false,
                       name: String) -> GalleryRegion {
        let scale = GalleryRender.scale
        let size = view.bounds.size
        var box = rects.first ?? NSRect(x: 0, y: 0, width: 1, height: 1)
        for rect in rects.dropFirst() { box = box.union(rect) }
        box = box.insetBy(dx: -margin, dy: -margin).intersection(NSRect(origin: .zero, size: size))
        if abs(size.width * scale - (size.width * scale).rounded()) > 1e-6
            || abs(size.height * scale - (size.height * scale).rounded()) > 1e-6 {
            let whole = GalleryRender.bitmap(of: view)
            return GalleryRegion(rep: whole, name: name, scale: CGFloat(whole.pixelsWide) / size.width, left: 0, top: 0,
                                 width: whole.pixelsWide, height: whole.pixelsHigh)
        }
        let minX = box.minX.rounded(.down), minY = box.minY.rounded(.down)
        let maxX = box.maxX.rounded(.up), maxY = box.maxY.rounded(.up)
        let region = NSRect(x: minX, y: view.isFlipped ? minY : size.height - maxY, width: max(1, maxX - minX),
                            height: max(1, maxY - minY))
        return GalleryRegion(rep: GalleryRender.bitmap(of: view, region: region, scale: scale, keys: keys), name: name, scale: scale,
                             left: Int(minX * scale), top: Int(minY * scale),
                             width: Int((size.width * scale).rounded()), height: Int((size.height * scale).rounded()))
    }

    /// The sRGB colour of the picture's pixel (`x`, `y`): what `GalleryPixels.srgb` gives on the whole bitmap.
    func srgb(x: Int, y: Int, file: StaticString = #filePath, line: UInt = #line) -> NSColor? {
        guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
        let column = x - left, row = y - top
        guard (0..<rep.pixelsWide).contains(column), (0..<rep.pixelsHigh).contains(row) else {
            XCTFail("\(name): pixel (\(x), \(y)) was read outside the region drawn for the rule", file: file, line: line)
            return nil
        }
        return GalleryPixels.srgb(rep, x: column, y: row)
    }
}
