import XCTest
@testable import lodestar
@testable import LodestarCore

/// The sheet inside a lens: every key the lens owns, and the whole system
/// when no lens is up.
final class ModeSheetTests: XCTestCase {
    private func keys(_ sections: [CheatSheet.Section]) -> [String] {
        sections.flatMap { $0.rows.map(\.key) }
    }

    func testScrollsSheetNamesEveryKeyTheModeOwns() {
        let stage = Stage()
        let sections = stage.engine.cheatSections(for: .scroll)
        XCTAssertEqual(sections.map(\.header), ["scroll"])
        for key in ["J K", "H L", "D U", "G G", "0 $", "/", "esc", "?"] {
            XCTAssertTrue(keys(sections).contains(key), "\(key) is on the sheet")
        }
    }

    func testTheAimBandsSheet() {
        let stage = Stage()
        let sections = stage.engine.cheatSections(for: .scrollAim)
        XCTAssertEqual(sections.map(\.header), ["aim"])
        for key in ["⇧A…Z", "⌫", "⌘V", "esc"] { XCTAssertTrue(keys(sections).contains(key)) }
    }

    func testClickAndSelectSheets() {
        let stage = Stage()
        let click = keys(stage.engine.cheatSections(for: .hints(sticky: false)))
        XCTAssertTrue(click.contains("⇧A…Z") && click.contains("⇧;") && click.contains("esc"))
        let select = keys(stage.engine.cheatSections(for: .select))
        XCTAssertTrue(select.contains("⌘C") && select.contains("⇧A…Z") && select.contains("esc"))
    }

    func testIdleGetsTheWholeSystem() {
        let stage = Stage()
        let sections = stage.engine.cheatSections(for: .idle)
        XCTAssertTrue(sections.map(\.header).contains("verbs"))
        XCTAssertTrue(keys(sections).contains("`"), "scroll's door is on the full sheet")
    }

    func testEveryLensSheetHasAWayOutAndTheSheetKey() {
        let stage = Stage()
        for state in [EngineCore.State.scroll, .scrollAim, .hints(sticky: true), .select] {
            let k = keys(stage.engine.cheatSections(for: state))
            XCTAssertTrue(k.contains("esc"), "\(state) says how to leave")
            XCTAssertTrue(k.contains("?"), "\(state) names the sheet's own key")
        }
    }
}
