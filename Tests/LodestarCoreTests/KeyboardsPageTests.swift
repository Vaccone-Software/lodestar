import XCTest
@testable import LodestarCore

/// The page behind the Health group's Keyboards row: one board chosen at
/// the top, its fourteen keys below, only a placement that differs ever
/// written. The first page the window has; the shape every later one
/// inherits.
final class KeyboardsPageTests: XCTestCase {
    private let kinesis = SettingsModel.Keyboard(id: "7504:24926:782ec294", name: "Kinesis Advantage360",
                                                 builtIn: false, attached: true)
    private let apple = SettingsModel.Keyboard(id: "1452:834:bc1af98d", name: "Apple Internal Keyboard",
                                               builtIn: true, attached: true)

    private func machine(_ keyboards: [SettingsModel.Keyboard]) -> SettingsModel.MachineState {
        var machine = SettingsModel.MachineState()
        machine.keyboards = keyboards
        return machine
    }

    private func page(config: Config = Config(), keyboards: [SettingsModel.Keyboard],
                      selected: String? = nil) -> SettingsModel.Section {
        SettingsModel.pages(config: config, machine: machine(keyboards),
                            view: SettingsModel.ViewState(selectedKeyboard: selected))
            .first { $0.name == SettingsModel.keyboardsPage }!
    }

    func testThePageIsAPageOfTheCoachPaneNotAPane() {
        let page = page(keyboards: [apple, kinesis])
        XCTAssertEqual(page.parent, "Coach")
        XCTAssertFalse(SettingsModel.catalog(config: Config(), machine: machine([apple, kinesis]))
            .contains { $0.name == SettingsModel.keyboardsPage }, "never on the rail")
    }

    /// The board chosen at the top, opened to the external one, because
    /// a laptop's own keyboard is standard and the other one is why the
    /// page exists.
    func testTheFirstRowChoosesTheBoardAndOpensToTheExternalOne() {
        let page = page(keyboards: [apple, kinesis])
        guard case .selector(let options, let labels, let current) = page.rows[0].control else {
            return XCTFail("the first row chooses the keyboard")
        }
        XCTAssertEqual(options, [apple.id, kinesis.id])
        XCTAssertEqual(labels, ["Apple Internal Keyboard", "Kinesis Advantage360"])
        XCTAssertEqual(current, kinesis.id)
        XCTAssertTrue(page.rows[0].path.isEmpty, "the window's choice, not the file's")
        XCTAssertTrue(page.rows[0].detail?.hasPrefix(kinesis.id) ?? false,
                      "the id first, so the file can be read against the page")
        XCTAssertTrue(page.rows[0].detail?.contains("Either") ?? false,
                      "and the one naming rule a split board needs")
    }

    func testTheChoiceIsHonoredAndAnUnpluggedBoardSaysSo() {
        let bag = SettingsModel.Keyboard(id: "13364:2064:cf3d8489", name: "Keychron Q1 Max",
                                         builtIn: false, attached: false)
        let page = page(keyboards: [apple, kinesis, bag], selected: bag.id)
        guard case .selector(_, let labels, let current) = page.rows[0].control else { return XCTFail() }
        XCTAssertEqual(current, bag.id)
        XCTAssertEqual(labels.last, "Keychron Q1 Max · not attached")
    }

    /// Fourteen keys, each its own row, each addressed by the file's
    /// own path, standard shown as the standard placement's name.
    func testEveryKeyIsARowAtItsOwnPathWithStandardLabelled() {
        let page = page(keyboards: [apple, kinesis])
        let keys = page.rows.dropFirst()
        XCTAssertEqual(keys.count, Keys.SpecialKey.allCases.count)
        XCTAssertEqual(keys.map(\.title), Keys.SpecialKey.allCases.map(\.label))
        XCTAssertEqual(keys.map(\.path), Keys.SpecialKey.allCases.map { "health.keyboards.\(kinesis.id).\($0.rawValue)" })
        XCTAssertTrue(keys.allSatisfy(\.isDefault))
        XCTAssertEqual(keys.first?.group, "Keys")
        XCTAssertTrue(keys.dropFirst().allSatisfy { $0.group == nil }, "one heading, not fourteen")
        let enter = keys.first { $0.title == "Enter" }!
        guard case .choice(let options, let labels, let current) = enter.control else { return XCTFail() }
        XCTAssertEqual(options.count, 16, "standard, then three sides by five fingers")
        XCTAssertEqual(options[0], "")
        XCTAssertEqual(labels[0], "Right pinky · standard")
        XCTAssertEqual(options[1...].map { $0 }, FingerMap.Placement.all.map(\.text))
        XCTAssertEqual(labels[1], "Left thumb")
        XCTAssertEqual(current, "")
        let space = keys.first { $0.title == "Space" }!
        if case .choice(_, let labels, _) = space.control {
            XCTAssertEqual(labels[0], "Either thumb · standard")
        }
    }

    func testADeclaredPlacementShowsAsTheRowsValueAndMarksItChanged() {
        var config = Config()
        config.fingerMap = FingerMap([kinesis.id: [.enter: FingerMap.Placement(.right, .thumb)]])
        let page = page(config: config, keyboards: [apple, kinesis])
        let enter = page.rows.first { $0.title == "Enter" }!
        XCTAssertFalse(enter.isDefault)
        if case .choice(_, _, let current) = enter.control { XCTAssertEqual(current, "right thumb") }
        let tab = page.rows.first { $0.title == "Tab" }!
        XCTAssertTrue(tab.isDefault)
        // The other board is untouched by it.
        let applePage = self.page(config: config, keyboards: [apple, kinesis], selected: apple.id)
        XCTAssertTrue(applePage.rows.dropFirst().allSatisfy(\.isDefault))
    }

    func testTheHealthRowSummarizesTheExternalBoards() {
        var config = Config()
        config.fingerMap = FingerMap([kinesis.id: [.enter: FingerMap.Placement(.right, .thumb),
                                                   .space: FingerMap.Placement(.right, .thumb)]])
        let coach = SettingsModel.catalog(config: config, machine: machine([apple, kinesis]))
            .first { $0.name == "Coach" }!
        let row = coach.rows.first { $0.path == "health.keyboards" }!
        XCTAssertEqual(row.detail, "Kinesis Advantage360 · 2 keys differ.")
        XCTAssertFalse(row.isDefault)
        let bare = SettingsModel.catalog(config: Config(), machine: machine([apple, kinesis]))
            .first { $0.name == "Coach" }!.rows.first { $0.path == "health.keyboards" }!
        XCTAssertEqual(bare.detail, "Kinesis Advantage360 · standard.")
        XCTAssertTrue(bare.isDefault)
        let none = SettingsModel.catalog(config: Config(), machine: machine([apple]))
            .first { $0.name == "Coach" }!.rows.first { $0.path == "health.keyboards" }!
        XCTAssertTrue(none.detail?.contains("split or custom keyboard") ?? false)
    }

    /// A board that is neither attached nor declared is not on the page
    /// at all. The window once showed one for hours after it was
    /// unpaired, which was a stale render rather than this — but the
    /// invariant is worth holding here, where it can be read.
    func testABoardNeitherAttachedNorDeclaredIsAbsent() {
        let gone = SettingsModel.Keyboard(id: "13364:2064:cf3d8489", name: "Keychron Q1 Max",
                                          builtIn: false, attached: true)
        var config = Config()
        config.fingerMap = FingerMap([gone.id: [.enter: FingerMap.Placement(.right, .thumb)]])
        // Declared and away: present, and marked so.
        let declared = page(config: config, keyboards: [apple, kinesis], selected: nil)
        guard case .selector(let options, let labels, _) = declared.rows[0].control else { return XCTFail() }
        XCTAssertFalse(options.contains(gone.id), "the machine did not offer it, so the page cannot")
        XCTAssertFalse(labels.contains { $0.contains("Keychron") })
        // Neither: gone from the summary too.
        let coach = SettingsModel.catalog(config: Config(), machine: machine([apple, kinesis]))
            .first { $0.name == "Coach" }!
        XCTAssertFalse(coach.rows.first { $0.path == "health.keyboards" }!
            .detail!.contains("Keychron"))
    }

    func testWithNoKeyboardThePageSaysSoInsteadOfGuessing() {
        let page = page(keyboards: [])
        XCTAssertEqual(page.rows.count, 1)
        guard case .readout = page.rows[0].control else { return XCTFail("a readout, not a choice") }
    }
}
