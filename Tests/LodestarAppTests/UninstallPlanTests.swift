import XCTest
@testable import lodestar

/// One plan for the CLI verb, the menu item and the sheet: every step
/// named before it runs, the running instance stopped last, data kept
/// unless asked. The login agent's stub is the Trash's door.
final class UninstallPlanTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone")

    private func world(present: Set<String>, selected: Bool = false, browser: String? = nil) -> UninstallPlan.World {
        UninstallPlan.World(
            agentPlist: home.appendingPathComponent("Library/LaunchAgents/com.vaccone.lodestar.plist"),
            bundles: [home.appendingPathComponent("Applications/lodestar.app"),
                      URL(fileURLWithPath: "/Applications/lodestar.app")],
            links: [URL(fileURLWithPath: "/opt/homebrew/bin/lodestar")],
            alertSound: home.appendingPathComponent("Library/Sounds/Lodestar.aiff"),
            alertSelected: selected,
            dataRoots: [home.appendingPathComponent(".config/lodestar"),
                        home.appendingPathComponent(".local/share/lodestar")],
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

    func testTheSheetShowsThePlanWholeAndWhatStays() {
        let (actions, _) = quiet()
        let plan = UninstallPlan.make(world: world(present: ["lodestar.app"]), purge: false, actions: actions)
        let summary = AppDelegate.uninstallSummary(plan)
        XCTAssertTrue(summary.hasPrefix("• ask macOS to forget Lodestar's permissions\n• remove /Users/someone/Applications/lodestar.app"))
        XCTAssertTrue(summary.contains("Your config, breaths and clipboard stay"))
        XCTAssertTrue(summary.hasSuffix(UninstallPlan.closing))
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
