import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// A search landing arms the row it lands on, and return works that row. The
/// arm belongs to the place the landing was in: the hand that moves on by
/// mouse (the back row, a place on the overview) has moved on from it, as
/// one that moves on by a key has.
final class SettingsArmedRowTests: XCTestCase {
    private struct Written: Equatable {
        var path: String
        var value: ConfigValue?
    }

    private let general = 0, switchPlace = 2, speak = 4, meetings = 7, observations = 9

    /// The window with nothing wired to the person's config: every write is
    /// kept here instead. It is never shown.
    private func window(_ written: @escaping (Written) -> Void) -> SettingsController {
        let settings = SettingsController()
        settings.apply = { path, value in written(Written(path: path, value: value)); return nil }
        settings.applyEntries = { removals, sets in
            for path in removals { written(Written(path: path.joined(separator: "."), value: nil)) }
            for (path, value) in sets { written(Written(path: path.joined(separator: "."), value: value)) }
            return nil
        }
        return settings
    }

    private func row(_ settings: SettingsController, place: Int, path: String) throws -> Int {
        try XCTUnwrap(settings.sectionsForTesting[place].rows.firstIndex { $0.path == path }, path)
    }

    /// A search landing on a row, with the main queue let run: the arm is
    /// set after the render that draws the landing.
    private func land(_ settings: SettingsController, place: Int, row: Int) {
        settings.renderForTesting(place: place)
        settings.landForTesting(place: place, row: row)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    }

    private func click(_ view: NSView) throws {
        var top = view
        while let up = top.superview { top = up }
        top.frame = NSRect(x: 0, y: 0, width: 1000, height: 680)
        top.layoutSubtreeIfNeeded()
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                         windowNumber: 0, context: nil, eventNumber: 0,
                                                         clickCount: 1, pressure: 1))
            type == .leftMouseDown ? view.mouseDown(with: event) : view.mouseUp(with: event)
        }
    }

    /// The row at the head of a place, whose esc key goes back.
    private func clickBack(_ settings: SettingsController) throws {
        let back = try XCTUnwrap(settings.viewsForTesting(of: Keycaps.CapGroup.self).first { group in
            (group.subviews.first as? KeyStrokes)?.caps.map(\.legend) == ["esc"]
        }, "the place has its back row")
        try click(back)
    }

    /// A place on the overview, clicked.
    private func clickPlace(_ settings: SettingsController, _ place: Int) throws {
        let name = settings.sectionsForTesting[place].name
        let tile = try XCTUnwrap(settings.viewsForTesting(of: NSView.self).first {
            $0.accessibilityLabel()?.hasPrefix(name + ",") == true && !$0.gestureRecognizers.isEmpty
        }, "\(name) is on the overview")
        let gesture = try XCTUnwrap(tile.gestureRecognizers.first as? NSClickGestureRecognizer)
        let target = try XCTUnwrap(gesture.target as? NSObject)
        _ = target.perform(try XCTUnwrap(gesture.action), with: gesture)
    }

    func testTheLandedRowIsWorkedByReturn() throws {
        var written: [Written] = []
        let settings = window { written.append($0) }
        settings.renderForTesting(place: general)
        let eye = try row(settings, place: general, path: "appearance.eye-comfort")
        land(settings, place: general, row: eye)
        settings.keyForTesting("return")
        XCTAssertEqual(written.map(\.path), ["appearance.eye-comfort"], "return works the row the search found")
        settings.close()
    }

    func testTheLandedRowIsWorkedOnceAndTheSecondReturnWorksNothing() throws {
        var written: [Written] = []
        let settings = window { written.append($0) }
        settings.renderForTesting(place: general)
        let eye = try row(settings, place: general, path: "appearance.eye-comfort")
        land(settings, place: general, row: eye)
        settings.keyForTesting("return")
        settings.keyForTesting("return")
        XCTAssertEqual(written.map(\.path), ["appearance.eye-comfort"], "return spends the landing")
        settings.close()
    }

    func testReturnInAnotherPlaceAfterAClickDoesNotWorkTheLandedRowsNumber() throws {
        var written: [Written] = []
        let settings = window { written.append($0) }
        settings.renderForTesting(place: general)
        let eye = try row(settings, place: general, path: "appearance.eye-comfort")
        // Switch has a toggle at the same row: Display move.
        let move = try row(settings, place: switchPlace, path: "gestures.display-move")
        XCTAssertEqual(eye, move, "the two places share the row's number")
        land(settings, place: general, row: eye)
        try clickBack(settings)
        XCTAssertNil(settings.placeForTesting, "the back row shows the overview")
        try clickPlace(settings, switchPlace)
        XCTAssertEqual(settings.placeForTesting, switchPlace)
        settings.keyForTesting("return")
        XCTAssertEqual(written, [], "return in Switch works nothing: the landing was in General")
        settings.close()
    }

    func testReturnOnTheOverviewAfterAClickWorksNothing() throws {
        var written: [Written] = []
        let settings = window { written.append($0) }
        settings.renderForTesting(place: switchPlace)
        let move = try row(settings, place: switchPlace, path: "gestures.display-move")
        land(settings, place: switchPlace, row: move)
        try clickBack(settings)
        XCTAssertNil(settings.placeForTesting)
        settings.keyForTesting("return")
        XCTAssertEqual(written, [], "the overview has no rows to work, and General's are not its rows")
        settings.close()
    }

    func testReturnOnTheOverviewAfterAClickWorksNothingEvenForGeneralsOwnRow() throws {
        var written: [Written] = []
        let settings = window { written.append($0) }
        settings.renderForTesting(place: general)
        let eye = try row(settings, place: general, path: "appearance.eye-comfort")
        land(settings, place: general, row: eye)
        try clickBack(settings)
        XCTAssertNil(settings.placeForTesting)
        settings.keyForTesting("return")
        XCTAssertEqual(written, [], "the overview shows no row, whichever place's it is")
        settings.close()
    }

    func testReturnInAShorterPlaceAfterAClickIsNotARowThatIsNotThere() throws {
        var written: [Written] = []
        let settings = window { written.append($0) }
        settings.renderForTesting(place: general)
        let eye = try row(settings, place: general, path: "appearance.eye-comfort")
        let calendarRows = settings.sectionsForTesting[meetings].rows.count
        XCTAssertLessThanOrEqual(calendarRows, eye, "Meetings has no row at General's Eye comfort number")
        land(settings, place: general, row: eye)
        try clickBack(settings)
        try clickPlace(settings, meetings)
        XCTAssertEqual(settings.placeForTesting, meetings)
        settings.keyForTesting("return")
        XCTAssertEqual(written, [], "return in Meetings works nothing: the landing was in General")
        settings.close()
    }

    func testReturnAfterLeavingThePlaceAndComingBackToItWorksNothing() throws {
        var written: [Written] = []
        let settings = window { written.append($0) }
        settings.renderForTesting(place: general)
        let eye = try row(settings, place: general, path: "appearance.eye-comfort")
        land(settings, place: general, row: eye)
        try clickBack(settings)
        try clickPlace(settings, general)
        XCTAssertEqual(settings.placeForTesting, general)
        settings.keyForTesting("return")
        XCTAssertEqual(written, [], "a landing does not wait for the hand to come back")
        settings.close()
    }

    // MARK: - A render that changed the rows

    private let inputPlace = SettingsModel.placeIndex("Input")!
    private let protoarc = SettingsModel.Wheel(id: "9639:64160:ab12cd34", name: "ProtoArc EM11 NL", present: true)
    private let tool = SettingsModel.Wheel(id: "app:com.example.mousetool", name: "Mouse Tool", present: true)

    /// Input, with the mice the closure names heard: each is a switch row.
    private func input(heard: @escaping () -> [SettingsModel.Wheel],
                       _ written: @escaping (Written) -> Void) -> SettingsController {
        let settings = window(written)
        settings.heardWheels = heard
        settings.machineState = {
            var machine = SettingsModel.MachineState()
            machine.inputMonitoring = "Granted"
            return machine
        }
        settings.renderForTesting(place: inputPlace)
        return settings
    }

    func testReturnWorksTheLandedMouseWhenTheRowsAreAsTheyWere() throws {
        var written: [Written] = []
        let settings = input(heard: { [self] in [protoarc, tool] }) { written.append($0) }
        let place = inputPlace
        let first = try XCTUnwrap(settings.sectionsForTesting[place].rows.firstIndex {
            $0.path.hasSuffix(protoarc.id)
        }, "the first mouse has a row")
        land(settings, place: place, row: first)
        settings.keyForTesting("return")
        XCTAssertEqual(written, [Written(path: "mice.reversed-wheels.\(protoarc.id)", value: .string(protoarc.name))])
        settings.close()
    }

    func testReturnAfterARenderPutAnotherMouseAtTheLandedRowWorksNothing() throws {
        var written: [Written] = []
        var heard = [protoarc, tool]
        let settings = input(heard: { heard }) { written.append($0) }
        let place = inputPlace
        let first = try XCTUnwrap(settings.sectionsForTesting[place].rows.firstIndex {
            $0.path.hasSuffix(protoarc.id)
        })
        land(settings, place: place, row: first)

        heard = [tool] // the first mouse went; the second now stands at its index
        settings.rerender()
        let now = settings.sectionsForTesting[place].rows[first]
        XCTAssertTrue(now.path.hasSuffix(tool.id), "the row at the landed index is another mouse's")

        settings.keyForTesting("return")
        XCTAssertEqual(written, [], "return does not tick a mouse the search did not find")
        settings.close()
    }

    func testReturnAfterARenderRemovedTheLandedRowWorksNothing() throws {
        var written: [Written] = []
        var heard = [protoarc, tool]
        let settings = input(heard: { heard }) { written.append($0) }
        let place = inputPlace
        let second = try XCTUnwrap(settings.sectionsForTesting[place].rows.firstIndex {
            $0.path.hasSuffix(tool.id)
        })
        land(settings, place: place, row: second)

        heard = []
        settings.rerender()
        XCTAssertGreaterThanOrEqual(second, settings.sectionsForTesting[place].rows.count, "the row is gone")

        settings.keyForTesting("return")
        XCTAssertEqual(written, [])
        settings.close()
    }
}
