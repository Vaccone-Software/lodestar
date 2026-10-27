import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The Reversed wheels page as the window drives it: a switch ticks a source
/// by writing its table entry under the name it is listed by, unticks it by
/// removing the entry, and the page says when it is on screen so that the
/// mice are listened for only then.
final class SettingsWheelsTests: XCTestCase {
    private struct Written: Equatable {
        var path: [String]
        var value: ConfigValue?
    }

    private let protoarc = SettingsModel.Wheel(id: "9639:64160:ab12cd34", name: "ProtoArc EM11 NL", present: true)
    private let app = SettingsModel.Wheel(id: "app:com.example.mousetool", name: "Mouse Tool", present: true)

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
        settings.openForTesting(page: SettingsModel.wheelsPage)
        return settings
    }

    func testTheInputPlaceOpensTheWheelsPage() {
        let settings = controller(wheels: [protoarc]) { _ in }
        XCTAssertEqual(settings.pageForTesting, SettingsModel.wheelsPage)
        XCTAssertTrue(settings.shownTextsForTesting.contains("ProtoArc EM11 NL"))
        settings.close()
    }

    /// The first row's letter ticks a mouse: its entry is written under the
    /// name it is listed by.
    func testTheLetterTicksAMouseByWritingItsEntry() {
        var written: [Written] = []
        let settings = controller(wheels: [protoarc, app]) { written.append($0) }
        XCTAssertTrue(settings.keyForTesting("a"))
        XCTAssertEqual(written, [Written(path: ["mice", "reversed-wheels", protoarc.id], value: .string(protoarc.name))])
        settings.close()
    }

    /// An app's id holds dots and goes as one component of the path, never
    /// split; its name is the app's, not the row's "Mice through".
    func testAnAppIsTickedUnderItsOwnNameAndItsIdIsNotSplit() {
        var written: [Written] = []
        let settings = controller(wheels: [protoarc, app]) { written.append($0) }
        XCTAssertTrue(settings.keyForTesting("b"))
        XCTAssertEqual(written, [Written(path: ["mice", "reversed-wheels", "app:com.example.mousetool"],
                                         value: .string("Mouse Tool"))])
        settings.close()
    }

    func testAnotherPressOfATickedSourceRemovesItsEntry() {
        var written: [Written] = []
        var config = Config()
        config.reversedWheels = [protoarc.id: protoarc.name, app.id: app.name]
        let settings = controller(wheels: [protoarc, app], config: config) { written.append($0) }
        XCTAssertTrue(settings.keyForTesting("a"))
        XCTAssertTrue(settings.keyForTesting("b"))
        XCTAssertEqual(written, [Written(path: ["mice", "reversed-wheels", protoarc.id], value: nil),
                                 Written(path: ["mice", "reversed-wheels", "app:com.example.mousetool"], value: nil)])
        settings.close()
    }

    /// Without the permission a switch is dimmed and a press writes nothing.
    func testWithoutInputMonitoringAPressWritesNothing() {
        var written: [Written] = []
        let settings = controller(wheels: [protoarc], inputMonitoring: "Not granted") { written.append($0) }
        settings.keyForTesting("a")
        XCTAssertEqual(written, [])
        settings.close()
    }

    /// The mice are listened for only while the page is on screen.
    func testThePageSaysWhenItIsOnScreen() {
        var shown: [Bool] = []
        let settings = SettingsController.preview(-1)
        settings.wheelsShowing = { shown.append($0) }
        settings.heardWheels = { [] }
        settings.renderForTesting(place: SettingsModel.placeIndex("Input"))
        XCTAssertEqual(shown, [], "the place is not the page")
        settings.openForTesting(page: SettingsModel.wheelsPage)
        settings.rerender()
        XCTAssertEqual(shown, [true], "once, not once a render")
        settings.openForTesting(place: "Input")
        XCTAssertEqual(shown, [true, false])
        settings.close()
    }

    func testClosingTheWindowSaysTheListIsNoLongerWatched() {
        var shown: [Bool] = []
        let settings = SettingsController.preview(-1)
        settings.wheelsShowing = { shown.append($0) }
        settings.heardWheels = { [] }
        settings.renderForTesting(place: SettingsModel.placeIndex("Input"))
        settings.openForTesting(page: SettingsModel.wheelsPage)
        XCTAssertEqual(shown, [true])
        settings.close()
        XCTAssertEqual(shown, [true, false])
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
