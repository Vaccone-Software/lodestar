import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// Every menu in Settings changes its setting, by the hand's two roads: a
/// click on a choice in the open menu, and the menu's own choosing (the
/// keyboard's return). 0.53 and 0.54 shipped menus whose clicks landed on a
/// line's drawing and went no further, so nothing could be chosen at all;
/// these tests click the real menu views the menu shows.
final class SettingsChoiceTests: XCTestCase {
    private struct Written: Equatable {
        var path: String
        var value: ConfigValue?
    }

    private func controller(_ written: @escaping (Written) -> Void) -> SettingsController {
        let settings = SettingsController.preview(-1)
        settings.apply = { path, value in written(Written(path: path, value: value)); return nil }
        settings.applyEntries = { removals, sets in
            for path in removals { written(Written(path: path.joined(separator: "."), value: nil)) }
            for (path, value) in sets { written(Written(path: path.joined(separator: "."), value: value)) }
            return nil
        }
        return settings
    }

    /// What choosing `option` on the row at `path` must write: the value, or
    /// for Not set on a key with no default, the line's removal.
    private func expected(_ path: String, _ option: String) -> [Written] {
        let hasDefault = ConfigFile.defaultTree.value(at: path.split(separator: ".").map(String.init)) != nil
        if option.isEmpty, !hasDefault, !Person.paths.contains(path) { return [Written(path: path, value: nil)] }
        return [Written(path: path, value: .string(option))]
    }

    private func itemViews(of popup: NSPopUpButton) throws -> [(item: NSMenuItem, view: ChoiceMenuItemView)] {
        let menu = try XCTUnwrap(popup.menu)
        let delegate = try XCTUnwrap(menu.delegate, "the menu draws its own items")
        delegate.menuNeedsUpdate?(menu)
        return try menu.items.map { ($0, try XCTUnwrap($0.view as? ChoiceMenuItemView, "every item is drawn by the line")) }
    }

    private func click(_ view: ChoiceMenuItemView) throws {
        // Anywhere on the line: its middle, where the words are.
        let point = NSPoint(x: view.frame.midX, y: view.frame.midY)
        let hit = try XCTUnwrap(view.hitTest(point))
        XCTAssertTrue(hit === view, "the line takes the click, not the drawing inside it")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                         windowNumber: 0, context: nil, eventNumber: 0,
                                                         clickCount: 1, pressure: 1))
            type == .leftMouseDown ? hit.mouseDown(with: event) : hit.mouseUp(with: event)
        }
    }

    func testEveryChoiceInEveryPlaceIsWrittenWhenClicked() throws {
        var written: [Written] = []
        let settings = controller { written.append($0) }
        var clicked = 0
        var paths: Set<String> = []
        for place in 0..<10 {
            settings.renderForTesting(place: place)
            for choice in settings.choicesForTesting {
                let items = try itemViews(of: choice.popup)
                XCTAssertEqual(items.count, choice.options.count, choice.path)
                for (index, option) in choice.options.enumerated() where items[index].item.isEnabled {
                    written = []
                    try click(items[index].view)
                    XCTAssertEqual(written, expected(choice.path, option), "\(choice.path) → \(option.isEmpty ? "Not set" : option)")
                    XCTAssertEqual(choice.popup.indexOfSelectedItem, index, "the menu shows what was chosen")
                    clicked += 1
                }
                paths.insert(choice.path)
            }
        }
        // The rows this was found on, by name, so a place that stops drawing
        // its menus fails here rather than passing on nothing.
        for path in ["health.sex", "health.hand", "health.typing", "lode.trigger", "draft.model"] {
            XCTAssertTrue(paths.contains(path), "\(path) was clicked")
        }
        XCTAssertGreaterThanOrEqual(clicked, 36, "every enabled choice of every menu")
        settings.close()
    }

    func testAChoiceIsWrittenWhenTheMenuChoosesIt() throws {
        var written: [Written] = []
        let settings = controller { written.append($0) }
        settings.openForTesting(place: "Observations")
        let sex = try XCTUnwrap(settings.choicesForTesting.first { $0.path == "health.sex" })
        let menu = try XCTUnwrap(sex.popup.menu)
        let female = try XCTUnwrap(sex.options.firstIndex(of: "female"))
        menu.performActionForItem(at: female)
        XCTAssertEqual(written, [Written(path: "health.sex", value: .string("female"))])
        settings.close()
    }

    /// A disabled choice (a model this Mac is too small for) is drawn and
    /// cannot be taken.
    func testADisabledChoiceWritesNothing() throws {
        var written: [Written] = []
        let settings = controller { written.append($0) }
        for place in 0..<10 {
            settings.renderForTesting(place: place)
            for choice in settings.choicesForTesting {
                for (item, view) in try itemViews(of: choice.popup) where !item.isEnabled {
                    try click(view)
                }
            }
        }
        XCTAssertEqual(written, [])
        settings.close()
    }
}
