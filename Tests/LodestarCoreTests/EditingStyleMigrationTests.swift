import XCTest
@testable import LodestarCore

/// The draft's Editing style arrived after Vim was the only way to edit it.
/// A Mac that had run Lodestar keeps Vim, once; a new Mac starts on Standard;
/// and a hand that picks Standard stays there across launches, though the
/// sparse config drops a key set to its default.
final class EditingStyleMigrationTests: XCTestCase {
    private var directory: URL!
    private var config: URL { directory.appendingPathComponent("lodestar.json") }
    private var state: URL { directory.appendingPathComponent("state.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-style-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    /// What a launch of this build makes of the config on disk.
    private var style: Draft.EditingStyle {
        var problems: [String] = []
        return Config.build(from: Config.userTree(from: config) ?? [:], problems: &problems).draftEditingStyle
    }

    /// A launch: a state store read from the file, as the app reads it.
    @discardableResult
    private func launch(ranBefore: Bool) throws -> Bool {
        try EditingStyleMigration.run(ranBefore: ranBefore, state: SealedFixture.stateStore(state), config: config)
    }

    private func existingInstall() throws {
        try #"{"scroll": {"speed": 2200}}"#.write(to: config, atomically: true, encoding: .utf8)
    }

    func testAMacThatRanBeforeKeepsVimAndItsOtherSettings() throws {
        try existingInstall()
        XCTAssertTrue(try launch(ranBefore: true))
        XCTAssertEqual(style, .vim)
        XCTAssertEqual(Config.userTree(from: config)?.value(at: ["scroll", "speed"]), .int(2200))
    }

    func testItHappensOnceAndAHandThatPicksStandardStaysThere() throws {
        try existingInstall()
        try launch(ranBefore: true)
        XCTAssertEqual(style, .vim)

        // The hand picks Standard in Settings: the sparse file drops the key.
        try Config.edit(in: config) { tree in
            Json.setting(tree, path: ["draft", "editing-style"], to: .string("standard"))!
        }
        XCTAssertEqual(style, .standard)
        XCTAssertNil(Config.userTree(from: config)?.value(at: ["draft", "editing-style"]))

        // Launch after launch, the file still looks like an old one.
        for _ in 0..<3 {
            XCTAssertFalse(try launch(ranBefore: true))
            XCTAssertEqual(style, .standard)
        }
    }

    func testANewMacStartsOnStandardAndIsNeverGivenVimLater() throws {
        XCTAssertFalse(try launch(ranBefore: false))
        XCTAssertEqual(style, .standard)
        // The next launch finds the config the first one made.
        try existingInstall()
        XCTAssertFalse(try launch(ranBefore: true))
        XCTAssertEqual(style, .standard)
    }

    /// A launch as the app makes it: whether the state file was there is
    /// read before the store opens.
    @discardableResult
    private func appLaunch() throws -> Bool {
        let ranBefore = SealedFixture.stateStore(state, load: false).existsOnDisk
        return try EditingStyleMigration.run(ranBefore: ranBefore, state: SealedFixture.stateStore(state), config: config)
    }

    /// The command line makes the config file, so a new Mac that ran a
    /// command first has one; it does not make the state.
    func testANewMacThatRanACommandFirstIsNotGivenVim() throws {
        try existingInstall()
        XCTAssertFalse(SealedFixture.stateStore(state, load: false).existsOnDisk)
        XCTAssertFalse(try appLaunch())
        XCTAssertEqual(style, .standard)
        XCTAssertTrue(SealedFixture.stateStore(state, load: false).existsOnDisk, "and the first launch leaves the record")
        XCTAssertFalse(try appLaunch())
        XCTAssertEqual(style, .standard)
    }

    func testAMacWithAStateFileFromBeforeKeepsVimAndALostStateFileReadsAsNew() throws {
        try existingInstall()
        // What an earlier build left: a state with no word about the style.
        SealedFixture.stateStore(state).save()
        XCTAssertTrue(try appLaunch())
        XCTAssertEqual(style, .vim)

        // A Mac that chose Standard, then lost its state file: new again.
        try Config.edit(in: config) { Json.setting($0, path: ["draft", "editing-style"], to: .string("standard"))! }
        try FileManager.default.removeItem(at: SealedFixture.sealedState(state))
        XCTAssertFalse(try appLaunch())
        XCTAssertEqual(style, .standard)
    }

    /// A state that started fresh cannot say whether the choice was made.
    func testADamagedStateSettlesWithoutGivingAStandardHandVim() throws {
        try existingInstall()
        SealedFixture.stateStore(state).save()
        try Data("not a sealed file".utf8).write(to: SealedFixture.sealedState(state))
        try? FileManager.default.removeItem(at: SealedFixture.sealedState(state).appendingPathExtension("bak"))
        let store = SealedFixture.stateStore(state)
        XCTAssertNotNil(store.bootWarning, "the state started fresh and said so")
        XCTAssertFalse(try EditingStyleMigration.run(ranBefore: true, state: store, config: config))
        XCTAssertEqual(style, .standard)
        XCTAssertTrue(store.editingStyleSettled, "and it is not asked again")
    }

    func testAStateThatIsNotKnownYetSettlesNothing() throws {
        try existingInstall()
        let unread = SealedFixture.stateStore(state, load: false)
        XCTAssertFalse(try EditingStyleMigration.run(ranBefore: true, state: unread, config: config))
        XCTAssertEqual(style, .standard)
        XCTAssertFalse(unread.editingStyleSettled)

        unread.load()
        XCTAssertTrue(try EditingStyleMigration.run(ranBefore: true, state: unread, config: config))
        XCTAssertEqual(style, .vim)
    }

    func testAStyleTheFileAlreadyNamesIsTheHandsOwn() throws {
        try #"{"draft": {"editing-style": "vim"}}"#.write(to: config, atomically: true, encoding: .utf8)
        XCTAssertFalse(try launch(ranBefore: true), "nothing written")
        XCTAssertEqual(style, .vim)
        XCTAssertTrue(SealedFixture.stateStore(state).editingStyleSettled)
    }

    func testAConfigThatDoesNotParseIsNotWrittenOverAndIsTriedAgain() throws {
        try "{ broken".write(to: config, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try launch(ranBefore: true))
        XCTAssertFalse(SealedFixture.stateStore(state).editingStyleSettled)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "{ broken")

        try existingInstall()
        XCTAssertTrue(try launch(ranBefore: true))
        XCTAssertEqual(style, .vim)
    }
}
