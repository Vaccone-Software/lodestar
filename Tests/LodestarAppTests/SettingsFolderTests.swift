import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// A folder is chosen, not typed (0.57): the row's letter or its Choose key
/// opens the Mac's folder panel where the folder is, and the folder chosen is
/// written with the home folder as `~`. Cancelled, nothing is written.
final class SettingsFolderTests: XCTestCase {
    private let keep = 3

    private func window(_ written: @escaping (String, ConfigValue) -> Void) -> SettingsController {
        let settings = SettingsController()
        settings.apply = { path, value in written(path, value); return nil }
        return settings
    }

    private func letter(_ settings: SettingsController) throws -> String {
        let index = try XCTUnwrap(settings.sectionsForTesting[keep].rows.firstIndex { $0.path == "clipboard.save-to" })
        return SettingsModel.labelAlphabet[index]
    }

    func testSaveImagesToIsAFolder() throws {
        let rows = SettingsModel.catalog(config: Config(), machine: .init())[keep].rows
        let row = try XCTUnwrap(rows.first { $0.path == "clipboard.save-to" })
        XCTAssertEqual(row.control, .folder("~/Downloads"))
        XCTAssertTrue(row.isDefault)
    }

    func testTheLetterOpensThePanelWhereTheFolderIsAndWritesTheChoice() throws {
        var written: [(String, ConfigValue)] = []
        let settings = window { written.append(($0, $1)) }
        var openedAt: URL?
        settings.chooseFolder = { start in
            openedAt = start
            return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures/Clips", isDirectory: true)
        }
        settings.renderForTesting(place: keep)
        settings.pressForTesting(try letter(settings))
        XCTAssertEqual(openedAt?.standardizedFileURL.path,
                       URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads").path)
        XCTAssertEqual(written.map(\.0), ["clipboard.save-to"])
        XCTAssertEqual(written.first?.1, .string("~/Pictures/Clips"), "the home folder written as ~")
        settings.close()
    }

    func testACancelledPanelWritesNothing() throws {
        var written: [(String, ConfigValue)] = []
        let settings = window { written.append(($0, $1)) }
        settings.chooseFolder = { _ in nil }
        settings.renderForTesting(place: keep)
        settings.pressForTesting(try letter(settings))
        XCTAssertTrue(written.isEmpty)
        settings.close()
    }
}
