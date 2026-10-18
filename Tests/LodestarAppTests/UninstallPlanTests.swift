import XCTest
@testable import LodestarCore
@testable import lodestar

/// One plan for the CLI verb, the menu item and the sheet: every step
/// named before it runs, the running instance stopped last, data kept
/// unless asked. The login agent's stub is the Trash's door.
final class UninstallPlanTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone")

    private let keychainItems = "com.vaccone.lodestar: health, logbook, clipboard, state"

    private func world(present: Set<String>, selected: Bool = false, browser: String? = nil,
                       keychainItems: String? = nil) -> UninstallPlan.World {
        UninstallPlan.World(
            agentPlist: home.appendingPathComponent("Library/LaunchAgents/com.vaccone.lodestar.plist"),
            bundles: [home.appendingPathComponent("Applications/lodestar.app"),
                      URL(fileURLWithPath: "/Applications/lodestar.app")],
            links: [URL(fileURLWithPath: "/opt/homebrew/bin/lodestar")],
            alertSound: home.appendingPathComponent("Library/Sounds/Lodestar.aiff"),
            alertSelected: selected,
            dataRoots: [home.appendingPathComponent(".config/lodestar"),
                        home.appendingPathComponent(".local/share/lodestar")],
            keychainItems: keychainItems ?? self.keychainItems,
            pidFile: home.appendingPathComponent(".config/lodestar/lodestar.pid"),
            bundleID: "com.vaccone.lodestar",
            browserToRestore: browser,
            exists: { present.contains($0.lastPathComponent) })
    }

    private func quiet() -> (UninstallPlan.Actions, () -> [String]) {
        var log: [String] = []
        var actions = UninstallPlan.Actions()
        actions.remove = { log.append("rm \($0.lastPathComponent)") }
        actions.restoreBrowser = { log.append("browser") }
        actions.forgetPermissions = { log.append("tcc \($0)") }
        actions.resetAlertSelection = { log.append("alert default") }
        actions.stopAgent = { log.append("bootout") }
        actions.stopInstance = { _ in log.append("stop") }
        actions.deleteKeys = { log.append("keys"); return [] }
        return (actions, { log })
    }

    func testEveryStepIsNamedAndTheRunningInstanceStopsLast() {
        let (actions, log) = quiet()
        let plan = UninstallPlan.make(
            world: world(present: ["com.vaccone.lodestar.plist", "lodestar.app", "lodestar",
                                   "Lodestar.aiff", "lodestar", ".config"],
                         selected: true, browser: "Brave"),
            purge: false, actions: actions)
        plan.steps.forEach { $0.run() }
        XCTAssertEqual(plan.steps.map(\.name), [
            "restore Brave as your default browser",
            "ask macOS to forget Lodestar's permissions",
            "remove the Lodestar alert sound and return the alert to the Mac's default",
            "remove /opt/homebrew/bin/lodestar",
            "remove /Users/someone/Applications/lodestar.app",
            "remove /Applications/lodestar.app",
            "remove /Users/someone/Library/LaunchAgents/com.vaccone.lodestar.plist",
            "stop Lodestar",
        ])
        XCTAssertEqual(log(), ["browser", "tcc com.vaccone.lodestar", "alert default", "rm Lodestar.aiff",
                               "rm lodestar", "rm lodestar.app", "rm lodestar.app",
                               "rm com.vaccone.lodestar.plist", "bootout", "stop"])
        XCTAssertEqual(plan.kept.map(\.lastPathComponent), ["lodestar", "lodestar"],
                       "config and data survive a reinstall unless asked")
    }

    func testWhatIsAbsentIsNotAStepAndTheAlertIsLeftAloneWhenTheMacNamesAnother() {
        let (actions, _) = quiet()
        let plan = UninstallPlan.make(world: world(present: ["Lodestar.aiff"]), purge: false, actions: actions)
        XCTAssertEqual(plan.steps.map(\.name), [
            "ask macOS to forget Lodestar's permissions",
            "remove the Lodestar alert sound",
            "stop Lodestar",
        ])
    }

    func testPurgeRemovesTheRootsAndKeepsNothing() {
        let (actions, _) = quiet()
        let plan = UninstallPlan.make(world: world(present: ["lodestar", ".config"]), purge: true, actions: actions)
        XCTAssertTrue(plan.steps.map(\.name).contains("remove /Users/someone/.config/lodestar"))
        XCTAssertTrue(plan.steps.map(\.name).contains("remove /Users/someone/.local/share/lodestar"))
        XCTAssertTrue(plan.kept.isEmpty)
    }

    // MARK: The keys in the login keychain

    private static let keyStepName = "remove Lodestar's keys from your login keychain (com.vaccone.lodestar: health, logbook, clipboard, state)"

    /// The sealed data stays on a plain uninstall, and without its keys it
    /// would be unreadable for ever: so the keys stay too, and the plan does
    /// not so much as name a keychain step.
    func testAPlainUninstallKeepsTheKeysAndNeverAsksTheKeychain() {
        let (actions, log) = quiet()
        let plan = UninstallPlan.make(world: world(present: ["lodestar", ".config", "lodestar.app"]), purge: false,
                                      actions: actions)
        plan.steps.forEach { $0.run() }
        XCTAssertFalse(plan.steps.map(\.name).contains { $0.contains("keychain") }, "\(plan.steps.map(\.name))")
        XCTAssertFalse(log().contains("keys"), "nothing touched the keychain")
        XCTAssertFalse(plan.kept.isEmpty, "the data it keeps is named")
    }

    func testPurgeDeletesTheKeysAfterTheDataAndBeforeTheAgentAndTheStop() {
        let (actions, log) = quiet()
        let plan = UninstallPlan.make(world: world(present: ["lodestar", ".config", "com.vaccone.lodestar.plist"]),
                                      purge: true, actions: actions)
        XCTAssertEqual(plan.steps.map(\.name), [
            "ask macOS to forget Lodestar's permissions",
            "remove /opt/homebrew/bin/lodestar",  // `present` matches by file name
            "remove /Users/someone/.config/lodestar",
            "remove /Users/someone/.local/share/lodestar",
            Self.keyStepName,
            "remove /Users/someone/Library/LaunchAgents/com.vaccone.lodestar.plist",
            "stop Lodestar",
        ])
        plan.steps.forEach { $0.run() }
        XCTAssertEqual(log(), ["tcc com.vaccone.lodestar", "rm lodestar", "rm lodestar", "rm lodestar", "keys",
                               "rm com.vaccone.lodestar.plist", "bootout", "stop"])
    }

    /// The items are in the keychain, which the plan does not look into: a
    /// machine whose data directory is already gone still has its keys.
    func testPurgeDeletesTheKeysWhenThereIsNoDataLeft() {
        let (actions, log) = quiet()
        let plan = UninstallPlan.make(world: world(present: []), purge: true, actions: actions)
        XCTAssertEqual(plan.steps.map(\.name), ["ask macOS to forget Lodestar's permissions", Self.keyStepName, "stop Lodestar"])
        plan.steps.forEach { $0.run() }
        XCTAssertEqual(log(), ["tcc com.vaccone.lodestar", "keys", "bootout", "stop"])
    }

    /// `--dry-run` prints `steps` and never runs them.
    func testDescribingThePlanDeletesNothing() {
        let (actions, log) = quiet()
        let plan = UninstallPlan.make(world: world(present: ["lodestar"]), purge: true, actions: actions)
        XCTAssertTrue(plan.steps.map(\.name).contains(Self.keyStepName))
        XCTAssertEqual(log(), [], "the plan is made without a single side effect")
    }

    /// A key the keychain would not give up is the person's to know: the step
    /// answers it, and every step after it still runs, the stop last.
    func testAKeyThatCannotBeDeletedIsReportedAndTheRestStillRuns() {
        var log: [String] = []
        var (actions, _) = quiet()
        actions.remove = { log.append("rm \($0.lastPathComponent)") }
        actions.deleteKeys = { log.append("keys"); return ["the logbook key is still in your login keychain (the login keychain refused access)"] }
        actions.stopAgent = { log.append("bootout") }
        actions.stopInstance = { _ in log.append("stop") }
        actions.forgetPermissions = { _ in }
        let plan = UninstallPlan.make(world: world(present: ["lodestar", "com.vaccone.lodestar.plist"]),
                                      purge: true, actions: actions)
        let problems = plan.steps.flatMap { $0.run() }
        XCTAssertEqual(problems, ["the logbook key is still in your login keychain (the login keychain refused access)"])
        XCTAssertEqual(log, ["rm lodestar", "rm lodestar", "rm lodestar", "keys", "rm com.vaccone.lodestar.plist",
                             "bootout", "stop"])
        XCTAssertTrue(plan.steps.filter { !$0.name.contains("keychain") }.flatMap { $0.run() }.isEmpty,
                      "the other steps report nothing")
    }

    /// The real action reaches the keychain through `Vault.system`, which a
    /// test run refuses: it answers a problem instead of touching anything.
    func testTheRealDeleteRefusesUnderATestRunAndSaysSo() {
        let problems = UninstallPlan.deleteKeys()
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("Keychain Access"), "\(problems)")
    }

    /// The live world names every ring, whatever rings there are.
    func testTheLivePlanNamesEveryRing() {
        for ring in Vault.RingName.allCases {
            XCTAssertTrue(UninstallPlan.keychainItemsNote.contains(ring.rawValue), "\(ring)")
        }
        XCTAssertTrue(UninstallPlan.keychainItemsNote.hasPrefix(Vault.keychainService))
    }

    func testTheSheetShowsThePlanWholeAndWhatStays() {
        let (actions, _) = quiet()
        let plan = UninstallPlan.make(world: world(present: ["lodestar.app"]), purge: false, actions: actions)
        let summary = AppDelegate.uninstallSummary(plan)
        XCTAssertTrue(summary.hasPrefix("• ask macOS to forget Lodestar's permissions\n• remove /Users/someone/Applications/lodestar.app"))
        XCTAssertTrue(summary.contains("Everything Lodestar has kept stays"))
        XCTAssertTrue(summary.hasSuffix(UninstallPlan.closing))
    }

    /// The menu's Uninstall is Lodestar's own room: the plan whole, R
    /// turning the switch for everything kept, ⌘⏎ carrying that answer.
    func testTheRoomShowsThePlanAndCarriesTheChoice() {
        let (actions, log) = quiet()
        let room = UninstallRoom()
        room.plan = { purge in
            UninstallPlan.make(world: self.world(present: ["lodestar.app", "lodestar"]), purge: purge, actions: actions)
        }
        var chosen: Bool?
        room.onUninstall = { chosen = $0 }
        room.show()
        defer { room.close() }
        XCTAssertTrue(room.shownLines.contains("Remove /Users/someone/Applications/lodestar.app"), "\(room.shownLines)")
        XCTAssertFalse(room.shownLines.contains("Remove /Users/someone/.config/lodestar"), "kept unless asked")
        room.pressToggle()
        XCTAssertTrue(room.shownLines.contains("Remove /Users/someone/.config/lodestar"), "the plan says so at once")
        room.pressUninstall()
        XCTAssertEqual(chosen, true)
        XCTAssertEqual(log(), [], "the room runs nothing itself")
    }

    func testTheLoginAgentBecomesTheAppOrCleansUpAfterTheTrash() {
        let job = LoginAgent.job(binary: "/Users/someone/Applications/lodestar.app/Contents/MacOS/lodestar")
        let arguments = job["ProgramArguments"] as? [String]
        XCTAssertEqual(arguments?.prefix(2), ["/bin/sh", "-c"])
        XCTAssertEqual(arguments?.last, "/Users/someone/Applications/lodestar.app/Contents/MacOS/lodestar",
                       "the path is an argument, never interpolated into the script")
        XCTAssertTrue(LoginAgent.stub.hasPrefix("if [ -x \"$1\" ]; then exec \"$1\"; fi"),
                      "with the app in place the stub is the app, under launchd's own pid")
        XCTAssertTrue(LoginAgent.stub.contains("Library/Sounds/Lodestar.aiff"))
        XCTAssertTrue(LoginAgent.stub.contains("launchctl bootout"))
        XCTAssertEqual(job["Label"] as? String, "com.vaccone.lodestar")
        XCTAssertEqual((job["KeepAlive"] as? [String: Bool])?["SuccessfulExit"], false)
    }
}

/// The login agent's stub, run under a home of its own with `defaults`
/// and `launchctl` recorded: with the app there it is the app; with the
/// app in the Trash it takes the agent and the sound with it, hands the
/// alert back only if it was Lodestar's, and stops.
final class LoginAgentStubRunTests: XCTestCase {
    private var home: URL!
    private var calls: URL { home.appendingPathComponent("calls.log") }
    private var plist: URL { home.appendingPathComponent("Library/LaunchAgents/\(UninstallPlan.agentLabel).plist") }
    private var sound: URL { home.appendingPathComponent("Library/Sounds/\(AlertSound.name).aiff") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("stub-run-\(UUID().uuidString)")
        let fm = FileManager.default
        for dir in ["Library/LaunchAgents", "Library/Sounds", "bin"] {
            try fm.createDirectory(at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try "plist".write(to: plist, atomically: true, encoding: .utf8)
        try "aiff".write(to: sound, atomically: true, encoding: .utf8)
        try executable("bin/launchctl", "#!/bin/sh\necho \"launchctl $*\" >> \"\(calls.path)\"\n")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: home) }

    private func executable(_ path: String, _ text: String) throws {
        let url = home.appendingPathComponent(path)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// `defaults` answering a read of the alert's selection with `selected`.
    private func alertSelection(_ selected: String?) throws {
        let read = selected.map { "echo \"\($0)\"" } ?? "exit 1"
        try executable("bin/defaults", """
        #!/bin/sh
        echo "defaults $*" >> "\(calls.path)"
        case "$1" in read) \(read);; esac
        """)
    }

    private func run(binary: String) throws -> (status: Int32, calls: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = Array((LoginAgent.job(binary: binary)["ProgramArguments"] as? [String] ?? []).dropFirst())
        process.environment = ["HOME": home.path, "PATH": home.appendingPathComponent("bin").path + ":/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()
        let log = (try? String(contentsOf: calls, encoding: .utf8)) ?? ""
        return (process.terminationStatus, log.split(separator: "\n").map(String.init))
    }

    func testWithTheAppInPlaceTheStubIsTheApp() throws {
        try alertSelection(nil)
        let ran = home.appendingPathComponent("app-ran")
        try executable("lodestar", "#!/bin/sh\ntouch \"\(ran.path)\"\nexit 0\n")
        let result = try run(binary: home.appendingPathComponent("lodestar").path)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ran.path), "the app ran")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path), "the agent stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sound.path), "the sound stays")
        XCTAssertEqual(result.calls, [], "nothing asked of launchd or the defaults")
    }

    func testWithTheAppInTheTrashTheStubCleansUpAndStops() throws {
        try alertSelection(sound.path)
        let result = try run(binary: home.appendingPathComponent("gone/lodestar").path)
        XCTAssertEqual(result.status, 0, "a clean exit, so launchd does not ask again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sound.path))
        XCTAssertTrue(result.calls.contains("defaults delete -g \(AlertSound.selectionKey)"),
                      "the alert named Lodestar's sound, so it goes back to the Mac's: \(result.calls)")
        XCTAssertTrue(result.calls.contains { $0.hasPrefix("launchctl bootout gui/") && $0.hasSuffix("/\(UninstallPlan.agentLabel)") })
    }

    func testAnAlertThePersonChoseElsewhereIsLeftAlone() throws {
        try alertSelection("/System/Library/Sounds/Boop.aiff")
        let result = try run(binary: home.appendingPathComponent("gone/lodestar").path)
        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(result.calls.contains { $0.hasPrefix("defaults delete") }, "\(result.calls)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
    }
}
