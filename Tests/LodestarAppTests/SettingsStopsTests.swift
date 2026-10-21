import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// A setting with an order is a row of stops (Ceramic): every value a key,
/// the current one the slab, `1`–`8` choosing directly and `h` and `l`
/// stepping. And every row leads with its key.
final class SettingsStopsTests: XCTestCase {
    /// Speak's rows by reading order: Draft (a), Microphone (b), Model (c).
    private let modelLetter = "c"

    private func speak() -> (SettingsController, () -> [String]) {
        let settings = SettingsController.preview(-1)
        var written: [String] = []
        settings.apply = { [unowned settings] path, value in
            if path == "draft.model", case .string(let model) = value {
                settings.config.draftModel = model
                written.append(model)
            }
            return nil
        }
        settings.renderForTesting(place: 4)
        return (settings, { written })
    }

    private func stops(in settings: SettingsController) -> (slab: [String], keys: [String]) {
        let slabs = settings.viewsForTesting(of: StopSlab.self).map { $0.legend.stringValue }
        let model = ["Automatic", "Apple", "Standard", "Full", "Max"]
        let keys = settings.viewsForTesting(of: KeyFace.self).map(\.label.stringValue).filter { model.contains($0) }
        return (slabs, keys)
    }

    func testTheDictationModelIsARowOfKeysAndTheCurrentOneIsTheSlab() {
        let (settings, _) = speak()
        let drawn = stops(in: settings)
        XCTAssertEqual(drawn.slab, ["Automatic"], "the current stop is the slab")
        XCTAssertEqual(drawn.keys, ["Apple", "Standard", "Full", "Max"], "every other stop is a key, in order")
        XCTAssertTrue(settings.viewsForTesting(of: NSPopUpButton.self)
            .allSatisfy { $0.itemTitles.first != "Automatic" }, "the old popup is gone from the row")
        settings.close()
    }

    func testDigitsJumpToAStopAndHAndLStepAfterThePressOfTheRowsLetter() {
        let (settings, written) = speak()
        // Digits are places until the keys are on the row.
        settings.pressForTesting("3")
        XCTAssertEqual(settings.placeForTesting, 3, "before the letter, 3 is Keep")
        settings.pressForTesting("4")
        settings.pressForTesting(modelLetter)
        settings.pressForTesting("3")
        XCTAssertEqual(written(), ["standard"], "3 is the third stop")
        XCTAssertEqual(settings.placeForTesting, 4, "and a digit on the row did not change the place")
        XCTAssertEqual(stops(in: settings).slab, ["Standard"])
        settings.pressForTesting("l")
        settings.pressForTesting("l")
        settings.pressForTesting("l")
        XCTAssertEqual(written(), ["standard", "full", "max"], "l steps right and stops at the end")
        XCTAssertEqual(stops(in: settings).slab, ["Max"])
        settings.pressForTesting("h")
        XCTAssertEqual(stops(in: settings).slab, ["Full"], "h steps left")
        settings.pressForTesting("1")
        XCTAssertEqual(stops(in: settings).slab, ["Automatic"])
        XCTAssertEqual(written().last, "", "the stored value is the one the config always held: empty is Automatic")
        settings.pressForTesting("7")
        XCTAssertEqual(written().count, 5, "a digit past the last stop is nothing")
        settings.close()
    }

    func testEscapeLetsGoOfTheRowAndOtherKeysDoTheirOwnThing() {
        let (settings, written) = speak()
        settings.pressForTesting(modelLetter)
        settings.pressForTesting("escape")
        XCTAssertEqual(settings.placeForTesting, 4, "escape lets go of the stops and does not close the place")
        settings.pressForTesting("2")
        XCTAssertEqual(settings.placeForTesting, 2, "after it, a digit is a place again")
        settings.pressForTesting("4")
        settings.pressForTesting(modelLetter)
        settings.pressForTesting("9")
        XCTAssertEqual(settings.placeForTesting, 9, "a digit that is not a stop is still a place")
        XCTAssertEqual(written(), [])
        settings.close()
    }

    func testAStopThisMacCannotChooseIsShownAndSteppedOver() {
        let settings = SettingsController.preview(-1)
        var written: [String] = []
        settings.machineState = {
            var machine = SettingsModel.MachineState()
            machine.draftModelsUnavailable = ["standard", "full"]
            return machine
        }
        settings.apply = { [unowned settings] _, value in
            if case .string(let model) = value { settings.config.draftModel = model; written.append(model) }
            return nil
        }
        settings.renderForTesting(place: 4)
        settings.pressForTesting(modelLetter)
        settings.pressForTesting("3")
        XCTAssertEqual(written, [], "a stop that cannot be chosen is not chosen by its digit")
        settings.pressForTesting("l")
        XCTAssertEqual(written, ["apple"], "l goes to the next one that can be chosen")
        settings.pressForTesting("l")
        XCTAssertEqual(written, ["apple", "max"], "stepping over the two it cannot")
        settings.close()
    }

    func testEveryRowLeadsWithItsKeyInAColumn() {
        let settings = SettingsController.preview(-1)
        settings.renderForTesting(place: 0)
        let section = SettingsModel.catalog(config: Config(), machine: .init())[0]
        let letters = settings.viewsForTesting(of: KeyFace.self).map(\.label.stringValue)
        for row in section.rows {
            XCTAssertTrue(letters.contains(row.letter!.uppercased()), "\(row.title) leads with its letter as a key")
        }
        // Every key of the column stands at one left edge.
        let column = settings.viewsForTesting(of: KeyFace.self).filter {
            section.rows.compactMap(\.letter).map { $0.uppercased() }.contains($0.label.stringValue)
        }
        let edges = Set(column.map { Int($0.convert($0.bounds, to: nil).minX.rounded()) })
        XCTAssertEqual(edges.count, 1, "one column: \(edges)")
        settings.close()
    }
}
