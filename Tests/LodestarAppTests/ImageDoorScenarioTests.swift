import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The image door and the save band, driven through the tap the way a
/// hand drives them: `⇧⌘V`, `⌘A`, `E` opens an image card large above
/// the strip; `esc` steps back; `S` turns the band into a name, and `⏎`
/// writes the file where the name and the config say.
final class ImageDoorScenarioTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lodestar-save-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private func stageWithImage(host: String? = nil) -> (Stage, Clipboard.Clip) {
        let stage = Stage()
        stage.clipboard.saveFolder = folder.path
        let clip = stage.seedImageClip(host: host)
        return (stage, clip)
    }

    private func openPanel(_ stage: Stage) {
        stage.openStrip()
        stage.chord("a", .maskCommand)
    }

    private func type(_ stage: Stage, _ text: String) {
        for character in text {
            stage.press(character == " " ? "space" : String(character))
        }
    }

    func testAnImageCardOffersViewAndSaveAs() {
        let (stage, clip) = stageWithImage()
        openPanel(stage)
        let keys = HotkeyEngine.panelActions(for: clip).map(\.key)
        XCTAssertEqual(keys, ["P", "E", "S", "D", "X"])
        let labels = HotkeyEngine.panelActions(for: clip).map(\.label)
        XCTAssertTrue(labels.contains("View"))
        XCTAssertTrue(labels.contains("Save as"))
        XCTAssertFalse(labels.contains("Edit"), "an image has no text to edit")
    }

    func testEOpensTheImageLargeAboveTheStrip() {
        let (stage, _) = stageWithImage()
        openPanel(stage)
        stage.press("e")
        XCTAssertEqual(stage.engine.grammarState, .pasteImage(searching: false))
        Stage.pump()
        XCTAssertTrue(stage.engine.imageDoor.isVisible, "the door stands")
        XCTAssertFalse(stage.draft.isOpen, "the draft is not the image's door")
        XCTAssertTrue(stage.engine.strip.isVisible, "the strip waits beneath")
        XCTAssertTrue(stage.engine.strip.pinsHidden, "the pin column steps aside")
        XCTAssertEqual(stage.engine.imageDoor.shownImageSize, NSSize(width: 320, height: 200),
                       "a small image stands at one point per pixel")
        XCTAssertTrue(stage.engine.imageDoor.shownCaption?.hasPrefix("320×200 · Brave") == true)
        XCTAssertTrue(stage.pasteboard.isEmpty, "the door never touches the pasteboard")
        XCTAssertEqual(stage.stripPastes, 0)
    }

    func testEscapeStepsBackToTheStripWithThePinsBack() {
        let (stage, _) = stageWithImage()
        openPanel(stage)
        stage.press("e")
        Stage.pump()
        stage.press("escape")
        XCTAssertFalse(stage.engine.imageDoor.isVisible)
        XCTAssertEqual(stage.engine.grammarState, .paste(searching: false))
        XCTAssertTrue(stage.engine.strip.isVisible)
        XCTAssertFalse(stage.engine.strip.pinsHidden)
        stage.press("escape")
        XCTAssertEqual(stage.engine.grammarState, .idle)
        XCTAssertFalse(stage.engine.strip.isVisible)
    }

    func testReturnInTheDoorStepsBackToo() {
        let (stage, _) = stageWithImage()
        openPanel(stage)
        stage.press("e")
        Stage.pump()
        stage.press("return")
        XCTAssertFalse(stage.engine.imageDoor.isVisible)
        XCTAssertEqual(stage.engine.grammarState, .paste(searching: false))
        XCTAssertEqual(stage.stripPastes, 0, "the strip is the only paste surface")
    }

    func testTheStripsToggleTakesTheDoorDownWithIt() {
        let (stage, _) = stageWithImage()
        openPanel(stage)
        stage.press("e")
        Stage.pump()
        stage.openStrip()
        XCTAssertFalse(stage.engine.imageDoor.isVisible)
        XCTAssertFalse(stage.engine.strip.isVisible)
        XCTAssertEqual(stage.engine.grammarState, .idle)
    }

    func testSOnTheCardOpensTheBandWithTheOfferedName() {
        let (stage, clip) = stageWithImage(host: "github.com")
        openPanel(stage)
        stage.press("s")
        XCTAssertEqual(stage.engine.grammarState, .pasteSave(searching: false))
        let band = stage.engine.strip.shownSave
        XCTAssertEqual(band?.name, "")
        XCTAssertEqual(band?.offered, Clipboard.imageFileName(for: clip))
        XCTAssertTrue(band?.offered.hasPrefix("github.com ") == true)
        XCTAssertEqual(band?.folder, folder.path)
        XCTAssertTrue(stage.engine.strip.isVisible)
        XCTAssertFalse(stage.engine.strip.pinsHidden, "the band is not a door")
    }

    func testReturnWithNothingTypedWritesTheOfferedNameIntoTheFolder() {
        let (stage, clip) = stageWithImage()
        var flashed: [String] = []
        stage.clipboard.flash = { flashed.append($0) }
        openPanel(stage)
        stage.press("s")
        stage.press("return")
        Stage.pump()
        let expected = folder.appendingPathComponent(Clipboard.imageFileName(for: clip)).path
        XCTAssertEqual(stage.clipboard.lastSavedPath, expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected))
        XCTAssertEqual(NSImage(contentsOfFile: expected)?.size, NSSize(width: 320, height: 200))
        XCTAssertEqual(stage.engine.grammarState, .paste(searching: false))
        XCTAssertNil(stage.engine.strip.shownSave, "the band is gone")
        XCTAssertTrue(stage.engine.strip.isVisible, "the strip stays")
        XCTAssertEqual(flashed.last, "⌂ saved \(Clipboard.imageFileName(for: clip)) to \(folder.lastPathComponent)")
    }

    func testATypedNameWithASubfolderAndAFormatIsHonored() {
        let (stage, _) = stageWithImage()
        openPanel(stage)
        stage.press("s")
        type(stage, "reports/chart.jpg")
        XCTAssertEqual(stage.engine.strip.shownSave?.name, "reports/chart.jpg")
        stage.press("return")
        Stage.pump()
        let expected = folder.appendingPathComponent("reports/chart.jpg").path
        XCTAssertEqual(stage.clipboard.lastSavedPath, expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected))
        let bytes = try? Data(contentsOf: URL(fileURLWithPath: expected))
        XCTAssertEqual(bytes?.prefix(2), Data([0xFF, 0xD8]), "a JPEG, as the name asked")
    }

    func testEscapeInTheBandWritesNothing() {
        let (stage, _) = stageWithImage()
        openPanel(stage)
        stage.press("s")
        type(stage, "chart")
        stage.press("escape")
        Stage.pump()
        XCTAssertNil(stage.clipboard.lastSavedPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(stage.engine.grammarState, .paste(searching: false))
        XCTAssertNil(stage.engine.strip.shownSave)
    }

    func testDeleteEditsTheNameLikeAnyField() {
        let (stage, _) = stageWithImage()
        openPanel(stage)
        stage.press("s")
        type(stage, "one two")
        stage.press("delete")
        XCTAssertEqual(stage.engine.strip.shownSave?.name, "one tw")
        stage.chord("delete", .maskAlternate)
        XCTAssertEqual(stage.engine.strip.shownSave?.name, "one ")
        stage.chord("delete", .maskCommand)
        XCTAssertEqual(stage.engine.strip.shownSave?.name, "")
    }

    func testSInsideTheDoorGoesOnToTheBandForTheSameCard() {
        let (stage, clip) = stageWithImage()
        openPanel(stage)
        stage.press("e")
        Stage.pump()
        stage.press("s")
        XCTAssertFalse(stage.engine.imageDoor.isVisible, "the door gives way to the band")
        XCTAssertEqual(stage.engine.grammarState, .pasteSave(searching: false))
        XCTAssertEqual(stage.engine.strip.shownSave?.offered, Clipboard.imageFileName(for: clip))
        stage.press("return")
        Stage.pump()
        XCTAssertNotNil(stage.clipboard.lastSavedPath)
    }

    func testTheRecordSaysViewAndSave() {
        let (stage, _) = stageWithImage()
        openPanel(stage)
        stage.press("e")
        Stage.pump()
        stage.press("s")
        stage.press("return")
        Stage.pump()
        stage.press("escape")
        XCTAssertEqual(stage.lastPaste?.action, "acted")
        XCTAssertEqual(stage.lastPaste?.row, "save")
    }
}
