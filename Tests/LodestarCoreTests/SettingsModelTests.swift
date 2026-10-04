import XCTest
@testable import LodestarCore

final class SettingsModelTests: XCTestCase {
    private var sections: [SettingsModel.Section] {
        SettingsModel.catalog(config: Config(), machine: .init())
    }

    private func place(_ name: String, _ config: Config = Config(),
                       _ machine: SettingsModel.MachineState = .init()) -> SettingsModel.Section {
        SettingsModel.catalog(config: config, machine: machine).first { $0.name == name }!
    }

    /// Ten places on the number row, General first on 0, then the four
    /// doors in the site's order.
    func testTheTenPlacesInTheirDigitsOrder() {
        XCTAssertEqual(sections.map(\.name), SettingsModel.placeNames)
        XCTAssertEqual(sections.map(\.name), ["General", "Write", "Switch", "Keep", "Speak",
                                              "Operate", "Web", "Meetings", "Keys", "Observations"])
        XCTAssertEqual(SettingsModel.paneAddresses(count: sections.count),
                       ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"])
        XCTAssertEqual(SettingsModel.pane(forKey: "3", count: sections.count), 3)
        XCTAssertNil(SettingsModel.pane(forKey: "a", count: sections.count))
        XCTAssertEqual(SettingsModel.placeIndex("Speak"), 4)
    }

    /// Every place wears a picture, a sentence and a line for the overview.
    func testEveryPlaceHasItsPictureSentenceAndLine() {
        for section in sections {
            XCTAssertFalse(section.picture.isEmpty, "\(section.name) has no picture")
            XCTAssertFalse(section.sentence.isEmpty, "\(section.name) says nothing")
            XCTAssertFalse(section.status.isEmpty, "\(section.name) has no line on the overview")
            XCTAssertFalse(section.sentence.hasSuffix("."), "copy ends without a period")
        }
    }

    /// A letter belongs to its row: fixed by the catalog in reading order,
    /// readouts and dimmed rows included, so nothing a neighbour does can
    /// move it.
    func testLettersAreFixedByTheCatalog() {
        for section in sections {
            XCTAssertEqual(section.rows.compactMap(\.letter),
                           Array(SettingsModel.labelAlphabet.prefix(section.rows.count)), section.name)
        }
        var off = Config()
        off.scrollSmooth = false
        let before = place("Operate").rows.map { "\($0.letter ?? "")\($0.path)" }
        let after = place("Operate", off).rows.map { "\($0.letter ?? "")\($0.path)" }
        XCTAssertEqual(before, after, "a row dimming never moves a letter")
    }

    /// Where a place has one switch for the whole of it, it is `a`.
    func testTheMasterSwitchIsA() {
        for (name, path) in [("Write", "editor.enabled"), ("Keep", "clipboard.enabled"),
                             ("Speak", "gestures.draft"), ("Meetings", "meetings.enabled"),
                             ("Observations", "observations.logbook"), ("Web", "gestures.web-bar")] {
            let first = place(name).rows.first!
            XCTAssertEqual(first.letter, "a")
            XCTAssertEqual(first.path, path, name)
        }
    }

    /// Every row sits under a header: every group is named.
    func testEveryRowHasAGroup() {
        for section in sections {
            for row in section.rows { XCTAssertNotNil(row.group, "\(section.name) · \(row.title)") }
        }
    }

    /// Each place holds its surface whole: its switch, its tuning, its
    /// permission. The gestures, advanced and permissions panes are gone.
    func testEachPlaceHoldsItsSurfaceWhole() {
        XCTAssertTrue(place("Keep").rows.contains { $0.path == "app.units" }, "units read clips")
        XCTAssertTrue(place("Operate").rows.contains { $0.path == "scroll.speed" })
        XCTAssertTrue(place("Operate").rows.contains { $0.path == "gestures.scroll" })
        XCTAssertTrue(place("Operate").rows.contains { $0.title == "Screen Recording" })
        XCTAssertTrue(place("General").rows.contains { $0.title == "Accessibility" })
        XCTAssertTrue(place("Keys").rows.contains { $0.path == "keys" })
        XCTAssertTrue(place("Keys").rows.contains { $0.path == "health.keyboards" })
        XCTAssertTrue(place("Speak").rows.contains { $0.path == "draft.model" })
        XCTAssertTrue(place("Write").rows.contains { $0.path == "editor.skip-apps" })
    }

    /// Words is one page with two doors: Write and Speak both open it.
    func testWordsIsOnePageBehindWriteAndSpeak() {
        for name in ["Write", "Speak"] {
            let row = place(name).rows.first { $0.path == "draft.words" }!
            guard case .page(let page) = row.control else { return XCTFail("\(name)'s Words is a door") }
            XCTAssertEqual(page, SettingsModel.wordsPage)
        }
        let pages = SettingsModel.pages(config: Config(), machine: .init())
        let words = pages.first { $0.name == SettingsModel.wordsPage }!
        guard case .table(let kind, _) = words.rows.first!.control else { return XCTFail("the page holds the list") }
        XCTAssertEqual(kind, .draftWords)
    }

    /// About you: two optional facts, under health.
    func testAboutYouHoldsTwoOptionalFacts() {
        let rows = place("Observations").rows.filter { $0.group == "About you" }
        XCTAssertEqual(rows.map(\.path), ["health.born", "health.hand"])
        XCTAssertTrue(rows.allSatisfy(\.isDefault), "unset by default")
        guard case .text(let year, let placeholder) = rows[0].control else { return XCTFail("born is typed") }
        XCTAssertEqual(year, "")
        XCTAssertEqual(placeholder, "Year")
        var config = Config()
        config.healthBorn = 1990
        let filled = place("Observations", config).rows.first { $0.path == "health.born" }!
        XCTAssertFalse(filled.isDefault)
    }

    /// Units say Automatic, with the region's choice, until one is chosen.
    func testUnitsAreAutomaticUntilChosen() {
        var machine = SettingsModel.MachineState()
        machine.unitsInferred = "metric"
        let row = place("Keep", Config(), machine).rows.first { $0.path == "app.units" }!
        guard case .choice(let options, let labels, let current) = row.control else { return XCTFail("a dropdown") }
        XCTAssertEqual(options, ["", "imperial", "metric"])
        XCTAssertEqual(labels, ["Automatic · Metric", "Imperial", "Metric"])
        XCTAssertEqual(current, "")
        XCTAssertTrue(row.isDefault)
        var chosen = Config()
        chosen.units = "imperial"
        let set = place("Keep", chosen, machine).rows.first { $0.path == "app.units" }!
        XCTAssertFalse(set.isDefault)
    }

    /// A kept zone is listed by its city and offset, never its identifier.
    func testKeptTimeZonesAreListedByPlace() {
        var config = Config()
        config.clipboardTimeZones = ["Asia/Tokyo", "Asia/Kolkata"]
        let row = place("Keep", config).rows.first { $0.path == "clipboard.time-zones" }!
        guard case .table(let kind, let entries) = row.control else { return XCTFail("time zones are a list") }
        XCTAssertEqual(kind, .clipboardTimeZones)
        XCTAssertEqual(entries.map(\.display), ["Tokyo · UTC+9", "Kolkata · UTC+5:30"])
        XCTAssertFalse(row.isDefault)
    }

    func testEveryConfigRowWearsItsPath() {
        for section in sections {
            for row in section.rows {
                if case .readout = row.control { continue }
                if case .page(SettingsModel.historyPage) = row.control { continue }
                XCTAssertFalse(row.path.isEmpty, "\(section.name) · \(row.title) hides its config path")
            }
        }
    }

    /// A permission reads the machine, says Granted or Not granted (macOS
    /// gives no third answer for these), and when not granted, offers the
    /// pane that grants it.
    func testPermissionsReadTheMachineAndOfferTheirPane() {
        var machine = SettingsModel.MachineState()
        machine.screenRecording = "Not asked yet"
        let row = place("Operate", Config(), machine).rows.first { $0.title == "Screen Recording" }!
        XCTAssertTrue(row.path.isEmpty)
        guard case .readout(let state, _) = row.control else { return XCTFail("a readout") }
        XCTAssertEqual(state, "Not granted")
        XCTAssertEqual(row.action?.id, "open-screen-recording")
        XCTAssertTrue(place("Operate", Config(), machine).attention, "the overview marks it")
        machine.screenRecording = "Granted"
        let granted = place("Operate", Config(), machine).rows.first { $0.title == "Screen Recording" }!
        XCTAssertNil(granted.action)
    }

    /// Deleting asks twice, in words.
    func testDeletingIsAVerbThatAsksTwice() {
        let rows = place("Observations").rows.filter { $0.group == "Delete" }
        XCTAssertEqual(rows.compactMap(\.action?.id), ["delete-logbook", "delete-health"])
        XCTAssertTrue(rows.allSatisfy { $0.action?.destructive == true && $0.action?.confirm != nil })
        XCTAssertEqual(place("Keep").rows.last?.action?.id, "clear-clipboard")
    }

    func testEveryGestureRowWearsItsKeycaps() {
        for section in sections {
            for row in section.rows where row.path.hasPrefix("gestures.") {
                XCTAssertFalse(row.keycaps.isEmpty, "\(row.title) shows no keys")
                XCTAssertFalse(row.title.contains("lode "), "titles are names, not guide copy")
            }
        }
    }

    /// Each record carries its own switch and limit, and what depends on
    /// it dims with it: the coach with the logbook, the facts with health.
    func testEachRecordGatesWhatReadsIt() {
        var config = Config()
        config.observationsHealth = false
        let rows = place("Observations", config).rows
        XCTAssertEqual(rows.map(\.path).prefix(5), ["observations.logbook", "observations.logbook-mb",
                                                    "coach.enabled", "observations.health",
                                                    "observations.health-mb"])
        for path in ["observations.health-mb", "health.born", "health.hand"] {
            XCTAssertTrue(rows.first { $0.path == path }!.dimmed, "\(path) needs health")
        }
        XCTAssertFalse(rows.first { $0.path == "coach.enabled" }!.dimmed, "the coach reads the logbook, not health")
    }

    func testCoachRowDimsWithoutTheLogbook() {
        var config = Config()
        config.logbookEnabled = false
        let row = place("Observations", config).rows.first { $0.path == "coach.enabled" }!
        XCTAssertTrue(row.dimmed)
        XCTAssertTrue(row.isDefault, "the dot and the switch agree")
        if case .toggle(let value) = row.control { XCTAssertFalse(value, "a dimmed coach never shows as on") }
    }

    func testLabelsAreUniqueAndNeverDigits() {
        let labels = SettingsModel.labelAlphabet
        XCTAssertEqual(Set(labels).count, labels.count)
        XCTAssertTrue(labels.allSatisfy { $0.count == 1 && Int($0) == nil },
                      "digits are place addresses and must never label a row")
    }

    func testSearchFindsRowsAndTheWordsPeopleUse() {
        let hits = SettingsModel.search("speed", in: sections)
        XCTAssertEqual(hits.first?.sectionName, "Operate")
        XCTAssertEqual(hits.first?.address, "5 d", "a hit teaches its two keys")
        XCTAssertEqual(SettingsModel.search("clipboard", in: sections).first?.sectionName, "Keep")
        XCTAssertEqual(SettingsModel.search("dictation", in: sections).first?.sectionName, "Speak")
        XCTAssertTrue(SettingsModel.search("", in: sections).isEmpty, "search is a verb, not a view")
    }

    func testEscapePopsExactlyOneLayer() {
        XCTAssertEqual(SettingsModel.popped(.editing), .browsing)
        XCTAssertEqual(SettingsModel.popped(.searching), .browsing)
        XCTAssertNil(SettingsModel.popped(.browsing), "the bottom layer closes")
    }

    func testDefaultConfigReadsAsDefault() {
        for section in sections {
            for row in section.rows where !row.path.isEmpty {
                XCTAssertTrue(row.isDefault, "\(row.path) marked changed on a default config")
            }
        }
    }

    func testChangedValueLosesItsDefaultMark() {
        var config = Config()
        config.scrollSpeed = 2400
        config.meetingsEnabled = true
        XCTAssertFalse(place("Operate", config).rows.first { $0.path == "scroll.speed" }!.isDefault)
        XCTAssertFalse(place("Meetings", config).rows.first { $0.path == "meetings.enabled" }!.isDefault)
    }
}

/// The covenant: the window and the file cannot drift, in either
/// direction. Every leaf the schema declares has a row that writes it (or
/// a deliberate, named exception); every path a row writes exists in the
/// schema. The sibling of ConfigCoverageTests, one layer up.
final class SettingsCoverageTests: XCTestCase {
    /// Leaves settings deliberately does not carry, each with its reason.
    /// The graph is edited where addressing happens — ⌘K and the file —
    /// and a third editor would be a product pretending to be a pane.
    private static let exceptions: Set<String> = ["graph"]
    private static let metadata: Set<String> = ["$schema", "version"]

    func testEverySchemaLeafHasARow() {
        let sections = SettingsModel.catalog(config: Config(), machine: .init())
        var covered = Set<String>()
        for section in sections {
            for row in section.rows where !row.path.isEmpty {
                covered.insert(row.path)
            }
        }
        let declared = SchemaWalk.leafAddresses()
            .subtracting(Self.metadata)
            .subtracting(Self.exceptions)
        let uncovered = declared.filter { leaf in
            !covered.contains(where: { leaf == $0 || leaf.hasPrefix($0 + ".") })
        }
        XCTAssertEqual(uncovered.sorted(), [],
                       "config leaves with no settings row — give them one or retire them")
    }
}

/// Schema leaves as dotted addresses, free-table keys shown as `<key>`.
enum SchemaWalk {
    static func leafAddresses() -> Set<String> {
        var out = Set<String>()
        walk(Config.schema, at: [], into: &out)
        return out
    }

    private static func walk(_ node: SchemaNode, at path: [String],
                             into out: inout Set<String>) {
        switch node {
        case .table(let children, _):
            for (name, child) in children {
                walk(child, at: path + [name], into: &out)
            }
        case .freeTable:
            out.insert((path + ["<key>"]).joined(separator: "."))
        default:
            out.insert(path.joined(separator: "."))
        }
    }

    func testTheAccentIsTheOneAppearanceSettingAndLivesUnderGeneral() {
        let sections = SettingsModel.catalog(config: Config(), machine: .init())
        let general = sections.first { $0.name == "General" }!
        let accent = general.rows.first { $0.path == "appearance.accent" }
        XCTAssertNotNil(accent)
        if case .choice(let options, let labels, let current)? = accent?.control {
            XCTAssertEqual(options, ["system", "orange"])
            XCTAssertEqual(labels, ["System", "International Orange"], "names, capitalized as names are")
            XCTAssertEqual(current, "system")
        } else {
            XCTFail("a choice of two")
        }
        let paths = sections.flatMap { $0.rows }.compactMap { $0.path }
        XCTAssertEqual(paths.filter { $0.hasPrefix("appearance.") }, ["appearance.accent"],
                       "nothing else on the appearance side has passed the sentence")
    }

    func testTheRetiredInteractionSwitchesAreGone() {
        let sections = SettingsModel.catalog(config: Config(), machine: .init())
        let paths = sections.flatMap { $0.rows }.compactMap { $0.path }
        XCTAssertFalse(paths.contains("select.commit-on-unique"))
        XCTAssertFalse(paths.contains("guide.fade"))
    }
}
