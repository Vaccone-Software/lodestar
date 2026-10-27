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
                                              "Operate", "Web", "Meetings", "Input", "Observations"])
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
        XCTAssertTrue(place("Operate").rows.contains { $0.title == "Screen recording" })
        XCTAssertTrue(place("General").rows.contains { $0.title == "Accessibility" })
        XCTAssertTrue(place("Input").rows.contains { $0.path == "keys" })
        XCTAssertTrue(place("Input").rows.contains { $0.path == "health.keyboards" })
        XCTAssertTrue(place("Speak").rows.contains { $0.path == "draft.model" })
        XCTAssertTrue(place("Write").rows.contains { $0.path == "editor.skip-apps" })
    }

    /// The Editing style is the Speak page's second row of the Draft group,
    /// directly under Microphone: Standard and Vim, Standard the default.
    func testTheEditingStyleSitsUnderTheMicrophone() throws {
        let rows = place("Speak").rows.filter { $0.group == "Draft" }.map(\.title)
        let microphone = try XCTUnwrap(rows.firstIndex(of: "Microphone"))
        XCTAssertEqual(rows[microphone + 1], "Editing style")

        let row = try XCTUnwrap(place("Speak").rows.first { $0.path == "draft.editing-style" })
        guard case .choice(let options, let labels, let current) = row.control else {
            return XCTFail("the style is a choice")
        }
        XCTAssertEqual(options, ["standard", "vim"])
        XCTAssertEqual(labels, ["Standard", "Vim"])
        XCTAssertEqual(current, "standard")
        XCTAssertTrue(row.isDefault)
        XCTAssertEqual(row.detail, "Edits like any Mac text field. Esc closes the draft")

        var vim = Config()
        vim.draftEditingStyle = .vim
        let chosen = try XCTUnwrap(place("Speak", vim).rows.first { $0.path == "draft.editing-style" })
        guard case .choice(_, _, let now) = chosen.control else { return XCTFail("the style is a choice") }
        XCTAssertEqual(now, "vim")
        XCTAssertFalse(chosen.isDefault)
        XCTAssertEqual(chosen.detail, "Vim's modes and motions. Esc goes to normal mode first")
    }

    /// Someone looking for Vim, or for the draft's keys, finds the Speak place.
    func testSearchingForVimOrEditingFindsTheEditingStyle() {
        for query in ["vim", "editing", "style"] {
            XCTAssertEqual(SettingsModel.search(query, in: sections).first?.title, "Editing style", query)
        }
        XCTAssertTrue(SettingsModel.search("keys", in: sections).contains { $0.sectionName == "Speak" })
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

    /// About you: four optional facts, read from the sealed record and
    /// never from the config.
    func testAboutYouHoldsFourOptionalFacts() {
        var machine = SettingsModel.MachineState()
        machine.person = Person()
        let rows = place("Observations", Config(), machine).rows.filter { $0.group == "About you" }
        XCTAssertEqual(rows.map(\.path), ["health.born", "health.sex", "health.hand", "health.typing"])
        XCTAssertEqual(rows.map(\.path), Person.paths)
        XCTAssertTrue(rows.allSatisfy(\.isDefault), "unset by default")
        XCTAssertFalse(rows.contains { $0.dimmed })
        guard case .text(let year, let placeholder) = rows[0].control else { return XCTFail("born is typed") }
        XCTAssertEqual(year, "")
        XCTAssertEqual(placeholder, "Year")
        machine.person = Person(born: 1990, sex: "female", typing: "touch")
        var config = Config()
        config.healthHand = "left"
        let filled = place("Observations", config, machine).rows.filter { $0.group == "About you" }
        XCTAssertEqual(filled.map(\.isDefault), [false, false, true, false], "an old config line is not a fact")
        guard case .choice(_, _, let sex) = filled[1].control else { return XCTFail("sex is chosen") }
        XCTAssertEqual(sex, "female")
    }

    /// Exact keyboard attribution has no switch: health asks for Input
    /// Monitoring itself, and Settings shows the grant.
    func testInputMonitoringIsAPermissionNotASwitch() {
        let rows = place("Observations").rows
        XCTAssertFalse(rows.contains { $0.path == "health.exact-keyboards" || $0.title == "Exact keyboard" })
        var machine = SettingsModel.MachineState()
        machine.inputMonitoring = "Not granted"
        let asking = place("Observations", Config(), machine).rows.first { $0.title == "Input Monitoring" }
        XCTAssertEqual(asking?.action?.id, "open-input-monitoring")
        machine.inputMonitoring = "Granted"
        let granted = place("Observations", Config(), machine).rows.first { $0.title == "Input Monitoring" }
        XCTAssertNotNil(granted)
        XCTAssertNil(granted?.action, "nothing to open once it is granted")
    }

    func testAboutYouWaitsForTheHealthRecord() {
        let rows = place("Observations").rows.filter { $0.group == "About you" }
        XCTAssertTrue(rows.allSatisfy(\.dimmed), "nothing to show until the sealed facts are read")
        XCTAssertTrue(rows.allSatisfy { $0.detail == "Opens with the health record" })
    }

    func testTheHealthRowSaysTheFingersAssumeTouchTyping() {
        let row = place("Observations").rows.first { $0.path == "observations.health" }!
        XCTAssertTrue(row.detail?.contains("touch typist") == true)
    }

    /// One night: there is no Background row, in either mode.
    func testThereIsNoBackgroundChoice() {
        var machine = SettingsModel.MachineState()
        for dark in [true, false] {
            machine.isDark = dark
            let rows = place("General", Config(), machine).rows
            XCTAssertNil(rows.first { $0.path == "appearance.background" })
        }
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
        let row = place("Operate", Config(), machine).rows.first { $0.title == "Screen recording" }!
        XCTAssertTrue(row.path.isEmpty)
        guard case .readout(let state, _) = row.control else { return XCTFail("a readout") }
        XCTAssertEqual(state, "Not granted")
        XCTAssertEqual(row.action?.id, "open-screen-recording")
        XCTAssertTrue(place("Operate", Config(), machine).attention, "the overview marks it")
        machine.screenRecording = "Granted"
        let granted = place("Operate", Config(), machine).rows.first { $0.title == "Screen recording" }!
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
        for path in ["observations.health-mb"] + Person.paths {
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
    private static let exceptions: Set<String> = ["graph.<key>"]

    func testEverySchemaLeafHasARow() {
        let sections = SettingsModel.catalog(config: Config(), machine: .init())
        var covered = Set<String>()
        for section in sections {
            for row in section.rows where !row.path.isEmpty {
                covered.insert(row.path)
            }
        }
        let declared = ConfigSchemaWalk.leafAddresses()
            .subtracting(Self.exceptions)
        let uncovered = declared.filter { leaf in
            !covered.contains(where: { leaf == $0 || leaf.hasPrefix($0 + ".") })
        }
        XCTAssertEqual(uncovered.sorted(), [],
                       "config leaves with no settings row — give them one or retire them")
    }

    /// Lodestar is International Orange and nothing else: no accent row, and
    /// on the appearance side of the config only Eye comfort, a switch in
    /// Sound and display.
    func testThereIsNoAccentRowAndEyeComfortIsTheOneAppearanceSetting() {
        let sections = SettingsModel.catalog(config: Config(), machine: .init())
        let paths = sections.flatMap { $0.rows }.compactMap { $0.path }
        XCTAssertEqual(paths.filter { $0.hasPrefix("appearance.") }, ["appearance.eye-comfort"],
                       "an appearance setting may change how Lodestar looks, never what it asks; this one has passed the sentence")
        XCTAssertFalse(sections.flatMap { $0.rows }.contains { $0.title == "Accent" })
        let general = sections.first { $0.name == "General" }!
        XCTAssertEqual(general.rows.compactMap(\.letter).prefix(4), ["a", "b", "c", "d"], "the letters stay one per row, in reading order")
        let eye = general.rows.first { $0.path == "appearance.eye-comfort" }
        XCTAssertEqual(eye?.title, "Eye comfort")
        XCTAssertEqual(eye?.group, "Sound and display")
        XCTAssertNotNil(eye?.letter, "a row has its key like the rest")
        XCTAssertEqual(eye?.detail, "Lodestar adjusts its own surfaces through the day to be easier on your eyes: dimmer and softer after sunset, dimmer still late at night, and quieter when you're not using them. What you copy and view is never changed")
        if case .toggle(let on)? = eye?.control { XCTAssertTrue(on, "on by default") } else { XCTFail("one switch") }
        XCTAssertEqual(eye?.isDefault, true)
    }

    func testTheRetiredInteractionSwitchesAreGone() {
        let sections = SettingsModel.catalog(config: Config(), machine: .init())
        let paths = sections.flatMap { $0.rows }.compactMap { $0.path }
        XCTAssertFalse(paths.contains("select.commit-on-unique"))
        XCTAssertFalse(paths.contains("guide.fade"))
    }
}
