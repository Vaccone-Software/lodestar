import XCTest
@testable import LodestarCore

final class SettingsModelTests: XCTestCase {
    private var sections: [SettingsModel.Section] {
        SettingsModel.catalog(config: Config(), machine: .init())
    }

    func testNinePanesInTheAgreedOrder() {
        XCTAssertEqual(sections.map(\.name),
                       ["General", "Permissions", "Gestures", "Interaction", "Clipboard",
                        "Web", "Meetings", "Coach", "Advanced"])
        XCTAssertLessThanOrEqual(sections.count, 9,
                                 "digits address panes; a tenth pane has no key")
    }

    func testEveryConfigRowWearsItsPath() {
        for section in sections where section.name != "Permissions" {
            for row in section.rows {
                if case .readout = row.control { continue }
                XCTAssertFalse(row.path.isEmpty,
                               "\(section.name) · \(row.title) hides its config path")
            }
        }
    }

    func testPermissionsReadTheMachineNeverTheConfig() {
        let permissions = sections.first { $0.name == "Permissions" }!
        XCTAssertEqual(permissions.rows.count, 3)
        for row in permissions.rows {
            XCTAssertTrue(row.path.isEmpty, "\(row.title) claims a config path")
            guard case .readout = row.control else {
                return XCTFail("\(row.title) is not a readout")
            }
        }
    }

    func testEveryGestureRowWearsItsKeycaps() {
        let gestures = sections.first { $0.name == "Gestures" }!
        for row in gestures.rows {
            XCTAssertFalse(row.keycaps.isEmpty, "\(row.title) shows no keys")
            guard case .toggle = row.control else {
                return XCTFail("\(row.title) is not a feature toggle")
            }
        }
        XCTAssertTrue(gestures.rows.contains { $0.path == "clipboard.enabled" },
                      "the clipboard is a feature and lives with the features")
        XCTAssertFalse(gestures.rows.contains { $0.title.contains("lode ") },
                       "titles are feature names, not guide copy")
    }

    func testCoachRowDimsWithoutObservations() {
        var config = Config()
        config.observationsEnabled = false
        let catalog = SettingsModel.catalog(config: config, machine: .init())
        let coach = catalog.first { $0.name == "Coach" }!
        let row = coach.rows.first { $0.path == "coach.enabled" }!
        XCTAssertTrue(row.dimmed, "the coach cannot speak without observations")
        if case .toggle(let value) = row.control {
            XCTAssertFalse(value, "a dimmed coach never shows as on")
        }
    }

    func testLabelsAreUniqueAndNeverDigits() {
        let most = sections.map(\.rows.count).max() ?? 0
        let labels = SettingsModel.labels(for: most)
        XCTAssertEqual(labels.count, most, "every visible row gets a label")
        XCTAssertEqual(Set(labels).count, labels.count)
        XCTAssertTrue(labels.allSatisfy { $0.count == 1 && Int($0) == nil },
                      "digits are pane addresses and must never label a row")
    }

    func testSearchFlattensAcrossPanesAndMatchesPaths() {
        let hits = SettingsModel.search("speed", in: sections)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.sectionName, "Interaction")
        XCTAssertFalse(SettingsModel.search("scroll", in: sections).isEmpty,
                       "the config path is part of the haystack")
        XCTAssertTrue(SettingsModel.search("", in: sections).isEmpty,
                      "search is a verb, not a view")
    }

    func testEscapePopsExactlyOneLayer() {
        XCTAssertEqual(SettingsModel.popped(.editing), .browsing)
        XCTAssertEqual(SettingsModel.popped(.searching), .browsing)
        XCTAssertNil(SettingsModel.popped(.browsing), "the bottom layer closes")
    }

    func testDefaultConfigReadsAsDefault() {
        for section in sections {
            for row in section.rows where !row.path.isEmpty {
                XCTAssertTrue(row.isDefault,
                              "\(row.path) marked changed on a default config")
            }
        }
    }

    func testChangedValueLosesItsDefaultMark() {
        var config = Config()
        config.scrollSpeed = 2400
        config.meetingsEnabled = true
        let catalog = SettingsModel.catalog(config: config, machine: .init())
        let interaction = catalog.first { $0.name == "Interaction" }!
        XCTAssertFalse(interaction.rows.first { $0.path == "scroll.speed" }!.isDefault)
        let meetings = catalog.first { $0.name == "Meetings" }!
        XCTAssertFalse(meetings.rows.first { $0.path == "meetings.enabled" }!.isDefault)
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
}
