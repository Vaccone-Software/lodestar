import CoreGraphics
import XCTest
@testable import LodestarCore

/// Config.build is where every option in the file becomes behavior: the
/// clamps, the refusals, the fallbacks. It moved into the core so this
/// could exist — before, the most-edited validation in the project had no
/// coverage at all, and every new option was added blind.
final class ConfigBuildTests: XCTestCase {
    private func build(_ json: String) throws -> (Config, [String]) {
        var problems: [String] = []
        let root = try Json.parse(json)
        return (Config.build(from: root, problems: &problems), problems)
    }

    // MARK: - Defaults

    /// The invariant ConfigDefaults claims: an empty file yields exactly the
    /// declared defaults. If the tree and the struct ever disagree, the tree
    /// wins silently in production — so pin them together here.
    func testEmptyConfigMatchesTheDeclaredDefaults() throws {
        let (config, problems) = try build("{}")
        XCTAssertEqual(problems, [])
        let bare = Config()
        XCTAssertEqual(config.trigger, bare.trigger)
        XCTAssertEqual(config.autoReload, bare.autoReload)
        XCTAssertEqual(config.autoUpdate, bare.autoUpdate)
        XCTAssertEqual(config.startAtLogin, bare.startAtLogin)
        XCTAssertEqual(config.showMenuBar, bare.showMenuBar)
        XCTAssertEqual(config.adoptNewWindows, bare.adoptNewWindows)
        XCTAssertEqual(config.activeDisplayMode, bare.activeDisplayMode)
        XCTAssertEqual(config.scrollStep, bare.scrollStep)
        XCTAssertEqual(config.scrollSmooth, bare.scrollSmooth)
        XCTAssertEqual(config.scrollSpeed, bare.scrollSpeed)
        XCTAssertEqual(config.hintLetters, bare.hintLetters)
        XCTAssertEqual(config.hintRescanDelay, bare.hintRescanDelay)
        XCTAssertEqual(config.webFallback, bare.webFallback)
        XCTAssertEqual(config.webSearchURL, bare.webSearchURL)
    }

    func testAdoptionStaysOffUnlessAsked() throws {
        // Reversed in 0.9.x after a certificate prompt and a file reveal both
        // got adopted and hid what was being read. It must never drift back.
        XCTAssertFalse(try build("{}").0.adoptNewWindows)
        XCTAssertTrue(try build(#"{"app": {"adopt-new-windows": true}}"#).0.adoptNewWindows)
    }

    // MARK: - Clamps

    func testScrollValuesClampInsteadOfRefusing() throws {
        XCTAssertEqual(try build(#"{"scroll": {"speed": 99999}}"#).0.scrollSpeed, 4000)
        XCTAssertEqual(try build(#"{"scroll": {"speed": 1}}"#).0.scrollSpeed, 200)
        XCTAssertEqual(try build(#"{"scroll": {"step": 99999}}"#).0.scrollStep, 400)
        XCTAssertEqual(try build(#"{"scroll": {"step": 0}}"#).0.scrollStep, 10)
    }

    func testRescanDelayClamps() throws {
        XCTAssertEqual(try build(#"{"hints": {"rescan-delay": 9}}"#).0.hintRescanDelay, 2.0)
        XCTAssertEqual(try build(#"{"hints": {"rescan-delay": 0}}"#).0.hintRescanDelay, 0.1)
    }

    // MARK: - Enums fall back loudly

    func testUnknownEnumsKeepTheDefaultAndSaySo() throws {
        let (config, problems) = try build(#"{"app": {"active-display": "elsewhere"}}"#)
        XCTAssertEqual(config.activeDisplayMode, .pointer)
        XCTAssertTrue(problems.contains { $0.contains("active-display") }, "\(problems)")

        let (lode, lodeProblems) = try build(#"{"lode": {"trigger": "left-pinky"}}"#)
        XCTAssertEqual(lode.trigger, .rightCommand)
        XCTAssertTrue(lodeProblems.contains { $0.contains("trigger") }, "\(lodeProblems)")
    }

    /// Pre-0.9.11 files named the lode key "hyper" and must still work.
    func testLegacyHyperSectionStillSetsTheTrigger() throws {
        XCTAssertEqual(try build(#"{"hyper": {"trigger": "raw-hyper"}}"#).0.trigger, .rawHyper)
    }

    // MARK: - Hint letters

    func testHintLettersAreNormalisedAndDeduplicated() throws {
        XCTAssertEqual(try build(#"{"hints": {"letters": "ASDF"}}"#).0.hintLetters, "asdf")
        XCTAssertEqual(try build(#"{"hints": {"letters": "aabbc"}}"#).0.hintLetters, "abc",
                       "duplicates would mint colliding labels")
        XCTAssertEqual(try build(#"{"hints": {"letters": "a1b!c"}}"#).0.hintLetters, "abc")
    }

    func testTooFewHintLettersIsRefusedWithTheDefaultKept() throws {
        let (config, problems) = try build(#"{"hints": {"letters": "a"}}"#)
        XCTAssertEqual(config.hintLetters, Config().hintLetters)
        XCTAssertTrue(problems.contains { $0.contains("hints.letters") }, "\(problems)")
    }

    // MARK: - Gestures

    func testDisablingAGestureFreesExactlyItsKeys() throws {
        let (config, _) = try build(#"{"gestures": {"scroll": false}}"#)
        XCTAssertEqual(config.disabledGestures, [","])
        XCTAssertTrue(try build("{}").0.disabledGestures.isEmpty)
    }

    // MARK: - Profiles and the references that depend on them

    func testProfileKeysAreGlobalAndLowercased() throws {
        let (config, _) = try build(#"{"profiles": {"brave": {"Work": "Work Profile"}}}"#)
        XCTAssertEqual(config.browserProfiles["work"]?.display, "Work Profile")
    }

    func testWebFallbackMustNameSomethingReal() throws {
        let (config, problems) = try build(#"{"web": {"fallback": "nowhere"}}"#)
        XCTAssertEqual(config.webFallback, "most-recent", "the default survives a bad reference")
        XCTAssertTrue(problems.contains { $0.contains("fallback") }, "\(problems)")

        let (good, goodProblems) = try build("""
        {"profiles": {"brave": {"work": "Work"}}, "web": {"fallback": "work"}}
        """)
        XCTAssertEqual(good.webFallback, "work")
        XCTAssertEqual(goodProblems, [])
    }

    func testWebRoutesAndLinksMustReferenceKnownProfiles() throws {
        let (config, problems) = try build("""
        {"web": {"routes": {"acme.com": "ghost"},
                 "links": {"yt": {"url": "youtube.com", "profile": "ghost"}}}}
        """)
        XCTAssertTrue(config.webRoutes.isEmpty, "a route to nowhere is dropped")
        XCTAssertEqual(config.webLinks.count, 1, "the link survives; only its bad profile is refused")
        XCTAssertNil(config.webLinks.first?.profileKey)
        XCTAssertEqual(problems.filter { $0.contains("ghost") }.count, 2, "\(problems)")
    }

    func testLinkWithoutUrlIsReported() throws {
        let (config, problems) = try build(#"{"web": {"links": {"yt": {"profile": "work"}}}}"#)
        XCTAssertTrue(config.webLinks.isEmpty)
        XCTAssertTrue(problems.contains { $0.contains("needs a url") }, "\(problems)")
    }

    // MARK: - Graph

    func testGraphBuildsAndReservedLettersAreRefused() throws {
        let (config, problems) = try build(#"{"graph": {"s": "Slack", "z": "Zed"}}"#)
        guard case .leaf = config.graph.resolve(["s"]) else { return XCTFail("s should resolve") }
        XCTAssertNil(config.graph.children["z"], "z belongs to layout undo")
        XCTAssertTrue(problems.contains { $0.contains("reserved") }, "\(problems)")
    }

    // MARK: - Key overrides

    func testKeyOverridesTakeNumericCodesAndKnownNames() throws {
        let (config, _) = try build(#"{"keys": {"50": "escape"}}"#)
        XCTAssertEqual(config.keyOverrides[50], "escape")

        let (_, badName) = try build(#"{"keys": {"50": "nonsense"}}"#)
        XCTAssertTrue(badName.contains { $0.contains("unknown key name") }, "\(badName)")

        let (_, badCode) = try build(#"{"keys": {"fifty": "escape"}}"#)
        XCTAssertTrue(badCode.contains { $0.contains("keycodes are numbers") }, "\(badCode)")
    }

    // MARK: - Unknown keys still reach the user

    func testUnknownKeysAreReportedRatherThanIgnored() throws {
        let (_, problems) = try build(#"{"scroll": {"speeed": 1800}}"#)
        XCTAssertTrue(problems.contains { $0.contains("speeed") }, "\(problems)")
    }
}
