import XCTest
@testable import LodestarCore
@testable import lodestar

/// What the instance does about launchd's side of the login agent, and how it
/// keeps the `lodestar` command. Both decisions are made by functions that touch
/// neither launchctl nor the real PATH, so a failure to read launchd and
/// another tool's file in the way are exercised here.
final class LoginItemTests: XCTestCase {
    // MARK: - Reading launchd

    func testAJobThatIsLoadedAndRunningAnswersItsPid() {
        let list = """
        {
        \t"LimitLoadToSessionType" = "Aqua";
        \t"Label" = "com.vaccone.lodestar";
        \t"PID" = 4242;
        }
        """
        XCTAssertEqual(LoginAgent.state(exitStatus: 0, output: list), .loaded(pid: 4242))
    }

    func testAJobThatIsLoadedAndIdleIsLoadedWithPidZero() {
        let list = "{\n\t\"Label\" = \"com.vaccone.lodestar\";\n\t\"LastExitStatus\" = 0;\n}"
        XCTAssertEqual(LoginAgent.state(exitStatus: 0, output: list), .loaded(pid: 0))
    }

    func testLaunchctlSayingThereIsNoSuchJobIsNotLoaded() {
        XCTAssertEqual(LoginAgent.state(exitStatus: 113, output: ""), .notLoaded)
    }

    func testAFailureToAskIsUnknownAndNeverNotLoaded() {
        guard case .unknown = LoginAgent.state(exitStatus: 1, output: "") else { return XCTFail("exit 1 is not an answer") }
        guard case .unknown = LoginAgent.state(exitStatus: 0, output: nil) else {
            return XCTFail("output that cannot be read is not an answer")
        }
        guard case .unknown = LoginAgent.state(exitStatus: 134, output: "") else { return XCTFail("a crash is not an answer") }
    }

    // MARK: - What to do about it

    func testNotLoadedBootstrapsAndUnknownDoesNothingAtAll() {
        XCTAssertEqual(LoginAgent.readoption(state: .notLoaded, definitionChanged: false, me: 7), .bootstrap)
        XCTAssertEqual(LoginAgent.readoption(state: .unknown("launchctl could not be run"), definitionChanged: false, me: 7),
                       .unreadable("launchctl could not be run"))
        XCTAssertEqual(LoginAgent.readoption(state: .unknown("x"), definitionChanged: true, me: 7), .unreadable("x"),
                       "not even a rewritten definition is loaded on a guess")
    }

    func testTheJobThatRunsThisInstanceIsLeftAloneAndAnotherIsKickstarted() {
        XCTAssertEqual(LoginAgent.readoption(state: .loaded(pid: 7), definitionChanged: false, me: 7), .nothing)
        XCTAssertEqual(LoginAgent.readoption(state: .loaded(pid: 9), definitionChanged: false, me: 7),
                       .kickstart(agentPid: 9))
        XCTAssertEqual(LoginAgent.readoption(state: .loaded(pid: 0), definitionChanged: false, me: 7),
                       .kickstart(agentPid: 0), "loaded and idle is not this instance")
    }

    func testARewrittenDefinitionIsLoadedAgainEvenWhenTheJobIsThisInstance() {
        XCTAssertEqual(LoginAgent.readoption(state: .loaded(pid: 7), definitionChanged: true, me: 7),
                       .reload(agentPid: 7))
    }

    // MARK: - The command's link

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-cli-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private let target = "/Applications/lodestar.app/Contents/MacOS/lodestar"

    private var link: String { folder.appendingPathComponent("lodestar").path }

    func testNothingThereGetsTheLink() throws {
        XCTAssertEqual(CLILink.maintain(link: link, target: target), .created)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), target)
    }

    func testALinkAlreadyRightIsLeftAsItIs() throws {
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        XCTAssertEqual(CLILink.maintain(link: link, target: target), .current)
    }

    func testALinkToAnotherLodestarAppIsMovedToThisOne() throws {
        let old = "/Users/someone/Downloads/lodestar.app/Contents/MacOS/lodestar"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: old)
        XCTAssertEqual(CLILink.maintain(link: link, target: target), .replaced(was: old))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), target)
    }

    func testALinkToNothingIsReplaced() throws {
        let gone = folder.appendingPathComponent("removed-tool").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: gone)
        XCTAssertEqual(CLILink.maintain(link: link, target: target), .replaced(was: gone))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), target)
    }

    func testAnotherToolsBinaryIsLeftAloneWhole() throws {
        try Data("#!/bin/sh\necho theirs\n".utf8).write(to: URL(fileURLWithPath: link))
        guard case .leftAlone = CLILink.maintain(link: link, target: target) else { return XCTFail("a file is not ours") }
        XCTAssertEqual(try String(contentsOfFile: link, encoding: .utf8), "#!/bin/sh\necho theirs\n")
    }

    func testALinkToAnotherToolThatExistsIsLeftAlone() throws {
        let theirs = folder.appendingPathComponent("theirs")
        try Data("x".utf8).write(to: theirs)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: theirs.path)
        guard case .leftAlone = CLILink.maintain(link: link, target: target) else { return XCTFail("their link is theirs") }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), theirs.path)
    }

    func testAFolderInTheWayIsLeftAlone() throws {
        try FileManager.default.createDirectory(atPath: link, withIntermediateDirectories: true)
        guard case .leftAlone = CLILink.maintain(link: link, target: target) else { return XCTFail("a folder is not ours") }
    }

    func testAFailedCreateSaysSoWhereItWasSilent() throws {
        let missing = folder.appendingPathComponent("no-such-folder/lodestar").path
        guard case .failed = CLILink.maintain(link: missing, target: target) else { return XCTFail("nothing can be made there") }
    }

    func testTheLinkIsReplacedWithoutAMomentOfNone() throws {
        let old = "/Users/someone/Downloads/lodestar.app/Contents/MacOS/lodestar"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: old)
        _ = CLILink.maintain(link: link, target: target)
        XCTAssertFalse(FileManager.default.fileExists(atPath: link + ".lodestar-new"), "no stray beside it")
    }

    // MARK: - Uninstall removes only what is ours

    func testOnlyALinkToALodestarAppIsLodestars() throws {
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        XCTAssertTrue(CLILink.isLodestars(link))
        let other = folder.appendingPathComponent("other").path
        try FileManager.default.createSymbolicLink(atPath: other, withDestinationPath: "/usr/local/bin/other-tool")
        XCTAssertFalse(CLILink.isLodestars(other))
        let file = folder.appendingPathComponent("file").path
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        XCTAssertFalse(CLILink.isLodestars(file))
        XCTAssertFalse(CLILink.isLodestars(folder.appendingPathComponent("absent").path))
    }
}
