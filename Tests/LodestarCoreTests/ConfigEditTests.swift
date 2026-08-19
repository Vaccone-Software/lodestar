import XCTest
@testable import LodestarCore

/// The one read-modify-write over the config file.
///
/// Four writers used to open with their own read and they disagreed about
/// what a parse failure meant. Two collapsed it to an empty tree, so a
/// hand-edit typo plus one menu-bar toggle replaced the user's whole
/// config — graph, profiles, links, routes, key overrides — with the
/// single key being set, silently and with no backup. These tests hold
/// the rule that replaced them: a file that exists and does not parse is
/// never written over.
final class ConfigEditTests: XCTestCase {
    private var directory: URL!
    private var file: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-config-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("lodestar.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func write(_ text: String) {
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }

    private var onDisk: String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }

    // MARK: - The happy path

    func testEditsAnExistingConfigAndKeepsEverythingElse() throws {
        write(#"{"graph": {"s": "Slack"}, "scroll": {"speed": 2200}}"#)
        try Config.edit(in: file) { tree in
            Json.setting(tree, path: ["scroll", "speed"], to: .int(2400))!
        }
        let round = try Json.parse(onDisk)
        XCTAssertEqual(round.value(at: ["scroll", "speed"]), .int(2400))
        XCTAssertEqual(round.value(at: ["graph", "s"]), .string("Slack"), "the rest rides untouched")
        XCTAssertEqual(round["version"], .string(Lodestar.version), "every write stamps the release")
    }

    /// An absent file is a first write, not a failure.
    func testWritesAFreshConfigWhenNoneExists() throws {
        try Config.edit(in: file) { tree in
            Json.setting(tree, path: ["scroll", "speed"], to: .int(2400))!
        }
        XCTAssertEqual(try Json.parse(onDisk).value(at: ["scroll", "speed"]), .int(2400))
    }

    // MARK: - The rule

    /// The regression this exists for.
    func testRefusesToWriteOverAConfigThatDoesNotParse() {
        // A `//` comment, which is the typo people actually make in a file
        // whose schema they are reading in an editor. (A trailing comma,
        // the other obvious candidate, is tolerated by the parser.)
        let broken = "{\n  // mine\n  \"graph\": {\"s\": \"Slack\"}\n}"
        write(broken)

        XCTAssertThrowsError(try Config.edit(in: file) { tree in
            Json.setting(tree, path: ["scroll", "speed"], to: .int(2400))!
        }) { error in
            guard case Config.EditError.unparsed = error else {
                return XCTFail("expected .unparsed, got \(error)")
            }
        }
        XCTAssertEqual(onDisk, broken, "the user's file must be exactly as they left it")
    }

    /// A file that exists but is not decodable UTF-8 is still the user's.
    func testRefusesToWriteOverAConfigThatIsNotUTF8() {
        try? Data([0x7B, 0x80, 0x7D]).write(to: file)  // {<invalid>}

        XCTAssertThrowsError(try Config.edit(in: file) { _ in ["a": .bool(true)] }) { error in
            guard case Config.EditError.unreadable = error else {
                return XCTFail("expected .unreadable, got \(error)")
            }
        }
        XCTAssertEqual(try? Data(contentsOf: file), Data([0x7B, 0x80, 0x7D]))
    }

    /// A transform that gives up leaves the file alone too.
    func testATransformThatThrowsWritesNothing() {
        let original = #"{"graph": {"s": "Slack"}}"#
        write(original)
        struct Nope: Error {}

        XCTAssertThrowsError(try Config.edit(in: file) { _ in throw Nope() })
        XCTAssertEqual(onDisk, original)
    }

    // MARK: - Load

    /// `load` shares the rule: an unreadable file becomes a problem the
    /// human can see, never a default written over the top of it. Both
    /// `check` and `diagnose` reach this path, so getting it wrong meant
    /// the diagnostic destroyed the evidence.
    func testLoadReportsAnUnparseableFileWithoutReplacingIt() {
        let broken = "{ not json at all"
        write(broken)
        let (config, problems) = Config.load(from: file)
        XCTAssertEqual(onDisk, broken, "load must never write over a file it could not read")
        XCTAssertFalse(problems.isEmpty, "and it must say so")
        XCTAssertEqual(config.scrollSpeed, Config().scrollSpeed, "defaults in memory only")
    }

    /// The same, for a file that exists and is not decodable UTF-8 —
    /// which `String(contentsOf:encoding:)` reports identically to "no
    /// such file", and which used to take the write-a-fresh-default branch.
    func testLoadDoesNotReplaceANonUTF8File() {
        let bytes = Data([0x7B, 0x80, 0x7D])
        try? bytes.write(to: file)
        let (_, problems) = Config.load(from: file)
        XCTAssertEqual(try? Data(contentsOf: file), bytes)
        XCTAssertTrue(problems.contains { $0.contains("UTF-8") }, "\(problems)")
    }

    /// A genuine first run still gets a file.
    func testLoadWritesDefaultsOnlyWhenNothingIsThere() {
        let (_, problems) = Config.load(from: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(problems, [])
        XCTAssertEqual(try? Json.parse(onDisk)["version"], .string(Lodestar.version))
    }

    /// Values the config cannot hold are reported through `load`, not
    /// dropped in silence — a `-1e400` used to survive as -infinity and
    /// make the next write emit `-inf`, which is not JSON.
    func testLoadReportsValuesItHadToDrop() {
        write(#"{"scroll": {"speed": -1e400}}"#)
        let (_, problems) = Config.load(from: file)
        XCTAssertTrue(problems.contains { $0.contains("finite") }, "\(problems)")
    }
}
