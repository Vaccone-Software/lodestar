import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// Eye comfort on the surfaces (design/06-eye-comfort.md): the theme reads
/// the level from one place, Lodestar never leaves the Mac's look, the pill
/// and the meeting's chip recede to their floors and come back at once, and
/// with the switch off everything is exactly as it was.
final class EyeComfortTests: XCTestCase {
    typealias RGB = Readability.RGB

    private let newYork = Coordinate(latitude: 40.7128, longitude: -74.0060)
    private let eastern = TimeZone(identifier: "America/New_York")!

    override func setUp() {
        off()
        GalleryLook.day.apply()
    }

    override func tearDown() {
        let controller = EyeComfortController.shared
        controller.configure(enabled: false)
        controller.now = Date.init
        controller.zone = { .current }
        controller.place = EyeComfortController.estimatedPlace
        off()
        GalleryLook.reset()
        Accessibility.reset()
    }

    private func off() { EyeComfortState.shared.set(enabled: false, level: 1) }

    private func on(_ level: Double) { EyeComfortState.shared.set(enabled: true, level: level) }

    private func rgb(_ color: NSColor, in name: NSAppearance.Name) -> RGB {
        var out = RGB(red: 0, green: 0, blue: 0)
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            out = RGB(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
        }
        return out
    }

    private func same(_ a: RGB, _ b: RGB, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.red, b.red, accuracy: 0.0005, message, file: file, line: line)
        XCTAssertEqual(a.green, b.green, accuracy: 0.0005, message, file: file, line: line)
        XCTAssertEqual(a.blue, b.blue, accuracy: 0.0005, message, file: file, line: line)
    }

    private func contrast(_ a: RGB, _ b: RGB) -> Double { Readability.contrast(a.luminance, b.luminance) }

    private func spin(_ seconds: TimeInterval = 0.08) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    // MARK: - One place

    /// Every colour of the theme is the palette the one place resolves, at the
    /// level in force, in the look of whoever draws it.
    func testTheThemeReadsTheLevelFromOnePlace() {
        on(0.8)
        for (name, full) in [(NSAppearance.Name.aqua, Palette.clay), (.darkAqua, Palette.night)] {
            let steps = EyeComfort.steps(full, level: 0.8)
            XCTAssertEqual(BarTheme.steps(for: NSAppearance(named: name)!), steps, "\(name.rawValue)")
            same(rgb(BarTheme.ink, in: name), steps.ink, "ink")
            same(rgb(BarTheme.secondaryColor, in: name), steps.quietInk, "quiet ink")
            same(rgb(BarTheme.paneFill, in: name), steps.pane, "pane")
            same(rgb(BarTheme.faceFill, in: name), steps.key, "key")
            same(rgb(BarTheme.sideFill, in: name), steps.side, "side")
            same(rgb(BarTheme.wellFill, in: name), steps.well, "well")
        }
        // The theme's own accessors follow the Mac's look (aqua here).
        XCTAssertEqual(BarTheme.palette, EyeComfort.steps(Palette.clay, level: 0.8))
        same(rgb(BarTheme.accent, in: .aqua), BarTheme.palette.orange, "the orange")
        same(rgb(BarTheme.onAccent, in: .aqua), BarTheme.palette.letterOnOrange, "the letter on it")
        XCTAssertNotEqual(BarTheme.palette.pane, Palette.clay.pane, "and it is dimmer than clay")
    }

    /// No surface reads a palette, or works out the level, itself: the theme
    /// and the one place are the only files that name them.
    func testNoSurfaceReadsAPaletteOrTheCurveItself() throws {
        let homes: Set<String> = ["Ceramic.swift", "EyeComfortController.swift", "Recess.swift"]
        var found: [String] = []
        let patterns = [#"Palette\.(clay|night)\b"#, #"EyeComfort\.(steps|level)\("#, #"Receding\.inks"#, #"EyeComfortState"#]
        for file in DesignDriftTests.swiftFiles(under: DesignDriftTests.appSources) where !homes.contains(file.lastPathComponent) {
            let text = DesignDriftTests.code(try String(contentsOf: file, encoding: .utf8))
            for pattern in patterns {
                let regex = try NSRegularExpression(pattern: pattern)
                for match in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                    found.append("\(file.lastPathComponent): \((text as NSString).substring(with: match.range))")
                }
            }
        }
        XCTAssertEqual(found, [], "a surface takes its colours from BarTheme, and the level lives where the palette is resolved")
    }

    /// With the switch off, or the sun up, the palettes are exactly Palette's.
    func testOffIsExactlyOff() {
        on(0.8)
        EyeComfortState.shared.set(enabled: false, level: 0.8)
        XCTAssertEqual(EyeComfortState.shared.level, 1, "off is full level")
        for (name, full) in [(NSAppearance.Name.aqua, Palette.clay), (.darkAqua, Palette.night)] {
            XCTAssertEqual(BarTheme.steps(for: NSAppearance(named: name)!), full, "\(name.rawValue) is the palette as it is")
        }
        let controller = EyeComfortController.shared
        controller.zone = { self.eastern }
        controller.place = { _ in self.newYork }
        controller.now = { self.night() }
        controller.configure(enabled: false)
        XCTAssertEqual(EyeComfortState.shared.level, 1, "the clock at midnight changes nothing while it is off")
        XCTAssertNil(controller.watchingEvery, "and nothing is watching")
        XCTAssertEqual(BarTheme.palette, Palette.clay)
        // Nothing recedes: a pill left alone keeps its inks.
        let pill = ModePill()
        pill.recess.idle = 0
        pill.show(.init(mode: .scroll, app: "Notes", icon: nil, listening: false, text: nil))
        pill.recess.idled()
        XCTAssertFalse(pill.recess.receded)
        let mode = label("Scroll", in: pill.drawnRoot)
        same(rgb(mode.textColor ?? .clear, in: .aqua), Palette.clay.ink, "full ink")
        pill.hide()
    }

    private func night() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = eastern
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 1, minute: 0))!
    }

    private func noon() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = eastern
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: 12))!
    }

    // MARK: - The Mac chooses the look

    /// Lodestar never changes between light and dark on its own: at every
    /// hour of a day, in both of the Mac's looks, the application's look and
    /// every window's is the Mac's.
    func testLodestarNeverLeavesTheMacsLook() {
        let controller = EyeComfortController.shared
        controller.zone = { self.eastern }
        controller.place = { _ in self.newYork }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = eastern
        for look in GalleryLook.all {
            look.apply()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 60), styleMask: [.borderless],
                                  backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            for hour in 0..<24 {
                let instant = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: hour, minute: 30))!
                controller.now = { instant }
                controller.configure(enabled: true)
                controller.reevaluate()
                let dark = look == .night
                XCTAssertEqual(Tone.systemDark, dark, "\(look.name) at \(hour):30 is still the Mac's look")
                XCTAssertEqual(NSApplication.shared.appearance?.name, look.appearance, "the application's own look is untouched")
                XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), look.appearance,
                               "a window with no look of its own follows the Mac")
                XCTAssertEqual(BarTheme.palette.isDark, dark, "\(look.name) at \(hour):30: the palette is the Mac's look")
                XCTAssertEqual(BarTheme.steps(for: window.effectiveAppearance).isDark, dark)
            }
        }
        // The two files that run it never set an appearance.
        for name in ["EyeComfortController.swift", "Recess.swift"] {
            let text = DesignDriftTests.code((try? String(contentsOf: DesignDriftTests.appSources.appendingPathComponent(name),
                                                             encoding: .utf8)) ?? "")
            XCTAssertFalse(text.contains(".appearance ="), "\(name) never sets the look")
            XCTAssertFalse(text.contains("NSAppearance(named"), "\(name) never names one")
        }
    }

    /// At bedtime, by day, the light look is dimmer and is still the light look.
    func testBedtimeByDayIsTheLightLookDimmed() {
        GalleryLook.day.apply()
        let controller = EyeComfortController.shared
        controller.zone = { self.eastern }
        controller.place = { _ in self.newYork }
        controller.now = { self.night() }
        controller.configure(enabled: true)
        XCTAssertEqual(EyeComfortState.shared.level, 0.80, accuracy: 0.001)
        XCTAssertFalse(BarTheme.palette.isDark)
        XCTAssertLessThan(BarTheme.palette.pane.luminance, Palette.clay.pane.luminance)
    }

    // MARK: - The steps

    func testTheLevelIsWorkedOutEveryFiveMinutesAndOnWakeClockAndZoneChanges() {
        let controller = EyeComfortController.shared
        var instant = noon(), tz = eastern, place = newYork
        controller.now = { instant }
        controller.zone = { tz }
        controller.place = { _ in place }
        controller.configure(enabled: true)
        XCTAssertEqual(controller.watchingEvery, 300, "a step every five minutes")
        XCTAssertEqual(EyeComfortState.shared.level, 1)

        instant = night()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        spin()
        XCTAssertEqual(EyeComfortState.shared.level, 0.8, accuracy: 0.001, "on waking")

        instant = noon()
        NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
        spin()
        XCTAssertEqual(EyeComfortState.shared.level, 1, "on a clock change")

        instant = night()
        tz = TimeZone(identifier: "Asia/Tokyo")!
        place = Coordinate(latitude: 35.68, longitude: 139.65)
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        spin()
        XCTAssertEqual(EyeComfortState.shared.level, 1, "on a zone change: it is the next morning there")
    }

    func testTheSwitchFollowsTheConfig() {
        XCTAssertTrue(Config().eyeComfort, "on by default")
        let controller = EyeComfortController.shared
        controller.zone = { self.eastern }
        controller.place = { _ in self.newYork }
        controller.now = { self.night() }
        controller.configure(enabled: Config().eyeComfort)
        XCTAssertEqual(EyeComfortState.shared.level, 0.8, accuracy: 0.001)
        var config = Config()
        config.eyeComfort = false
        controller.configure(enabled: config.eyeComfort)
        XCTAssertEqual(EyeComfortState.shared.level, 1)
        XCTAssertEqual(BarTheme.palette, Palette.clay)
    }

    /// A level step repaints a surface that baked its colour into a layer
    /// the way a change of look does.
    func testALevelStepRepaintsASurface() throws {
        GalleryLook.day.apply()
        let size = NSSize(width: 160, height: 100)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        _ = Ceramic.installPane(in: root, cornerRadius: BarTheme.surfaceRadius)
        let tone = ToneView(fill: BarTheme.paneFill)
        tone.frame = NSRect(x: 60, y: 30, width: 40, height: 40)
        root.addSubview(tone)
        let window = GalleryHost.window(root, size: size, look: .day)
        func pixel(_ x: CGFloat, _ y: CGFloat) throws -> RGB {
            let rep = GalleryRender.bitmap(of: root)
            let scale = CGFloat(rep.pixelsWide) / rep.size.width
            let c = try XCTUnwrap(rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
            return RGB(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
        }
        let before = try pixel(20, 20), beforeTone = try pixel(80, 50)
        XCTAssertEqual(before.red, Palette.clay.pane.red, accuracy: 0.012)
        let controller = EyeComfortController.shared
        controller.zone = { self.eastern }
        controller.place = { _ in self.newYork }
        controller.now = { self.night() }
        controller.configure(enabled: true)
        let dimmed = EyeComfort.steps(Palette.clay, level: 0.8).pane
        let after = try pixel(20, 20), afterTone = try pixel(80, 50)
        XCTAssertEqual(after.red, dimmed.red, accuracy: 0.012, "the pane is the dimmed pane")
        XCTAssertEqual(afterTone.red, dimmed.red, accuracy: 0.012, "and so is a layer that baked its colour")
        XCTAssertLessThan(after.red, before.red)
        XCTAssertLessThan(afterTone.red, beforeTone.red)
        withExtendedLifetime(window) {}
    }

    // MARK: - Receding

    private func label(_ text: String, in root: NSView) -> NSTextField {
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.stringValue == text { return field }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        return find(root)!
    }

    private func symbolTint(in root: NSView) -> NSColor {
        func find(_ view: NSView) -> NSColor? {
            if let image = view as? NSImageView, let tint = image.contentTintColor { return tint }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        return find(root)!
    }

    private let scroll = ModePill.State(mode: .scroll, app: "Notes", icon: nil, listening: false, text: nil)

    /// After twenty seconds alone the pill's ink moves to 7 to 1 on its
    /// pane and its quiet ink to 4.5, the two keeping their order, in both
    /// looks and at every level; one touch, a key, or a new state brings
    /// them back at once.
    func testThePillRecedesToItsFloorsAndComesBackAtOnce() {
        XCTAssertEqual(Receding.idleSeconds, 20)
        for level in [1.0, 0.96, 0.88, 0.80] {
            for look in GalleryLook.all {
                look.apply()
                on(level)
                let pill = ModePill()
                pill.recess.idle = 0
                pill.show(scroll)
                let full = BarTheme.steps(for: NSAppearance(named: look.appearance)!)
                let mode = label("Scroll", in: pill.drawnRoot), app = label("Notes", in: pill.drawnRoot)
                func inks() -> (ink: RGB, quiet: RGB, symbol: RGB) {
                    (rgb(mode.textColor ?? .clear, in: look.appearance), rgb(app.textColor ?? .clear, in: look.appearance),
                     rgb(symbolTint(in: pill.drawnRoot), in: look.appearance))
                }
                var now = inks()
                same(now.ink, full.ink, "\(look.name) \(level): full ink at first")
                same(now.quiet, full.quietInk, "quiet")
                same(now.symbol, full.ink, "the symbol takes the ink")

                pill.recess.idled()
                XCTAssertTrue(pill.recess.receded, "\(look.name) \(level)")
                now = inks()
                XCTAssertEqual(contrast(now.ink, full.pane), 7, accuracy: 0.01, "\(look.name) \(level): ink to 7")
                XCTAssertEqual(contrast(now.quiet, full.pane), 4.5, accuracy: 0.01, "quiet ink to 4.5")
                XCTAssertGreaterThanOrEqual(contrast(now.quiet, full.pane), 4.5, "never under the floor")
                XCTAssertGreaterThan(contrast(now.ink, full.pane), contrast(now.quiet, full.pane), "they keep their order")
                same(now.symbol, now.ink, "the symbol recedes with the ink")

                pill.show(.init(mode: .scroll, app: "Notes", icon: nil, listening: false, text: "word"))
                XCTAssertFalse(pill.recess.receded, "a change of state brings it back at once")
                XCTAssertEqual(rgb(label("word", in: pill.drawnRoot).textColor ?? .clear, in: look.appearance).luminance,
                               full.ink.luminance, accuracy: 1e-6)
                pill.recess.idled()
                XCTAssertTrue(pill.recess.receded)
                pill.recess.touch()
                XCTAssertFalse(pill.recess.receded, "a touch of the pointer or the keys sheet")
                same(rgb(label("word", in: pill.drawnRoot).textColor ?? .clear, in: look.appearance), full.ink, "full again")
                pill.hide()
            }
        }
    }

    func testAKeyBringsTheRecededPillBackAndAHoverDoesToo() {
        on(0.88)
        let pill = ModePill()
        pill.recess.idle = 0
        pill.show(scroll)
        pill.recess.idled()
        XCTAssertTrue(pill.recess.receded)
        pill.recess.idle = 60  // so the count that starts again does not run out inside the test
        Attention.key()
        spin()
        XCTAssertFalse(pill.recess.receded, "a key anywhere Lodestar listens")

        pill.recess.idle = 0
        pill.recess.idled()
        XCTAssertTrue(pill.recess.receded)
        pill.recess.idle = 60
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        let hover = RecessHover(view, recess: pill.recess)
        let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        hover.mouseEntered(with: event)
        XCTAssertFalse(pill.recess.receded, "the pointer coming onto it")
        pill.hide()
    }

    /// A surface left alone does recede by itself: the count runs, a key
    /// pressed meanwhile starts it again, and the switch turning off brings
    /// it back.
    func testALeftAlonePillRecedesByItselfUnlessAKeyWasPressed() {
        on(0.88)
        let pill = ModePill()
        // The count is driven, not waited for: `idled()` is what its timer
        // calls, and what it decides is read off the clock against `idle`,
        // so a window is as long as `idle` says (a wall clock with 30 ms to
        // spare failed on a runner twice as slow as a desk).
        pill.recess.idle = 60
        pill.show(scroll)
        // A key at some moment inside the window puts the count back...
        Attention.key(at: Date())
        pill.recess.idled()
        XCTAssertFalse(pill.recess.receded, "a key inside the window puts the count back")
        // ...and with nothing since for the whole window, it recedes.
        pill.recess.idle = 0
        pill.recess.idled()
        XCTAssertTrue(pill.recess.receded, "left alone for the whole window")
        EyeComfortState.shared.set(enabled: false, level: 1)
        NotificationCenter.default.post(name: .eyeComfortDidChange, object: nil)
        spin()
        XCTAssertFalse(pill.recess.receded, "off puts it back at once")
        pill.hide()
    }

    func testIncreaseContrastKeepsEverythingAtFullInk() {
        on(0.88)
        Accessibility.increaseContrast = { true }
        let pill = ModePill()
        pill.recess.idle = 0
        pill.show(scroll)
        pill.recess.idled()
        XCTAssertFalse(pill.recess.receded, "a Mac asked for more contrast never recedes")
        pill.hide()
    }

    /// The meeting's chip: ink to 7, quiet ink to 4.5, back at once when
    /// the meeting is due, and a lit stub never recedes.
    func testTheChipRecedesAndTheDueMeetingBringsItBackAndALitOneNeverRecedes() throws {
        on(0.88)
        // Standing before it returns: the staged calendar read empties a
        // chip that has to wait for the run loop.
        let controller = MeetingController.staged(startingIn: 4 * 60)
        defer { controller.unstage() }
        let root = controller.chipRoot
        XCTAssertEqual(controller.chipWords.first(where: { $0 == "Product sync" }), "Product sync")
        let full = BarTheme.palette
        let title = label("Product sync", in: root), detail = label("Zoom · 6 people", in: root)
        func inks() -> (ink: RGB, quiet: RGB) {
            (rgb(title.textColor ?? .clear, in: .aqua), rgb(detail.textColor ?? .clear, in: .aqua))
        }
        same(inks().ink, full.ink, "full ink")
        same(inks().quiet, full.quietInk, "full quiet ink")
        XCTAssertFalse(controller.chipLit)

        controller.recess.idle = 0
        controller.recess.idled()
        XCTAssertTrue(controller.recess.receded)
        var now = inks()
        XCTAssertEqual(contrast(now.ink, full.pane), 7, accuracy: 0.01)
        XCTAssertEqual(contrast(now.quiet, full.pane), 4.5, accuracy: 0.01)
        XCTAssertGreaterThan(contrast(now.ink, full.pane), contrast(now.quiet, full.pane))

        // The meeting comes due: the chip is back at once, and lit.
        let start = try XCTUnwrap(controller.current).occurrence.start
        controller.advanceCountdown(now: start.addingTimeInterval(-30))
        XCTAssertTrue(controller.chipLit)
        XCTAssertFalse(controller.recess.receded, "a meeting becoming due is attention")
        controller.recess.idled()
        XCTAssertFalse(controller.recess.receded, "a lit chip never recedes")
        now = inks()
        same(now.ink, full.ink, "full ink")
    }
}
