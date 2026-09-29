import XCTest

/// The GitHub half of a ship, run against a stand-in for `gh` that keeps a
/// release's state in a folder and can be told to time out on its next N
/// calls. 0.39.4 died uploading its zip: the draft `gh release create`
/// made stayed, empty, and every later create failed with "already
/// exists". These hold each way a ship can stop and be run again.
final class ShipScriptTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// GitHub, as far as the script asks of it. `gh api ... --jq` is real
    /// gh applying a filter; here the filter's result is what is printed,
    /// so the script's filters are checked against the live API by hand.
    private static let fakeGH = #"""
    #!/bin/bash
    S="$FAKE_GH_STATE"
    echo "$*" >> "$S/calls.log"
    consume() {
        local f="$S/fail_$1" n
        [ -f "$f" ] || return 1
        n=$(cat "$f")
        [ "$n" -gt 0 ] || return 1
        echo $((n - 1)) > "$f"
        return 0
    }
    blip() { echo "Post \"https://uploads.github.com/x\": dial tcp 140.82.112.13:443: i/o timeout" >&2; exit 1; }
    state() { cat "$S/state"; }
    case "$1" in
    api)
        case "$2" in
        *"/releases?per_page=30")
            consume lookup && blip
            case "$(state)" in
                none) echo none;;
                draft) echo "4242 draft";;
                published) echo "4242 published";;
            esac;;
        *"/releases/4242")
            consume assets && blip
            [ -f "$S/assets" ] && cat "$S/assets"
            exit 0;;
        esac;;
    release)
        case "$2" in
        create)
            consume create && blip
            [ "$(state)" = none ] || { echo "a release with the same tag already exists" >&2; exit 1; }
            echo draft > "$S/state"
            if [ -f "$S/create_lands_then_errors" ]; then rm "$S/create_lands_then_errors"; blip; fi;;
        upload)
            [ "$(state)" = draft ] || { echo "no draft to upload to" >&2; exit 1; }
            consume upload && blip
            file="$4"; name=$(basename "$file"); size=$(stat -f %z "$file")
            touch "$S/assets"
            grep -v "^$name " "$S/assets" > "$S/assets.new"
            echo "$name $size" >> "$S/assets.new"
            mv "$S/assets.new" "$S/assets"
            if consume upload_lands_then_errors; then blip; fi;;
        edit)
            case "$*" in
            *"--draft=false"*) consume publish && blip; echo published > "$S/state";;
            esac;;
        esac;;
    workflow)
        consume dispatch && blip
        echo 777 > "$S/run";;
    run)
        case "$2" in
        list) [ -f "$S/run" ] && echo 777; exit 0;;
        view)
            consume view && blip
            n=$(cat "$S/polls")
            if [ "$n" -gt 0 ]; then echo $((n - 1)) > "$S/polls"; echo ""; else cat "$S/verify_result"; fi;;
        esac;;
    esac
    exit 0
    """#

    private struct Outcome {
        var status: Int32
        var output: String
        var state: String
        var assets: [String]
        var calls: [String]
        func count(_ prefix: String) -> Int { calls.filter { $0.hasPrefix(prefix) }.count }
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-ship-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// One run of the script. `failing` is how many of a call's next
    /// attempts time out; `flags` are one-shot behaviours the stand-in
    /// reads (a create that lands then errors).
    private func run(_ arguments: [String], state: String = "none", failing: [String: Int] = [:],
                     flags: [String] = [], verify: String = "success", polls: Int = 0,
                     verifySeconds: Int = 3) throws -> Outcome {
        let bin = scratch.appendingPathComponent("bin")
        let gh = scratch.appendingPathComponent("state")
        for dir in [bin, gh] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let script = bin.appendingPathComponent("gh")
        try Self.fakeGH.appending("\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try state.write(to: gh.appendingPathComponent("state"), atomically: true, encoding: .utf8)
        try verify.write(to: gh.appendingPathComponent("verify_result"), atomically: true, encoding: .utf8)
        try String(polls).write(to: gh.appendingPathComponent("polls"), atomically: true, encoding: .utf8)
        for (name, count) in failing {
            try String(count).write(to: gh.appendingPathComponent("fail_\(name)"), atomically: true, encoding: .utf8)
        }
        for flag in flags { try "1".write(to: gh.appendingPathComponent(flag), atomically: true, encoding: .utf8) }

        let notes = scratch.appendingPathComponent("v9.9.9.md")
        let zip = scratch.appendingPathComponent("lodestar-9.9.9.zip")
        let dmg = scratch.appendingPathComponent("lodestar-9.9.9.dmg")
        try "Notes.\n".write(to: notes, atomically: true, encoding: .utf8)
        try Data(repeating: 1, count: 1_234).write(to: zip)
        try Data(repeating: 2, count: 5_678).write(to: dmg)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("scripts/github-release.sh").path]
            + arguments.map { $0 == "NOTES" ? notes.path : $0 == "ZIP" ? zip.path : $0 == "DMG" ? dmg.path : $0 }
        process.currentDirectoryURL = root
        process.environment = [
            "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "FAKE_GH_STATE": gh.path,
            "REPO": "test/repo",
            "RELEASE_RETRY_DELAY": "0", "RELEASE_POLL_DELAY": "0", "RELEASE_FIND_DELAY": "0",
            "RELEASE_VERIFY_SECONDS": String(verifySeconds),
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        func read(_ name: String) -> String { (try? String(contentsOf: gh.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        return Outcome(
            status: process.terminationStatus, output: String(decoding: data, as: UTF8.self),
            state: read("state").trimmingCharacters(in: .whitespacesAndNewlines),
            assets: read("assets").split(separator: "\n").map(String.init),
            calls: read("calls.log").split(separator: "\n").map(String.init))
    }

    private let publish = ["publish", "9.9.9", "NOTES", "ZIP", "DMG"]

    func testACleanShipDraftsUploadsVerifiesAndPublishes() throws {
        let result = try run(publish)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.state, "published")
        XCTAssertEqual(Set(result.assets), ["lodestar-9.9.9.zip 1234", "lodestar-9.9.9.dmg 5678"])
        XCTAssertEqual(result.count("release create"), 1)
        XCTAssertEqual(result.count("workflow run"), 1)
    }

    /// 0.39.4: the create made the draft and the upload timed out, so the
    /// next ship found an empty draft and could not create another.
    func testAnEmptyDraftLeftByAStoppedShipIsFinishedNotFoughtOver() throws {
        let result = try run(publish, state: "draft")
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.state, "published")
        XCTAssertEqual(result.count("release create"), 0, "no second create")
        XCTAssertEqual(result.assets.count, 2)
        XCTAssertGreaterThanOrEqual(result.count("release edit v9.9.9 --title"), 1, "the notes are refreshed on a reused draft")
    }

    func testAnUploadThatTimesOutIsTriedAgain() throws {
        let result = try run(publish, failing: ["upload": 2])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.state, "published")
        XCTAssertEqual(result.assets.count, 2)
    }

    /// The server took the file and the answer was lost: not sent twice.
    func testAnUploadThatLandedButErroredIsNotSentAgain() throws {
        let result = try run(publish, failing: ["upload_lands_then_errors": 1])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.count("release upload"), 2, "one call for each artifact, no repeats")
        XCTAssertEqual(result.assets.count, 2)
    }

    func testACreateThatErroredAfterMakingTheDraftIsNotRepeated() throws {
        let result = try run(publish, flags: ["create_lands_then_errors"])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.count("release create"), 1)
        XCTAssertEqual(result.state, "published")
    }

    func testAPublishedReleaseIsNeverTouched() throws {
        let result = try run(publish, state: "published")
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.output.contains("already published"), result.output)
        XCTAssertEqual(result.count("release upload") + result.count("release edit") + result.count("release create"), 0)
    }

    func testAFailedVerificationLeavesTheDraftUnpublished() throws {
        let result = try run(publish, verify: "failure")
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.state, "draft")
        XCTAssertTrue(result.output.contains("stays a draft"), result.output)
        XCTAssertEqual(result.count("release edit v9.9.9 --draft=false"), 0)
    }

    func testAnUploadThatKeepsFailingStopsAndSaysToRunAgain() throws {
        let result = try run(publish, failing: ["upload": 99])
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.state, "draft", "the draft is left for the next run to finish")
        XCTAssertTrue(result.output.contains("Run ship.sh again"), result.output)
        XCTAssertEqual(result.count("workflow run"), 0, "nothing is verified without its artifacts")
    }

    func testAnUnreachableGitHubStopsBeforeAnythingIsMade() throws {
        let result = try run(publish, failing: ["lookup": 99])
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.count("release create"), 0)
    }

    func testAFewFailedLookupsAreRetried() throws {
        let result = try run(publish, failing: ["lookup": 2])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.state, "published")
    }

    func testAVerificationStillRunningIsWaitedFor() throws {
        let result = try run(publish, polls: 3)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.state, "published")
    }

    func testAVerificationWhoseQuestionsFailIsAskedAgain() throws {
        let result = try run(publish, failing: ["view": 2])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.state, "published")
    }

    func testAVerificationThatNeverFinishesLeavesTheDraft() throws {
        let result = try run(publish, polls: 1_000_000, verifySeconds: 1)
        XCTAssertEqual(result.status, 1)
        XCTAssertEqual(result.state, "draft")
    }

    func testAPublishThatTimesOutIsTriedAgain() throws {
        let result = try run(publish, failing: ["publish": 2])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.state, "published")
    }

    // MARK: - The question ship.sh asks before it builds

    func testTheCheckPassesForAVersionNotYetOnGitHub() throws {
        XCTAssertEqual(try run(["check", "9.9.9"]).status, 0)
    }

    func testTheCheckNotesAnUnfinishedDraftAndPasses() throws {
        let result = try run(["check", "9.9.9"], state: "draft")
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("already on GitHub"), result.output)
    }

    func testTheCheckRefusesAPublishedVersionBeforeAnythingIsBuilt() throws {
        let result = try run(["check", "9.9.9"], state: "published")
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.output.contains("bump"), result.output)
        XCTAssertTrue(result.output.contains("bump-cask.sh"), "and says how to finish a cask that is all that is left")
    }

    func testTheCheckSaysSoWhenGitHubCannotBeReached() throws {
        XCTAssertEqual(try run(["check", "9.9.9"], failing: ["lookup": 99]).status, 2)
    }
}
