import AppKit
import LodestarCore
import XCTest
@testable import lodestar

/// Eye comfort in the app: the theme reads the level, bedtime puts the
/// application in the night look and the morning takes it out, the type's
/// weight follows the look, and the pill and the meeting's chip recede when
/// they are left alone. The pure curve is held in LodestarCoreTests; this
/// is what the app does with it.
final class EyeComfortAppTests: XCTestCase {
    private let aqua = NSAppearance(named: .aqua)!
    private let darkAqua = NSAppearance(named: .darkAqua)!
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let place = Coordinate(latitude: 40.7128, longitude: -74.0060)

    override func tearDown() {
        let controller = EyeComfortController.shared
        controller.configure(enabled: false)
        controller.now = Date.init
        controller.zone = { .current }
        controller.place = EyeComfortController.estimatedPlace
        controller.restingAppearance = nil
        NSApplication.shared.appearance = nil
        // The drawing appearance the others read is the application's again.
        Ceramic.followSystemAppearance()
        super.tearDown()
    }

    /// The Mac is light, whatever the one running the tests is.
    override func setUp() {
        super.setUp()
        EyeComfortController.shared.restingAppearance = aqua
        NSApplication.shared.appearance = aqua
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func standing(at instant: Date) -> EyeComfortController {
        let controller = EyeComfortController.shared
        controller.now = { instant }
        controller.zone = { self.newYork }
        controller.place = { _ in self.place }
        controller.configure(enabled: true)
        return controller
    }

    private func rgb(_ color: NSColor, in appearance: NSAppearance) -> Readability.RGB {
        var out = Readability.RGB(red: 0, green: 0, blue: 0)
        appearance.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            out = Readability.RGB(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
        }
        return out
    }

    private func contrast(_ a: Readability.RGB, _ b: Readability.RGB) -> Double { Readability.contrast(a.luminance, b.luminance) }

    // MARK: - The theme reads the level

    func testWithTheSwitchOffTheThemeIsExactlyThePalettes() {
        XCTAssertFalse(EyeComfortState.shared.enabled)
        XCTAssertEqual(BarTheme.steps(for: aqua), Palette.clay)
        XCTAssertEqual(BarTheme.steps(for: darkAqua), Palette.night)
        XCTAssertEqual(rgb(BarTheme.internationalOrange, in: aqua), Readability.orangeOnPaper)
        XCTAssertEqual(rgb(BarTheme.internationalOrange, in: darkAqua).red, 1, accuracy: 0.002)
    }

    func testAnEveningEasesEverySurfaceThroughTheOnePlaceTheStepsAreResolved() {
        let times = EyeComfort.times(onDayOf: date(2026, 10, 21, 12), at: place, in: newYork)
        let controller = standing(at: times.sunset.addingTimeInterval(3 * 3_600 + 60))
        XCTAssertEqual(EyeComfortState.shared.level.lightnessCut, 0.12, accuracy: 0.001)
        let clay = BarTheme.steps(for: aqua)
        XCTAssertEqual(clay.pane.lightness, Palette.clay.pane.lightness * 0.88, accuracy: 0.004)
        XCTAssertNotEqual(clay, Palette.clay)
        XCTAssertEqual(rgb(BarTheme.dynamicGround(), in: aqua).lightness, clay.pane.lightness, accuracy: 0.002,
                       "a dynamic colour resolves through the same steps")
        XCTAssertEqual(rgb(BarTheme.keyFace, in: aqua), clay.raised)
        XCTAssertLessThan(rgb(BarTheme.internationalOrange, in: aqua).oklab.chroma,
                          Readability.orangeOnPaper.oklab.chroma * 0.8, "the accent is calmer")
        XCTAssertGreaterThanOrEqual(contrast(rgb(BarTheme.ink, in: aqua), clay.pane), 7)
        XCTAssertGreaterThanOrEqual(contrast(rgb(BarTheme.secondaryColor, in: aqua), clay.pane), 4.5)
        // The slab is the other look's ground: it eases too, and its ink holds.
        XCTAssertGreaterThanOrEqual(contrast(rgb(BarTheme.ink, in: darkAqua), rgb(BarTheme.slabFill, in: darkAqua)), 7)
        _ = controller
    }

    func testTheSwitchBackOffPutsTheMorningBack() {
        let times = EyeComfort.times(onDayOf: date(2026, 10, 21, 12), at: place, in: newYork)
        let controller = standing(at: times.sunset.addingTimeInterval(2 * 3_600))
        XCTAssertNotEqual(BarTheme.steps(for: aqua), Palette.clay)
        controller.configure(enabled: false)
        XCTAssertEqual(BarTheme.steps(for: aqua), Palette.clay)
        XCTAssertEqual(BarTheme.steps(for: darkAqua), Palette.night)
        XCTAssertEqual(NSApplication.shared.appearance?.name, .aqua)
    }

    // MARK: - Bedtime and the morning

    func testBedtimeTakesTheApplicationToTheNightAndTheMorningGivesItBack() {
        let times = EyeComfort.times(onDayOf: date(2026, 10, 21, 12), at: place, in: newYork)
        let controller = standing(at: times.bedtime.addingTimeInterval(-60))
        XCTAssertEqual(NSApplication.shared.appearance?.name, .aqua, "not yet: the Mac's own")
        controller.now = { times.bedtime.addingTimeInterval(60) }
        controller.reevaluate()
        XCTAssertEqual(NSApplication.shared.appearance?.name, .darkAqua, "bedtime: the dark look, whatever the Mac shows")
        XCTAssertTrue(Tone.systemDark)
        let wake = EyeComfort.times(onDayOf: date(2026, 10, 22, 12), at: place, in: newYork).sunrise
        controller.now = { wake.addingTimeInterval(60) }
        controller.reevaluate()
        XCTAssertEqual(NSApplication.shared.appearance?.name, .aqua, "the sun is up: back to the Mac's own look")
    }

    func testTheSwitchOffAtBedtimeGivesTheLookBackAtOnce() {
        let times = EyeComfort.times(onDayOf: date(2026, 10, 21, 12), at: place, in: newYork)
        let controller = standing(at: times.bedtime.addingTimeInterval(60))
        XCTAssertEqual(NSApplication.shared.appearance?.name, .darkAqua)
        controller.configure(enabled: false)
        XCTAssertEqual(NSApplication.shared.appearance?.name, .aqua)
    }

    func testSurfacesStandingAtBedtimeAreTheNightLookAndTheSlabIsStillTheOpposite() {
        let times = EyeComfort.times(onDayOf: date(2026, 10, 21, 12), at: place, in: newYork)
        _ = standing(at: times.bedtime.addingTimeInterval(60))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let pane = ToneView(fill: BarTheme.dynamicGround())
        window.contentView = pane
        XCTAssertEqual(pane.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), .darkAqua,
                       "a window with no look of its own takes the application's")
        let night = BarTheme.steps(for: pane.effectiveAppearance)
        XCTAssertLessThan(night.pane.lightness, 0.2)
        let wearing = BarTheme.slabLook(over: pane.effectiveAppearance)
        XCTAssertEqual(wearing.bestMatch(from: [.darkAqua, .aqua]), .aqua, "the chosen row is the other look")
    }

    // MARK: - The type follows the look

    func testTypeStepsHeavierAtNightForSurfacesAlreadyBuiltAndBackAgain() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: window.contentView!.bounds)
        window.contentView = host
        let body = NSTextField(labelWithString: "Body")
        body.font = NSFont.systemFont(ofSize: BarTheme.Scale.body, weight: .regular)
        let countdown = NSTextField(labelWithString: "4m")
        countdown.font = BarTheme.countdownFont
        let meta = NSTextField(labelWithString: "meta")
        meta.font = BarTheme.chipFont
        let mono = NSTextField(labelWithString: "mono")
        mono.font = NSFont.monospacedSystemFont(ofSize: BarTheme.Scale.body, weight: .regular)
        let rich = NSTextField(labelWithAttributedString: NSAttributedString(
            string: "Rich", attributes: [.font: NSFont.systemFont(ofSize: BarTheme.Scale.title, weight: .semibold)]))
        for view in [body, countdown, meta, mono, rich] { host.addSubview(view) }

        func weight(_ font: NSFont?) -> CGFloat {
            (font?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight] as? CGFloat ?? .nan
        }
        let countdownBefore = weight(countdown.font), metaBefore = weight(meta.font), monoBefore = weight(mono.font)

        window.orderBack(nil)
        TypeWeights.follow(dark: true)
        XCTAssertEqual(weight(body.font), NSFont.Weight.medium.rawValue, accuracy: 0.01, "regular, one step heavier")
        XCTAssertEqual(weight(rich.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont),
                       NSFont.Weight.bold.rawValue, accuracy: 0.01, "an attributed title, run by run")
        XCTAssertEqual(rich.attributedStringValue.string, "Rich")
        XCTAssertEqual(weight(countdown.font), countdownBefore, "tabular figures are not the theme's to step")
        XCTAssertEqual(weight(meta.font), metaBefore, "a size the theme does not step")
        XCTAssertEqual(weight(mono.font), monoBefore, "the hand's face")

        TypeWeights.follow(dark: false)
        XCTAssertEqual(weight(body.font), NSFont.Weight.regular.rawValue, accuracy: 0.01)
        XCTAssertEqual(weight(rich.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont),
                       NSFont.Weight.semibold.rawValue, accuracy: 0.01)
        window.close()
    }

    func testTheBedtimeSwitchSetsTheTypeOfSurfacesAlreadyStandingInTheNightWeight() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: window.contentView!.bounds)
        window.contentView = host
        let label = NSTextField(labelWithString: "Standing")
        label.font = BarTheme.face(BarTheme.Scale.body)
        host.addSubview(label)
        window.orderBack(nil)
        defer { window.close() }
        let day = label.font!

        let times = EyeComfort.times(onDayOf: date(2026, 10, 21, 12), at: place, in: newYork)
        let controller = standing(at: times.sunset.addingTimeInterval(3_600))
        XCTAssertEqual(label.font, day, "the evening alone does not touch the type")
        controller.now = { times.bedtime.addingTimeInterval(60) }
        controller.reevaluate()
        XCTAssertNotEqual(label.font, day, "bedtime: the night look, and the weight with it")
        XCTAssertEqual(label.font, NSFont.systemFont(ofSize: BarTheme.Scale.body, weight: .medium))
        controller.configure(enabled: false)
        XCTAssertEqual(label.font, NSFont.systemFont(ofSize: BarTheme.Scale.body, weight: .regular), "and back")
    }
}

/// Receding: the pill and the meeting's chip lower their ink when left alone
/// and return it the instant they are used.
final class RecessTests: XCTestCase {
    private let aqua = NSAppearance(named: .aqua)!
    private let darkAqua = NSAppearance(named: .darkAqua)!

    override func tearDown() {
        EyeComfortState.shared.set(enabled: false, level: .day)
        super.tearDown()
    }

    private func rgb(_ color: NSColor, in appearance: NSAppearance) -> Readability.RGB {
        var out = Readability.RGB(red: 0, green: 0, blue: 0)
        appearance.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            out = Readability.RGB(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
        }
        return out
    }

    private func contrast(_ a: Readability.RGB, _ b: Readability.RGB) -> Double { Readability.contrast(a.luminance, b.luminance) }

    func testAnIdleSurfaceRecedesAndTheTouchBringsItBackAtOnce() {
        EyeComfortState.shared.set(enabled: true, level: .day)
        let clock = RecessClock()
        var repaints = 0
        clock.onChange = { repaints += 1 }
        clock.touch()
        XCTAssertFalse(clock.receded)
        clock.idled()
        XCTAssertTrue(clock.receded)
        XCTAssertEqual(repaints, 1, "one repaint at the moment it recedes")
        clock.touch()
        XCTAssertFalse(clock.receded, "instantly, on a touch")
        XCTAssertEqual(repaints, 2)
        clock.touch()
        XCTAssertEqual(repaints, 2, "a touch on a surface at full ink repaints nothing")
    }

    func testTheClockRunsOutAfterTheIdleWindowAndNotBefore() {
        EyeComfortState.shared.set(enabled: true, level: .day)
        let clock = RecessClock()
        clock.idle = 0.15
        let receded = expectation(description: "recedes")
        clock.onChange = { if clock.receded { receded.fulfill() } }
        clock.touch()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertFalse(clock.receded, "not yet")
        clock.touch()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertFalse(clock.receded, "a touch begins the count again")
        wait(for: [receded], timeout: 2)
        XCTAssertEqual(Receding.idleSeconds, 20)
        clock.stop()
    }

    func testItNeverRecedesWithTheSwitchOffOrAskingForTheHand() {
        let clock = RecessClock()
        clock.touch()
        clock.idled()
        XCTAssertFalse(clock.receded, "off: everything as today")
        EyeComfortState.shared.set(enabled: true, level: .day)
        clock.mayRecede = { false }
        clock.touch()
        clock.idled()
        XCTAssertFalse(clock.receded, "a lit countdown never recedes")
        clock.mayRecede = { true }
        clock.idled()
        XCTAssertTrue(clock.receded)
        EyeComfortState.shared.set(enabled: false, level: .day)
        NotificationCenter.default.post(name: .eyeComfortDidChange, object: nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertFalse(clock.receded, "turning the switch off puts the ink back")
        clock.stop()
    }

    func testARecededInkIsNearTheFloorNeverUnderItAtAnyPointOfTheEvening() {
        let clock = RecessClock()
        let ink = BarTheme.ink(recedingWith: clock), quiet = BarTheme.secondary(recedingWith: clock)
        for cut in stride(from: 0.0, through: 0.12, by: 0.01) {
            EyeComfortState.shared.set(enabled: true, level: .init(lightnessCut: cut))
            for appearance in [aqua, darkAqua] {
                let steps = BarTheme.steps(for: appearance)
                clock.touch()
                XCTAssertEqual(rgb(ink, in: appearance), steps.ink, "full when in use")
                clock.idled()
                XCTAssertTrue(clock.receded)
                for ground in [steps.pane, steps.raised] {
                    XCTAssertGreaterThanOrEqual(contrast(rgb(ink, in: appearance), ground), 4.5, "ink at \(cut)")
                    XCTAssertGreaterThanOrEqual(contrast(rgb(quiet, in: appearance), ground), 4.5, "quiet ink at \(cut)")
                }
                XCTAssertLessThan(contrast(rgb(ink, in: appearance), steps.pane), contrast(steps.ink, steps.pane) - 4,
                                  "and a long way down from full")
            }
        }
        clock.stop()
    }

    func testThePillRecedesWhenLeftAloneAndComesBackWhenItChangesOrIsHidden() {
        EyeComfortState.shared.set(enabled: true, level: .day)
        let pill = ModePill()
        let state = ModePill.State(mode: .scroll, app: "Slack", icon: nil, listening: false, text: nil)
        pill.show(state)
        XCTAssertFalse(pill.recess.receded)
        pill.recess.idled()
        XCTAssertTrue(pill.recess.receded, "twenty seconds of nothing")
        pill.show(state)
        XCTAssertFalse(pill.recess.receded, "keyed again, even to the same state")
        pill.recess.idled()
        pill.show(.init(mode: .scroll, app: "Slack", icon: nil, listening: false, text: "x"))
        XCTAssertFalse(pill.recess.receded, "a new state")
        pill.recess.idled()
        pill.hide()
        XCTAssertFalse(pill.recess.receded, "gone: full for the next time it stands")
    }

    func testTheMeetingChipRecedesUntilItsCountdownLights() {
        EyeComfortState.shared.set(enabled: true, level: .day)
        let controller = MeetingController()
        let start = Date().addingTimeInterval(4 * 60)
        let occurrence = Meetings.Occurrence(
            eventID: "t", title: "Product sync", start: start, end: start.addingTimeInterval(1_800),
            link: Meetings.Link(provider: .zoom, url: "https://zoom.us/j/1"), calendar: "Work", account: "Google", people: 3)
        controller.stageChip(.init(occurrence: occurrence, phase: .upcoming(minutes: 4)))
        XCTAssertFalse(controller.recessClock.receded)
        controller.recessClock.idled()
        XCTAssertTrue(controller.recessClock.receded, "four minutes away and left alone")
        func title() -> NSTextField? {
            func find(_ view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.stringValue == "Product sync" { return field }
                for sub in view.subviews { if let found = find(sub) { return found } }
                return nil
            }
            return find(controller.chipRoot)
        }
        let steps = BarTheme.steps(for: aqua)
        let receded = rgb(title()!.textColor!, in: aqua)
        XCTAssertLessThan(contrast(receded, steps.pane), contrast(steps.ink, steps.pane) - 4)
        XCTAssertGreaterThanOrEqual(contrast(receded, steps.pane), 4.5)
        XCTAssertGreaterThanOrEqual(contrast(rgb(controller.countdownKey!.label.textColor!, in: aqua), steps.pane), 4.5,
                                    "the quiet key's legend recedes too, to the floor")

        // A minute ticks over: not an interaction, the chip stays receded.
        controller.stageChip(.init(occurrence: occurrence, phase: .upcoming(minutes: 3)))
        XCTAssertTrue(controller.recessClock.receded, "a minute passing is not the hand")
        // The door: the countdown lights and the chip returns, and stays.
        controller.stageChip(.init(occurrence: occurrence, phase: .soon(seconds: 45)))
        XCTAssertFalse(controller.recessClock.receded, "lit at the door: instantly full")
        controller.recessClock.idled()
        XCTAssertFalse(controller.recessClock.receded, "a lit countdown asks for the hand and never recedes")
        XCTAssertEqual(rgb(title()!.textColor!, in: aqua), steps.ink)
    }
}
