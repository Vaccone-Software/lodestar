import XCTest

/// `dev-build.sh stop`, run against apps that are only an Info.plist, a
/// release list and downloads served from a folder, a small git history,
/// and stand-ins for launchctl, codesign and spctl. On 2026-10-19 the
/// copy set aside was 0.51.0 while the development build (labelled
/// 0.51.0 too) had written cards of files, which 0.51 cannot read: a stop
/// would have set the whole clipboard history aside. These hold that stop
/// puts back only a release that holds the build's work.
final class DevBuildScriptTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static let stand_ins = [
        "launchctl": #"echo "launchctl $*" >> "$STAND_IN_LOG""#,
        "pgrep": #"echo "4242 /Applications/lodestar.app/Contents/MacOS/lodestar""#,
        "codesign": #"""
        case "$1" in
        --verify) [ -f "$STAND_IN_STATE/bad_signature" ] && exit 1; exit 0;;
        -dv) if [ -f "$STAND_IN_STATE/other_team" ]; then echo "TeamIdentifier=ABCDE12345" >&2; else echo "TeamIdentifier=2PZMN57974" >&2; fi;;
        esac
        """#,
        "spctl": #"[ -f "$STAND_IN_STATE/gatekeeper_refuses" ] && exit 3; exit 0"#,
    ]

    private struct Commits { var base, released, unreleased: String }

    private struct Outcome {
        var status: Int32
        var output: String
        var installed: [String: Any]?
        var setAside: [String: Any]?
        var launchctl: [String]
        var installedVersion: String? { installed?["CFBundleShortVersionString"] as? String }
        var installedIsDevelopment: Bool { installed?["LodestarDevelopment"] as? Bool == true }
    }

    private var scratch: URL!
    private var commits: Commits!
    private var releases: [(version: String, commit: String)] = []
    private var flags: [String] = []

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-dev-build-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        commits = try makeHistory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func path(_ name: String) -> URL { scratch.appendingPathComponent(name) }

    @discardableResult
    private func shell(_ arguments: [String], in directory: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw NSError(domain: output, code: Int(process.terminationStatus)) }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// base → released, and base → unreleased beside it: the released
    /// commit holds base's work and not unreleased's.
    private func makeHistory() throws -> Commits {
        let repo = path("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        try shell(git + ["init", "-q"], in: repo)
        try shell(git + ["commit", "-q", "--allow-empty", "-m", "base"], in: repo)
        let base = try shell(["git", "rev-parse", "HEAD"], in: repo)
        try shell(git + ["commit", "-q", "--allow-empty", "-m", "released"], in: repo)
        let released = try shell(["git", "rev-parse", "HEAD"], in: repo)
        try shell(git + ["checkout", "-q", "-b", "work", base], in: repo)
        try shell(git + ["commit", "-q", "--allow-empty", "-m", "unreleased"], in: repo)
        let unreleased = try shell(["git", "rev-parse", "HEAD"], in: repo)
        return Commits(base: base, released: released, unreleased: unreleased)
    }

    private func makeApp(at url: URL, version: String, development: Bool = false, commit: String? = nil) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleShortVersionString": version, "CFBundleIdentifier": "com.vaccone.lodestar"]
        if development { plist["LodestarDevelopment"] = true }
        if let commit { plist["LodestarCommit"] = commit }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
    }

    /// A published release: listed by the API and downloadable as the
    /// zip release.sh makes.
    private func publish(_ version: String, at commit: String, appVersion: String? = nil, development: Bool = false) throws {
        releases.append((version, commit))
        let staging = path("staging-\(version)/lodestar.app")
        try makeApp(at: staging, version: appVersion ?? version, development: development)
        let folder = path("downloads/v\(version)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try shell(["ditto", "-c", "-k", "--keepParent", staging.path, folder.appendingPathComponent("lodestar-\(version).zip").path])
    }

    private func readPlist(_ app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    private func stop(_ extra: [String] = [], offline: Bool = false) throws -> Outcome {
        let bin = path("bin"), state = path("state")
        for dir in [bin, state] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        for (name, body) in Self.stand_ins {
            let file = bin.appendingPathComponent(name)
            try "#!/bin/bash\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        for flag in flags { try "1".write(to: state.appendingPathComponent(flag), atomically: true, encoding: .utf8) }
        let list = releases.map { #"{"tag_name":"v\#($0.version)","draft":false,"prerelease":true,"target_commitish":"\#($0.commit)"}"# }
        if !offline { try "[\(list.joined(separator: ","))]".write(to: path("releases.json"), atomically: true, encoding: .utf8) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent("scripts/dev-build.sh").path, "stop"] + extra
        process.currentDirectoryURL = root
        process.environment = [
            "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": scratch.path + "/",
            "STAND_IN_LOG": path("launchctl.log").path,
            "STAND_IN_STATE": state.path,
            "DEV_BUILD_AGENT": path("agent.plist").path,
            "DEV_BUILD_INSTALLED": path("Applications/lodestar.app").path,
            "DEV_BUILD_RELEASE": path("dist/lodestar-release.app").path,
            "DEV_BUILD_RELEASES_API": "file://\(path("releases.json").path)",
            "DEV_BUILD_DOWNLOADS": "file://\(path("downloads").path)",
            "DEV_BUILD_REPO": path("repo").path,
            "DEV_BUILD_SETTLE": "0",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let log = (try? String(contentsOf: path("launchctl.log"), encoding: .utf8)) ?? ""
        return Outcome(
            status: process.terminationStatus, output: String(decoding: data, as: UTF8.self),
            installed: readPlist(path("Applications/lodestar.app")),
            setAside: readPlist(path("dist/lodestar-release.app")),
            launchctl: log.split(separator: "\n").map(String.init))
    }

    private func developmentBuild(_ version: String, commit: String?) throws {
        try makeApp(at: path("Applications/lodestar.app"), version: version, development: true, commit: commit)
    }

    private func setAside(_ version: String) throws {
        try makeApp(at: path("dist/lodestar-release.app"), version: version)
    }

    // MARK: -

    /// The night's case: the same version number on both, and the copy
    /// set aside built before the build's work.
    func testACopySetAsideWithoutTheBuildsWorkIsNotPutBackEvenAtTheSameVersion() throws {
        try developmentBuild("1.2.0", commit: commits.unreleased)
        try setAside("1.2.0")
        try publish("1.2.0", at: commits.released)
        let result = try stop()
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertTrue(result.installedIsDevelopment, "the development build stays")
        XCTAssertEqual(result.setAside?["CFBundleShortVersionString"] as? String, "1.2.0", "the copy is kept")
        XCTAssertEqual(result.launchctl, [], "nothing was swapped")
        XCTAssertTrue(result.output.contains("stop --older"), result.output)
    }

    func testACopySetAsideThatHoldsTheBuildsCommitIsPutBack() throws {
        try developmentBuild("1.2.0", commit: commits.base)
        try setAside("1.2.0")
        try publish("1.2.0", at: commits.released)
        let result = try stop()
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.installedVersion, "1.2.0")
        XCTAssertFalse(result.installedIsDevelopment)
        XCTAssertNil(result.setAside, "moved into place")
        XCTAssertEqual(result.launchctl.count, 2, "unloaded and loaded around the swap")
    }

    func testTheNewestReleaseIsInstalledWhenItHoldsTheWorkAndTheCopyDoesNot() throws {
        try developmentBuild("1.2.0", commit: commits.unreleased)
        try setAside("1.2.0")
        try publish("1.2.0", at: commits.released)
        try publish("1.3.0", at: commits.unreleased)
        let result = try stop()
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.installedVersion, "1.3.0")
        XCTAssertFalse(result.installedIsDevelopment)
        XCTAssertNil(result.setAside, "the older copy is removed")
    }

    func testOlderPutsBackTheCopyAnyway() throws {
        try developmentBuild("1.2.0", commit: commits.unreleased)
        try setAside("1.1.0")
        let result = try stop(["--older"])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.installedVersion, "1.1.0")
    }

    /// A build from a tree with changes names no commit, and an unread
    /// list names none either: then only a newer version will do.
    func testWithoutCommitsOnlyANewerVersionIsPutBack() throws {
        try developmentBuild("1.2.0", commit: nil)
        try setAside("1.2.0")
        try publish("1.2.0", at: commits.released)
        XCTAssertEqual(try stop().status, 1)

        try setAside("1.2.1")
        let offline = try stop(offline: true)
        XCTAssertEqual(offline.status, 0, offline.output)
        XCTAssertEqual(offline.installedVersion, "1.2.1")
    }

    func testAReleaseTheUpdaterPutInPlaceIsLeftAndTheOlderCopyRemoved() throws {
        try makeApp(at: path("Applications/lodestar.app"), version: "1.3.0")
        try setAside("1.2.0")
        let result = try stop()
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.installedVersion, "1.3.0", "never downgraded")
        XCTAssertNil(result.setAside)
        XCTAssertEqual(result.launchctl, [])
    }

    func testADownloadNotSignedByLodestarsTeamIsRefused() throws {
        try developmentBuild("1.2.0", commit: commits.unreleased)
        try publish("1.3.0", at: commits.unreleased)
        flags = ["other_team"]
        let result = try stop()
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.installedIsDevelopment)
        XCTAssertEqual(result.launchctl, [])
        XCTAssertTrue(result.output.contains("team"), result.output)
    }

    func testADownloadGatekeeperRefusesIsRefused() throws {
        try developmentBuild("1.2.0", commit: commits.unreleased)
        try publish("1.3.0", at: commits.unreleased)
        flags = ["gatekeeper_refuses"]
        let result = try stop()
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.installedIsDevelopment)
    }

    func testADownloadThatIsNotTheVersionItClaimsIsRefused() throws {
        try developmentBuild("1.2.0", commit: commits.unreleased)
        try publish("1.3.0", at: commits.unreleased, appVersion: "1.1.0")
        let result = try stop()
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.installedIsDevelopment)
        XCTAssertTrue(result.output.contains("says it is 1.1.0"), result.output)
    }

    func testADownloadThatIsADevelopmentBuildIsRefused() throws {
        try developmentBuild("1.2.0", commit: commits.unreleased)
        try publish("1.3.0", at: commits.unreleased, development: true)
        let result = try stop()
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(result.installedVersion, "1.2.0")
    }
}
