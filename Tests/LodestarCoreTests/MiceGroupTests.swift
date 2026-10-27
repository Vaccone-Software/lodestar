import XCTest
@testable import LodestarCore

/// The Reversed wheels page behind the Input place's Mice group: one
/// switch per mouse or app that has been heard or ticked, all off until
/// chosen, and a place renamed from Keys to hold the keyboards and the mice.
final class WheelsPageTests: XCTestCase {
    private let protoarc = SettingsModel.Wheel(id: "9639:64160:ab12cd34", name: "ProtoArc EM11 NL", present: true)
    private let logi = SettingsModel.Wheel(id: "app:com.logi.cp-dev-mgr", name: "Logi Options+", present: true)

    private func machine(_ wheels: [SettingsModel.Wheel] = [], inputMonitoring: String = "Granted") -> SettingsModel.MachineState {
        var machine = SettingsModel.MachineState()
        machine.wheels = wheels
        machine.inputMonitoring = inputMonitoring
        return machine
    }

    private func page(_ machine: SettingsModel.MachineState, config: Config = Config()) throws -> SettingsModel.Section {
        try XCTUnwrap(SettingsModel.pages(config: config, machine: machine).first { $0.name == SettingsModel.wheelsPage })
    }

    private func input(_ machine: SettingsModel.MachineState, config: Config = Config()) throws -> SettingsModel.Section {
        try XCTUnwrap(SettingsModel.catalog(config: config, machine: machine).first { $0.name == "Input" })
    }

    private func toggle(_ row: SettingsModel.Row) -> Bool? {
        if case .toggle(let on) = row.control { return on }
        return nil
    }

    // MARK: - The place

    /// Keys is Input everywhere the place is named, and the digit is the same.
    func testTheKeysPlaceIsInput() throws {
        XCTAssertEqual(SettingsModel.placeNames[8], "Input")
        XCTAssertNil(SettingsModel.placeIndex("Keys"))
        XCTAssertEqual(SettingsModel.placeIndex("Input"), 8)
        let place = try input(machine())
        XCTAssertEqual(place.picture, "place-keys", "the picture stays")
        XCTAssertEqual(place.sentence, "The key every gesture starts from, and the keyboards and mice you use")
        XCTAssertEqual(place.status, "Lode, keyboards and mice")
        XCTAssertEqual(try page(machine()).parent, "Input")
        XCTAssertEqual(SettingsModel.pages(config: Config(), machine: machine()).first { $0.name == SettingsModel.keyboardsPage }?.parent,
                       "Input")
    }

    func testSearchFindsTheInputPlaceByTheWordsForMice() {
        let sections = SettingsModel.catalog(config: Config(), machine: machine())
        for word in ["mouse", "wheel", "scroll", "reverse", "direction", "keyboard"] {
            XCTAssertTrue(SettingsModel.search(word, in: sections).contains { $0.sectionName == "Input" }, word)
        }
        XCTAssertTrue(SettingsModel.search("reversed", in: sections).contains { $0.title == "Reversed wheels" })
    }

    /// Mice sit below Keyboards: one row opening the page, and the permission.
    func testTheMiceGroupHoldsTheRowAndThePermission() throws {
        let rows = try input(machine(inputMonitoring: "Not granted")).rows
        let titles = rows.map(\.title)
        XCTAssertEqual(titles.last, "Input Monitoring")
        let reversed = try XCTUnwrap(rows.first { $0.path == "mice.reversed-wheels" })
        XCTAssertEqual(reversed.title, "Reversed wheels")
        XCTAssertEqual(reversed.group, "Mice")
        XCTAssertEqual(reversed.control, .page(SettingsModel.wheelsPage))
        XCTAssertTrue(try XCTUnwrap(titles.firstIndex(of: "Keyboards")) < XCTUnwrap(titles.firstIndex(of: "Reversed wheels")))
        XCTAssertEqual(rows.last?.group, "Mice")
        XCTAssertEqual(rows.last?.action?.id, "open-input-monitoring", "not granted offers the pane")
    }

    /// The row says what is ticked, by name, and is at its default when nothing is.
    func testTheRowSummarisesWhatIsTicked() throws {
        let bare = try XCTUnwrap(try input(machine([protoarc])).rows.first { $0.path == "mice.reversed-wheels" })
        XCTAssertEqual(bare.detail, "None")
        XCTAssertTrue(bare.isDefault, "heard is not ticked")

        var config = Config()
        config.reversedWheels = [protoarc.id: protoarc.name]
        let one = try XCTUnwrap(try input(machine([protoarc]), config: config).rows.first { $0.path == "mice.reversed-wheels" })
        XCTAssertEqual(one.detail, "ProtoArc EM11 NL")
        XCTAssertFalse(one.isDefault)

        config.reversedWheels[logi.id] = logi.name
        let two = try XCTUnwrap(try input(machine(), config: config).rows.first { $0.path == "mice.reversed-wheels" })
        XCTAssertEqual(two.detail, "ProtoArc EM11 NL, Mice through Logi Options+", "a source that was not heard still shows")
    }

    /// Input Monitoring now serves the wheels too, so health is not named alone.
    func testTheObservationsPermissionNoLongerSaysHealthOnly() throws {
        let observations = try XCTUnwrap(SettingsModel.catalog(config: Config(), machine: machine())
            .first { $0.name == "Observations" })
        let row = try XCTUnwrap(observations.rows.first { $0.title == "Input Monitoring" })
        XCTAssertTrue(row.detail?.contains("mouse") ?? false, row.detail ?? "")
    }

    // MARK: - The page

    func testEachSourceHeardIsASwitchThatIsOffUntilChosen() throws {
        let page = try page(machine([logi, protoarc]))
        let sources = page.rows.filter { toggle($0) != nil }
        XCTAssertEqual(sources.map(\.title), ["ProtoArc EM11 NL", "Mice through Logi Options+"], "mice, then apps")
        XCTAssertEqual(sources.map { toggle($0) }, [false, false])
        XCTAssertEqual(sources.map(\.path), ["mice.reversed-wheels.9639:64160:ab12cd34",
                                             "mice.reversed-wheels.app:com.logi.cp-dev-mgr"])
        XCTAssertTrue(sources.allSatisfy { $0.isDefault && !$0.dimmed && $0.group == "Mice" })
        XCTAssertEqual(page.rows.last?.title, "Input Monitoring")
        XCTAssertEqual(page.rows.last?.group, "Permission")
    }

    func testATickedSourceIsOnAndNotDefault() throws {
        var config = Config()
        config.reversedWheels = [protoarc.id: protoarc.name]
        let row = try XCTUnwrap(try page(machine([protoarc]), config: config).rows.first { $0.title == protoarc.name })
        XCTAssertEqual(toggle(row), true)
        XCTAssertFalse(row.isDefault)
        XCTAssertEqual(row.detail, "Its wheel scrolls the other way")
    }

    /// A ticked mouse that is unplugged still lists, by the name the config
    /// kept, and says it is not connected; an app says it is not running.
    func testATickedSourceThatIsGoneStillListsAndSaysSo() throws {
        var config = Config()
        config.reversedWheels = [protoarc.id: protoarc.name, logi.id: logi.name]
        let rows = try page(machine(), config: config).rows
        let mouse = try XCTUnwrap(rows.first { $0.title == "ProtoArc EM11 NL" })
        XCTAssertEqual(mouse.detail, "Not connected")
        XCTAssertEqual(toggle(mouse), true)
        let app = try XCTUnwrap(rows.first { $0.title == "Mice through Logi Options+" })
        XCTAssertEqual(app.detail, "Not running")
    }

    func testTheHeardNameWinsOverTheOneTheConfigKept() throws {
        var config = Config()
        config.reversedWheels = [protoarc.id: "Old name"]
        let rows = try page(machine([protoarc]), config: config).rows
        XCTAssertTrue(rows.contains { $0.title == "ProtoArc EM11 NL" })
        XCTAssertFalse(rows.contains { $0.title == "Old name" })
    }

    func testNothingHeardSaysHowToListAMouse() throws {
        let page = try page(machine())
        XCTAssertEqual(page.rows.count, 2)
        XCTAssertEqual(page.rows[0].control, .readout("Turn the wheel of a mouse to list it here", sub: nil))
        XCTAssertEqual(page.rows[1].title, "Input Monitoring")
    }

    /// Without the permission nothing can be heard or turned: the switches
    /// are dimmed and say why, and the permission row offers its pane.
    func testWithoutInputMonitoringTheSwitchesAreDimmedAndSayWhy() throws {
        var config = Config()
        config.reversedWheels = [protoarc.id: protoarc.name]
        let page = try page(machine([protoarc, logi], inputMonitoring: "Not granted"), config: config)
        let sources = page.rows.filter { toggle($0) != nil }
        XCTAssertEqual(sources.count, 3 - 1)
        XCTAssertTrue(sources.allSatisfy { $0.dimmed && $0.detail == "Needs Input Monitoring" })
        XCTAssertEqual(page.rows.last?.control, .readout("Not granted", sub: nil))
        XCTAssertEqual(page.rows.last?.action?.id, "open-input-monitoring")
        let empty = try self.page(machine([], inputMonitoring: "Not granted"))
        XCTAssertEqual(empty.rows[0].detail, "Needs Input Monitoring")
    }

    /// Every file path the page writes lies under the one table the schema
    /// declares, so the covenant between window and file holds.
    func testEveryRowWritesUnderTheTable() throws {
        var config = Config()
        config.reversedWheels = [logi.id: logi.name]
        for row in try page(machine([protoarc]), config: config).rows where !row.path.isEmpty {
            XCTAssertTrue(row.path.hasPrefix(SettingsModel.wheelsPath + "."), row.path)
        }
    }

    /// The history names a change to the table by the row that opens it.
    func testAChangeToTheTableIsNamedByItsRow() {
        XCTAssertEqual(SettingsModel.historyTitle(["mice", "reversed-wheels", "app:com.logi.cp-dev-mgr"]), "Reversed wheels")
    }
}
