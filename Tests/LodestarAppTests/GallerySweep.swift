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
