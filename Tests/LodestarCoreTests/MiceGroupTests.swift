import XCTest
@testable import LodestarCore

/// The Mice group, last in the Input place: the permission row first, then
/// one switch per mouse or app a scroll has been attributed to or that is
/// ticked, all off until chosen. The place was Keys; it holds the keyboards
/// and the mice.
final class MiceGroupTests: XCTestCase {
    private let protoarc = SettingsModel.Wheel(id: "9639:64160:ab12cd34", name: "ProtoArc EM11 NL", present: true)
    private let logi = SettingsModel.Wheel(id: "app:com.logi.cp-dev-mgr", name: "Logi Options+", present: true)

    private func machine(_ wheels: [SettingsModel.Wheel] = [], inputMonitoring: String = "Granted") -> SettingsModel.MachineState {
        var machine = SettingsModel.MachineState()
        machine.wheels = wheels
        machine.inputMonitoring = inputMonitoring
        return machine
    }

    private func input(_ machine: SettingsModel.MachineState, config: Config = Config()) throws -> SettingsModel.Section {
        try XCTUnwrap(SettingsModel.catalog(config: config, machine: machine).first { $0.name == "Input" })
    }

    private func mice(_ machine: SettingsModel.MachineState, config: Config = Config()) throws -> [SettingsModel.Row] {
        try input(machine, config: config).rows.filter { $0.group == "Mice" }
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
        XCTAssertEqual(SettingsModel.pages(config: Config(), machine: machine()).first { $0.name == SettingsModel.keyboardsPage }?.parent,
                       "Input")
    }

    /// The group is a place's own, with no page behind it.
    func testThereIsNoReversedWheelsPage() {
        XCTAssertEqual(SettingsModel.pages(config: Config(), machine: machine([protoarc])).map(\.name),
                       [SettingsModel.keyboardsPage, SettingsModel.wordsPage, SettingsModel.historyPage])
        XCTAssertFalse(SettingsModel.catalog(config: Config(), machine: machine([protoarc]))
            .flatMap(\.rows).contains { $0.title == "Reversed wheels" })
    }

    // MARK: - Search

    /// A hand looking for the wheel's direction by any of its words lands on
    /// the Mice group, in the Input place, first.
    func testSearchLandsOnTheMiceGroup() throws {
        let sections = SettingsModel.catalog(config: Config(), machine: machine([protoarc]))
        for word in ["reverse", "reversed", "wheel", "mouse", "scroll direction", "mice"] {
            let hits = SettingsModel.search(word, in: sections)
            let first = try XCTUnwrap(hits.first, word)
            XCTAssertEqual(first.sectionName, "Input", word)
            let row = sections[first.section].rows[first.row]
            XCTAssertEqual(row.group, "Mice", "\(word) lands on \(row.title)")
        }
        XCTAssertTrue(SettingsModel.search("keyboard", in: sections).contains { $0.sectionName == "Input" })
    }

    func testSearchLandsOnTheMiceGroupWithNoSourceToo() throws {
        let sections = SettingsModel.catalog(config: Config(), machine: machine())
        for word in ["reverse", "wheel", "mouse", "scroll direction"] {
            let first = try XCTUnwrap(SettingsModel.search(word, in: sections).first, word)
            XCTAssertEqual(sections[first.section].rows[first.row].group, "Mice", word)
            XCTAssertEqual(first.sectionName, "Input", word)
        }
    }

    // MARK: - The group

    /// Last in the place, so that the rows that come and go never move a
    /// letter the hand has learned: the permission first, fixed, then the sources.
    func testTheGroupIsLastAndTheLettersBeforeItNeverMove() throws {
        let bare = try input(machine())
        let withMice = try input(machine([protoarc, logi]))
        let fixed = bare.rows.prefix { $0.group != "Mice" }
        XCTAssertEqual(withMice.rows.prefix(fixed.count).map(\.letter), fixed.map(\.letter))
        XCTAssertEqual(withMice.rows.prefix(fixed.count).map(\.title), fixed.map(\.title))
        XCTAssertEqual(bare.rows[fixed.count].title, "Input Monitoring")
        XCTAssertEqual(withMice.rows[fixed.count].title, "Input Monitoring")
        XCTAssertEqual(withMice.rows[fixed.count].letter, bare.rows[fixed.count].letter)
        XCTAssertTrue(withMice.rows.suffix(from: fixed.count).allSatisfy { $0.group == "Mice" })
        XCTAssertEqual(withMice.rows.count, fixed.count + 3)
    }

    func testThePermissionRowOffersThePaneWhenNotGranted() throws {
        let row = try XCTUnwrap(try mice(machine(inputMonitoring: "Not granted")).first)
        XCTAssertEqual(row.title, "Input Monitoring")
        XCTAssertEqual(row.control, .readout("Not granted", sub: nil))
        XCTAssertEqual(row.action?.id, "open-input-monitoring")
    }

    func testEachSourceIsASwitchThatIsOffUntilChosenMiceFirst() throws {
        let rows = try mice(machine([logi, protoarc])).dropFirst()
        XCTAssertEqual(rows.map(\.title), ["ProtoArc EM11 NL", "Mice through Logi Options+"])
        XCTAssertEqual(rows.map { toggle($0) }, [false, false])
        XCTAssertEqual(rows.map(\.path), ["mice.reversed-wheels.9639:64160:ab12cd34",
                                          "mice.reversed-wheels.app:com.logi.cp-dev-mgr"])
        XCTAssertTrue(rows.allSatisfy { $0.isDefault && !$0.dimmed })
        XCTAssertEqual(rows.first?.detail, "Its wheel scrolls the way the Mac does")
    }

    func testATickedSourceIsOnAndNotDefault() throws {
        var config = Config()
        config.reversedWheels = [protoarc.id: protoarc.name]
        let row = try XCTUnwrap(try mice(machine([protoarc]), config: config).first { $0.title == protoarc.name })
        XCTAssertEqual(toggle(row), true)
        XCTAssertFalse(row.isDefault)
        XCTAssertEqual(row.detail, "Its wheel scrolls the other way")
    }

    /// A ticked mouse that is unplugged still lists, by the name the config
    /// kept, and says it is not connected; an app says it is not running.
    func testATickedSourceThatIsGoneStillListsAndSaysSo() throws {
        var config = Config()
        config.reversedWheels = [protoarc.id: protoarc.name, logi.id: logi.name]
        let rows = try mice(machine(), config: config)
        let mouse = try XCTUnwrap(rows.first { $0.title == "ProtoArc EM11 NL" })
        XCTAssertEqual(mouse.detail, "Not connected")
        XCTAssertEqual(toggle(mouse), true)
        XCTAssertEqual(rows.first { $0.title == "Mice through Logi Options+" }?.detail, "Not running")
    }

    func testTheHeardNameWinsOverTheOneTheConfigKept() throws {
        var config = Config()
        config.reversedWheels = [protoarc.id: "Old name"]
        let rows = try mice(machine([protoarc]), config: config)
        XCTAssertTrue(rows.contains { $0.title == "ProtoArc EM11 NL" })
        XCTAssertFalse(rows.contains { $0.title == "Old name" })
    }

    func testNothingHeardSaysHowToListAMouse() throws {
        let rows = try mice(machine())
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1].title, "No mouse heard")
        XCTAssertEqual(rows[1].control, .readout("Turn the wheel of a mouse to list it here", sub: nil))
    }

    /// Without the permission nothing can be heard or turned: the switches
    /// are dimmed and say why.
    func testWithoutInputMonitoringTheSwitchesAreDimmedAndSayWhy() throws {
        var config = Config()
        config.reversedWheels = [protoarc.id: protoarc.name]
        let rows = try mice(machine([protoarc, logi], inputMonitoring: "Not granted"), config: config).dropFirst()
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.dimmed && $0.detail == "Needs Input Monitoring" })
        let empty = try mice(machine(inputMonitoring: "Not granted"))
        XCTAssertEqual(empty[1].detail, "Needs Input Monitoring")
    }

    /// Every path a switch writes lies under the one table the schema declares.
    func testEveryRowWritesUnderTheTable() throws {
        var config = Config()
        config.reversedWheels = [logi.id: logi.name]
        for row in try mice(machine([protoarc]), config: config) where !row.path.isEmpty {
            XCTAssertTrue(row.path.hasPrefix(SettingsModel.wheelsPath + "."), row.path)
        }
    }

    /// The Observations permission names the mice too.
    func testTheObservationsPermissionNoLongerSaysHealthOnly() throws {
        let observations = try XCTUnwrap(SettingsModel.catalog(config: Config(), machine: machine())
            .first { $0.name == "Observations" })
        let row = try XCTUnwrap(observations.rows.first { $0.title == "Input Monitoring" })
        XCTAssertTrue(row.detail?.contains("mouse") ?? false, row.detail ?? "")
    }

    /// The history names a change to the table as Reversed wheels, a mouse
    /// or an app, heard or not.
    func testAChangeToTheTableIsNamedReversedWheels() {
        XCTAssertEqual(SettingsModel.historyTitle(["mice", "reversed-wheels", "app:com.logi.cp-dev-mgr"]), "Reversed wheels")
        XCTAssertEqual(SettingsModel.historyTitle(["mice", "reversed-wheels", "9639:64160:ab12cd34"]), "Reversed wheels")
    }
}
