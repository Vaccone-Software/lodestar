import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The Mice group as the window drives it: a switch ticks a source by
/// writing its table entry under the name it is listed by, unticks it by
/// removing the entry, the place says when it is on screen so that the mice
/// are listened for only then, and the row of a wheel that is turning wears
/// the border a search landing does.
final class SettingsWheelsTests: XCTestCase {
    private struct Written: Equatable {
        var path: [String]
        var value: ConfigValue?
    }

    private let protoarc = SettingsModel.Wheel(id: "9639:64160:ab12cd34", name: "ProtoArc EM11 NL", present: true)
    private let app = SettingsModel.Wheel(id: "app:com.example.mousetool", name: "Mouse Tool", present: true)

    /// Input's rows: six fixed (Lode key to the permission, a to f), so the
    /// sources are g, h.
    private func controller(wheels: [SettingsModel.Wheel], config: Config = Config(), inputMonitoring: String = "Granted",
                            written: @escaping (Written) -> Void) -> SettingsController {
        let settings = SettingsController.preview(-1)
        settings.applyEntries = { removals, sets in
            for path in removals { written(Written(path: path, value: nil)) }
            for (path, value) in sets { written(Written(path: path, value: value)) }
            return nil
        }
        settings.machineState = {
            var machine = SettingsModel.MachineState()
            machine.inputMonitoring = inputMonitoring
            return machine
        }
        settings.heardWheels = { wheels }
        settings.config = config
        settings.renderForTesting(place: SettingsModel.placeIndex("Input"))
        return settings
    }

    func testTheInputPlaceListsTheSources() {
        let settings = controller(wheels: [protoarc]) { _ in }
        XCTAssertNil(settings.pageForTesting)
        XCTAssertTrue(settings.shownTextsForTesting.contains("ProtoArc EM11 NL"))
        settings.close()
    }

    /// A source's letter ticks it: its entry is written under the name it is
    /// listed by.
    func testTheLetterTicksAMouseByWritingItsEntry() {
        var written: [Written] = []
        let settings = controller(wheels: [protoarc, app]) { written.append($0) }
        XCTAssertTrue(settings.keyForTesting("g"))
        XCTAssertEqual(written, [Written(path: ["mice", "reversed-wheels", protoarc.id], value: .string(protoarc.name))])
        settings.close()
    }

    /// An app's id holds dots and goes as one component of the path, never
    /// split; its name is the app's, not the row's "Mice through".
    func testAnAppIsTickedUnderItsOwnNameAndItsIdIsNotSplit() {
        var written: [Written] = []
        let settings = controller(wheels: [protoarc, app]) { written.append($0) }
        XCTAssertTrue(settings.keyForTesting("h"))
        XCTAssertEqual(written, [Written(path: ["mice", "reversed-wheels", "app:com.example.mousetool"],
                                         value: .string("Mouse Tool"))])
        settings.close()
    }

    func testAnotherPressOfATickedSourceRemovesItsEntry() {
        var written: [Written] = []
        var config = Config()
        config.reversedWheels = [protoarc.id: protoarc.name, app.id: app.name]
        let settings = controller(wheels: [protoarc, app], config: config) { written.append($0) }
        XCTAssertTrue(settings.keyForTesting("g"))
        XCTAssertTrue(settings.keyForTesting("h"))
        XCTAssertEqual(written, [Written(path: ["mice", "reversed-wheels", protoarc.id], value: nil),
                                 Written(path: ["mice", "reversed-wheels", "app:com.example.mousetool"], value: nil)])
        settings.close()
    }

    /// Without the permission a switch is dimmed and a press writes nothing.
    func testWithoutInputMonitoringAPressWritesNothing() {
        var written: [Written] = []
        let settings = controller(wheels: [protoarc], inputMonitoring: "Not granted") { written.append($0) }
        settings.keyForTesting("g")
        XCTAssertEqual(written, [])
        settings.close()
    }

    /// The mice are listened for only while the Input place itself is on
    /// screen: not the overview, not another place, not a page of Input.
    func testThePlaceSaysWhenItIsOnScreen() {
        var shown: [Bool] = []
        let settings = SettingsController.preview(-1)
        settings.miceShowing = { shown.append($0) }
        settings.heardWheels = { [] }
        settings.renderForTesting(place: SettingsModel.placeIndex("Keep"))
        XCTAssertEqual(shown, [])
        settings.renderForTesting(place: SettingsModel.placeIndex("Input"))
        settings.rerender()
        XCTAssertEqual(shown, [true], "once, not once a render")
        settings.openForTesting(page: SettingsModel.keyboardsPage)
        XCTAssertEqual(shown, [true, false], "a page of Input is not the group")
        settings.openForTesting(place: "Input")
        XCTAssertEqual(shown, [true, false, true])
        settings.openForTesting(place: nil)
        XCTAssertEqual(shown, [true, false, true, false])
        settings.close()
    }

    func testClosingTheWindowSaysTheListIsNoLongerWatched() {
        var shown: [Bool] = []
        let settings = SettingsController.preview(-1)
        settings.miceShowing = { shown.append($0) }
        settings.heardWheels = { [] }
        settings.renderForTesting(place: SettingsModel.placeIndex("Input"))
        XCTAssertEqual(shown, [true])
        settings.close()
        XCTAssertEqual(shown, [true, false])
    }

    // MARK: - Lit rows

    /// A wheel turning lights its row with the border a search landing wears
    /// (one raised step behind the row), and nothing else.
    func testALitSourceWearsTheLandingBorder() {
        var lit: Set<String> = []
        let settings = controller(wheels: [protoarc, app]) { _ in }
        settings.litWheels = { lit }
        settings.rerender()
        let plain = settings.viewsForTesting(of: LandingStep.self).count
        lit = [protoarc.id]
        settings.rerender()
        XCTAssertEqual(settings.viewsForTesting(of: LandingStep.self).count, plain + 1)
        lit = [protoarc.id, app.id]
        settings.rerender()
        XCTAssertEqual(settings.viewsForTesting(of: LandingStep.self).count, plain + 2)
        lit = []
        settings.rerender()
        XCTAssertEqual(settings.viewsForTesting(of: LandingStep.self).count, plain, "unlit when it stops")
        settings.close()
    }

    /// Nothing is lit where the Mice group is not drawn.
    func testNothingIsLitWhileInputIsNotOnScreen() {
        let settings = controller(wheels: [protoarc]) { _ in }
        settings.litWheels = { [self.protoarc.id] }
        settings.renderForTesting(place: SettingsModel.placeIndex("Keep"))
        XCTAssertEqual(settings.viewsForTesting(of: LandingStep.self).count, 0)
        settings.openForTesting(page: SettingsModel.keyboardsPage)
        XCTAssertEqual(settings.viewsForTesting(of: LandingStep.self).count, 0)
        settings.close()
    }

    /// The sources are read for each render, after the doctor's memo, as the
    /// keyboards are: a memoized list is how a page names a mouse that left.
    func testTheSourcesAreReadOutsideTheDoctorsMemo() throws {
        let url = DesignDriftTests.appSources.appendingPathComponent("SettingsController.swift")
        let controller = try String(contentsOf: url, encoding: .utf8)
        guard let memo = controller.range(of: "doctorCache = (machine, findings, now)"),
              let fresh = controller.range(of: "machine.wheels = heardWheels()") else {
            return XCTFail("the render's shape has moved; check the freshness still holds")
        }
        XCTAssertTrue(fresh.lowerBound > memo.lowerBound)
        let main = try String(contentsOf: DesignDriftTests.appSources.appendingPathComponent("main.swift"), encoding: .utf8)
        XCTAssertFalse(main.contains("state.wheels"), "the sources belong to heardWheels, never to the memoized state")
    }
}
