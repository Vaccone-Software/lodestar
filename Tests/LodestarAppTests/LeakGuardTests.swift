import XCTest
@testable import lodestar
@testable import LodestarCore

/// The guard that fails a test for leaving a static changed (Overrides.swift):
/// that it is installed whichever class runs, that it names what leaked and
/// puts it back, and that the statics it cannot watch are only ever set
/// through an override.
final class LeakGuardTests: XCTestCase {
    /// Installed by a constructor when the bundle loads, so a run of this one
    /// class (`xctest -XCTest LodestarAppTests.LeakGuardTests`) has it as a
    /// full run does.
    func testTheGuardIsInstalledWhicheverClassRuns() {
        XCTAssertTrue(LeakGuard.installed)
    }

    func testAStaticLeftChangedIsNamedWithBothValuesAndPutBack() {
        let leaks = LeakGuard.leaks { ActivePolicy.frameOverride = NSRect(x: 1, y: 2, width: 3, height: 4) }
        XCTAssertEqual(leaks.count, 1)
        let leak = leaks.first ?? ""
        XCTAssertTrue(leak.hasPrefix("ActivePolicy.frameOverride was nil when this test began and is (1.0, 2.0, 3.0, 4.0) after it."), leak)
        XCTAssertNil(ActivePolicy.frameOverride, "put back, so the next test does not inherit the leak")
    }

    func testAnOverrideIsNotALeakAndIsOverWhenItsScopeEnds() {
        XCTAssertEqual(LeakGuard.leaks { withPresentationFrame(Stage.screen) { XCTAssertEqual(ActivePolicy.frameOverride, Stage.screen) } }, [])
        XCTAssertNil(ActivePolicy.frameOverride)
        XCTAssertThrowsError(try withPresentationFrame(Stage.screen) { throw CocoaError(.fileNoSuchFile) })
        XCTAssertNil(ActivePolicy.frameOverride, "a throw ends it too")
    }

    func testAStaticSetByTheTestIsPutBackAtItsEnd() {
        setOverride(\ActivePolicy.Type.frameOverride, to: Stage.screen)
        XCTAssertEqual(ActivePolicy.frameOverride, Stage.screen)
        // The teardown block is last in, first out: two overrides of one
        // static end on what it held before either.
        setOverride(\ActivePolicy.Type.frameOverride, to: NSRect(x: 5, y: 5, width: 5, height: 5))
        XCTAssertEqual(ActivePolicy.frameOverride, NSRect(x: 5, y: 5, width: 5, height: 5))
    }

    /// A closure cannot be compared, so it is read: what it answers, or that
    /// it is set at all.
    func testAClosureIsComparedByWhatItAnswers() {
        let moved = LeakGuard.leaks { Accessibility.reduceMotion = { true } }
        XCTAssertEqual(moved.count, 1)
        XCTAssertTrue(moved.first?.hasPrefix("Accessibility.reduceMotion was false when this test began and is true after it.") ?? false,
                      "\(moved)")
        XCTAssertFalse(Accessibility.reduceMotion(), "put back")

        XCTAssertEqual(LeakGuard.leaks { Log.listener = { _ in } }.first?.hasPrefix("Log.listener was none"), true)
        XCTAssertNil(Log.listener)
        // A different closure that answers the same is the same setting: the
        // tests put the accent back with their own copy of its default.
        XCTAssertEqual(LeakGuard.leaks { BarTheme.accentColor = { BarTheme.internationalOrange } }, [])
    }

    /// The word lists are installed when the bundle loads, so no test is the
    /// first to need them, and a test that changes one has leaked it.
    func testTheWordListsAreInstalledBeforeAnyTestAndAreWatchedLikeAnyOther() throws {
        let installed = try XCTUnwrap(CommonWords.frequentListURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path), installed.path)
        XCTAssertNotNil(DictationLexicon.given)
        let leaks = LeakGuard.leaks { CommonWords.frequentListURL = URL(fileURLWithPath: "/elsewhere.txt") }
        XCTAssertEqual(leaks.count, 1)
        XCTAssertEqual(CommonWords.frequentListURL, installed, "put back")
    }

    /// A closure answers nothing a test could read off it, so these four are
    /// not watched at run time. The stage sets and restores the pointer's; the
    /// rest are set through `setOverride`, which puts them back.
    func testNoTestAssignsAStaticTheGuardCannotWatchExceptThroughAnOverride() throws {
        let unwatched = ["Pointer.post", "Sounds.play", "FileSense.thumbnailer", "FileSense.dataless"]
        let patterns = try unwatched.map { ($0, try NSRegularExpression(pattern: "(?<![A-Za-z0-9_.])\($0)\\s*=[^=]")) }
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let exempt: Set<String> = ["Stage.swift", "Overrides.swift", "LeakRegistry.swift", "LeakGuardTests.swift"]
        var offenders: [String] = []
        for case let url as URL in try XCTUnwrap(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)) {
            guard url.pathExtension == "swift", !exempt.contains(url.lastPathComponent) else { continue }
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            for (number, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                for (name, assignment) in patterns where line.contains(name)
                    && assignment.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil {
                    offenders.append("\(url.lastPathComponent):\(number + 1) assigns \(name)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "set it with setOverride, which puts it back")
    }
}
