import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The meeting's stub (design/15-meeting-stub.md): three phases, one width
/// for the chip's life, and a chord that is lit in every phase.
final class MeetingStubTests: XCTestCase {
    typealias RGB = Readability.RGB

    override func setUp() {
        EyeComfortState.shared.set(enabled: true, level: 1)
        GalleryLook.day.apply()
    }

    override func tearDown() {
        EyeComfortState.shared.set(enabled: false, level: 1)
        GalleryLook.reset()
        Accessibility.reset()
    }

    // MARK: - Model

    private func occurrence(startsIn seconds: TimeInterval, lasts minutes: Double = 120) -> Meetings.Occurrence {
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000 + seconds)
        return Meetings.Occurrence(
            eventID: "stub", title: "Standup", start: start,
            end: start.addingTimeInterval(minutes * 60),
            link: Meetings.Link(provider: .zoom, url: "https://zoom.us/j/123456789"),
            calendar: "Work", account: "Google")
    }

    /// What the stub says and which phase it is in, `seconds` from the
    /// start (negative before it), with the chip's lead as given.
    private func stub(_ seconds: TimeInterval, lead: Int)
        -> (number: String, unit: String?, lit: Bool, quiet: Bool)? {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        guard let candidate = Meetings.candidate(
            occurrences: [occurrence(startsIn: -seconds)], now: now, leadMinutes: lead, spent: []) else { return nil }
        return MeetingController.stub(for: candidate.phase)
    }

    private func expect(_ seconds: TimeInterval, lead: Int, _ number: String, _ unit: String?,
                        lit: Bool, quiet: Bool, _ message: String,
                        file: StaticString = #filePath, line: UInt = #line) {
        guard let said = stub(seconds, lead: lead) else {
            return XCTFail("no chip \(message)", file: file, line: line)
        }
        XCTAssertEqual(said.number, number, message, file: file, line: line)
        XCTAssertEqual(said.unit, unit, message, file: file, line: line)
        XCTAssertEqual(said.lit, lit, "\(message): the stub is orange only in the alert", file: file, line: line)
        XCTAssertEqual(said.quiet, quiet, "\(message): receded only once quiet", file: file, line: line)
    }

    func testThePhaseTheLegendAndTheRecedingAcrossTheWindow() {
        // Normal: from the lead to 60 s before, on the chip's own surface.
        expect(-5 * 60, lead: 5, "5", "min", lit: false, quiet: false, "lead 5 min, at the lead")
        expect(-120 * 60, lead: 120, "120", "min", lit: false, quiet: false, "lead 120 min, at the lead")
        expect(-61, lead: 5, "1", "min", lit: false, quiet: false, "61 s before is still a minute")
        // Alert: the last minute and 90 s of the meeting, orange.
        expect(-60, lead: 5, "60", "sec", lit: true, quiet: false, "60 s before")
        expect(-1, lead: 5, "1", "sec", lit: true, quiet: false, "1 s before")
        expect(0, lead: 5, "Now", nil, lit: true, quiet: false, "at the start")
        expect(89, lead: 5, "Now", nil, lit: true, quiet: false, "89 s after is still the alert")
        // Quiet: from 90 s after, until the meeting ends.
        expect(90, lead: 5, "1", "min ago", lit: false, quiet: true, "90 s after")
        expect(91, lead: 5, "1", "min ago", lit: false, quiet: true, "91 s after")
        expect(40 * 60, lead: 5, "40", "min ago", lit: false, quiet: true, "40 min after")
        XCTAssertNil(stub(130 * 60, lead: 5), "the chip is gone when the meeting ends")
    }

    func testTheQuietPhaseSaysHowLongAgoItStarted() {
        XCTAssertEqual(MeetingController.sentence(title: "Standup", phase: .inProgress(minutes: 4)),
                       "Standup started four minutes ago")
        XCTAssertEqual(MeetingController.sentence(title: "Standup", phase: .inProgress(minutes: 1)),
                       "Standup started one minute ago")
    }

    // MARK: - The chip, drawn

    /// The chip, standing at once.
    private func standing(startingIn offset: TimeInterval) throws -> MeetingController {
        let controller = MeetingController.staged(startingIn: offset)
        XCTAssertNotNil(controller.current, "the staged chip stands")
        return controller
    }

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var out: [T] = []
        for sub in view.subviews {
            if let hit = sub as? T { out.append(hit) }
            out += all(type, in: sub)
        }
        return out
    }

    private func stubFace(of controller: MeetingController) throws -> StubFace {
        try XCTUnwrap(all(StubFace.self, in: controller.chipRoot).first)
    }

    private func rgb(_ color: NSColor, in name: NSAppearance.Name = .aqua) -> RGB {
        var out = RGB(red: 0, green: 0, blue: 0)
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB)!
            out = RGB(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent))
        }
        return out
    }

    /// Seconds from the start for each legend of one occurrence.
    private let legends: [(name: String, seconds: TimeInterval)] = [
        ("MIN", -4 * 60), ("SEC", -45), ("Now", 0), ("MIN AGO", 3 * 60),
    ]

    func testEveryLegendFitsTheStubAndNothingMovesBetweenThem() throws {
        // Measured on their own, in their fonts, in both looks.
        for night in [false, true] {
            let ink: [CGFloat] = [
                BarTheme.width(of: "88", in: .figure, tabular: true, night: night),
                BarTheme.width(of: "MIN", in: .key, night: night),
                BarTheme.width(of: "SEC", in: .key, night: night),
                BarTheme.width(of: "Now", in: .emphasis, night: night),
                BarTheme.width(of: "MIN AGO", in: .key, night: night),
            ]
            for width in ink {
                XCTAssertLessThanOrEqual(width + Grid.close * 2, MeetingController.stubWidth,
                                         "8 each side of the widest legend, in the \(night ? "night" : "day") look")
            }
        }
        XCTAssertEqual(MeetingController.stubWidth,
                       ceil(BarTheme.width(of: "MIN AGO", in: .key, night: true)) + Grid.close * 2,
                       "the widest legend is MIN AGO")

        let controller = try standing(startingIn: 4 * 60)
        defer { controller.unstage() }
        let start = try XCTUnwrap(controller.current).occurrence.start
        var frames: [NSRect] = [], chips: [NSSize] = [], fitting: [CGFloat] = []
        for (name, seconds) in legends {
            controller.advanceCountdown(now: start.addingTimeInterval(seconds))
            let face = try stubFace(of: controller)
            let fields = all(NSTextField.self, in: face).filter { !$0.stringValue.isEmpty }
            XCTAssertFalse(fields.isEmpty, name)
            for field in fields {
                let frame = face.convert(field.bounds, from: field)
                XCTAssertGreaterThanOrEqual(frame.minX, 0, "\(name): \(field.stringValue) starts inside the stub")
                XCTAssertLessThanOrEqual(frame.maxX, face.bounds.maxX, "\(name): \(field.stringValue) ends inside the stub")
                let ink = field.attributedStringValue.size().width
                XCTAssertLessThanOrEqual(ink + Grid.close * 2, face.bounds.width + 0.5,
                                         "\(name): \(field.stringValue) has 8 each side")
            }
            frames.append(face.frame)
            chips.append(controller.chipSize)
            fitting.append(controller.chipRoot.fittingSize.width)
        }
        XCTAssertEqual(Set(frames.map { "\($0)" }).count, 1, "the stub's frame is the same in every legend")
        XCTAssertEqual(Set(chips.map { "\($0)" }).count, 1, "the chip's size is the same in every legend")
        XCTAssertEqual(Set(fitting).count, 1, "and so is the width the chip asks for")
        XCTAssertEqual(frames[0].width, MeetingController.stubWidth)
        XCTAssertEqual(frames[0].width, 74, "the stub is as wide as it was on main, so the chip does not grow")
    }

    private func pixel(of face: StubFace, atX x: CGFloat, y: CGFloat) throws -> NSColor {
        let rep = try XCTUnwrap(face.bitmapImageRepForCachingDisplay(in: face.bounds))
        face.cacheDisplay(in: face.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / face.bounds.width
        return try XCTUnwrap(rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
    }

    /// The colour a label is drawn in: the run's own, where it is attributed.
    private func inkOf(_ field: NSTextField) -> NSColor {
        let text = field.attributedStringValue
        if text.length > 0, let color = text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor {
            return color
        }
        return field.textColor ?? .clear
    }

    private func isOrange(_ color: NSColor) -> Bool {
        color.alphaComponent > 0.5 && color.redComponent > 0.6 && color.greenComponent < 0.5 && color.blueComponent < 0.3
    }

    func testTheStubIsOrangeOnlyInTheAlertAndTheChordIsLitUntilItIsQuiet() throws {
        let controller = try standing(startingIn: 4 * 60)
        defer { controller.unstage() }
        let start = try XCTUnwrap(controller.current).occurrence.start
        let edge = try XCTUnwrap(controller.chipRoot.subviews.first { $0 is PaneEdge } as? PaneEdge)
        let accent = rgb(BarTheme.accent)

        func check(_ name: String, _ seconds: TimeInterval, orange: Bool) throws {
            controller.advanceCountdown(now: start.addingTimeInterval(seconds))
            let face = try stubFace(of: controller)
            // A point inside the stub, clear of the text, near its trailing corner.
            let sample = try pixel(of: face, atX: face.bounds.maxX - 4, y: 4)
            XCTAssertEqual(isOrange(sample), orange, "\(name): the stub \(orange ? "is" : "has no") orange")
            XCTAssertEqual(face.lit, orange, name)
            XCTAssertEqual(edge.litShape != nil, orange, "\(name): the lit rim shows only where the stub is orange")
            for field in all(NSTextField.self, in: face) where !field.stringValue.isEmpty {
                let ink = rgb(inkOf(field))
                let onAccent = rgb(BarTheme.onAccent)
                if orange {
                    XCTAssertEqual(ink.red, onAccent.red, accuracy: 0.01, "\(name): ink on orange")
                } else {
                    XCTAssertFalse(abs(ink.red - accent.red) < 0.02 && abs(ink.green - accent.green) < 0.02,
                                   "\(name): \(field.stringValue) is not orange")
                }
            }
            let chords = all(KeyStrokes.self, in: controller.chipRoot)
            XCTAssertEqual(chords.count, 1, name)
            XCTAssertEqual(chords.first?.lit, orange || name == "normal",
                           "\(name): the chord is lit in the normal phase and the alert, and rests in quiet")
            XCTAssertEqual(chords.first?.caps.allSatisfy { $0.state == .resting }, name == "quiet", name)
        }
        try check("normal", -4 * 60, orange: false)
        XCTAssertFalse(controller.recess.receded, "normal is full ink")
        try check("alert, seconds", -45, orange: true)
        try check("alert, now", 0, orange: true)
        XCTAssertFalse(controller.recess.receded, "the alert never recedes")
        try check("quiet", 3 * 60, orange: false)
    }

    func testQuietDrawsTheChipRecededAtOnce() throws {
        let controller = try standing(startingIn: 0)
        defer { controller.unstage() }
        let start = try XCTUnwrap(controller.current).occurrence.start
        XCTAssertFalse(controller.recess.receded, "the alert is at full ink")

        controller.advanceCountdown(now: start.addingTimeInterval(91))
        XCTAssertTrue(controller.recess.receded, "quiet draws receded the moment it begins, not after twenty seconds")

        let face = try stubFace(of: controller)
        let full = BarTheme.palette
        let numberField = try XCTUnwrap(all(NSTextField.self, in: face).first { $0.stringValue == "1" })
        let unitField = try XCTUnwrap(all(NSTextField.self, in: face).first { $0.stringValue == "MIN AGO" })
        let count = rgb(inkOf(numberField)), unit = rgb(inkOf(unitField))
        XCTAssertEqual(Readability.contrast(count.luminance, full.pane.luminance), 4.5, accuracy: 0.01,
                       "the count is in the receded quiet ink")
        XCTAssertEqual(Readability.contrast(unit.luminance, full.pane.luminance), 4.5, accuracy: 0.01,
                       "and so is the unit")

        // The chord rests, and it recedes with the rest of the chip: its
        // letter at the receded ink and its ×2 at the receded quiet ink.
        let chord = try XCTUnwrap(all(KeyStrokes.self, in: controller.chipRoot).first)
        XCTAssertFalse(chord.lit)
        let legend = rgb(try XCTUnwrap(chord.caps.first).legendColor)
        XCTAssertEqual(Readability.contrast(legend.luminance, full.pane.luminance), 7, accuracy: 0.01,
                       "the resting chord's letter is in the receded ink")
        let times = try XCTUnwrap(all(KeyTimes.self, in: chord).first)
        XCTAssertEqual(Readability.contrast(rgb(try XCTUnwrap(times.ink)).luminance, full.pane.luminance), 4.5,
                       accuracy: 0.01, "and its ×2 in the receded quiet ink")

        // A later minute ticking over is not attention, so it stays receded.
        controller.advanceCountdown(now: start.addingTimeInterval(3 * 60 + 1))
        XCTAssertTrue(controller.recess.receded)
        // The pointer brings it back at once.
        controller.recess.touch()
        XCTAssertFalse(controller.recess.receded)
        let woken = try XCTUnwrap(all(KeyStrokes.self, in: controller.chipRoot).first)
        let wokenLegend = rgb(try XCTUnwrap(woken.caps.first).legendColor)
        XCTAssertEqual(Readability.contrast(wokenLegend.luminance, full.pane.luminance),
                       Readability.contrast(full.ink.luminance, full.pane.luminance), accuracy: 0.01,
                       "back at full ink, the chord's letter with it")
    }

    func testATypedKeyDoesNotWakeTheQuietChipButAHoverDoes() throws {
        let controller = try standing(startingIn: 0)
        defer { controller.unstage() }
        let start = try XCTUnwrap(controller.current).occurrence.start
        controller.advanceCountdown(now: start.addingTimeInterval(4 * 60))
        XCTAssertTrue(controller.chipQuiet)
        XCTAssertTrue(controller.recess.receded)
        controller.recess.handKeyed()
        XCTAssertTrue(controller.recess.receded, "typing in the meeting does not wake the quiet chip")
        // A hover brings it back, and twenty seconds alone recede it again.
        controller.recess.touch()
        XCTAssertFalse(controller.recess.receded, "a hover wakes it")
        controller.recess.idle = 0
        controller.recess.idled()
        XCTAssertTrue(controller.recess.receded, "left alone it recedes again")
        // Outside the quiet phase a key still wakes a receded chip (contract 6).
        controller.advanceCountdown(now: start.addingTimeInterval(-4 * 60))
        XCTAssertFalse(controller.chipQuiet)
        controller.recess.idled()
        XCTAssertTrue(controller.recess.receded)
        controller.recess.handKeyed()
        XCTAssertFalse(controller.recess.receded, "in the normal phase a key wakes it")
    }

    func testTheQuietChipReadsAsStartedMinutesAgo() throws {
        let controller = try standing(startingIn: 0)
        defer { controller.unstage() }
        let start = try XCTUnwrap(controller.current).occurrence.start
        controller.advanceCountdown(now: start.addingTimeInterval(4 * 60 + 5))
        let said = controller.chipRoot.accessibilityLabel() ?? ""
        XCTAssertTrue(said.contains("started four minutes ago"), said)
    }
}
