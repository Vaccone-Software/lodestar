import Foundation
import Stoic
import StoicFoundation
import XCTest
@testable import LodestarCore

/// `Log.attempt` and `Log.attemptUnlessAbsent`: the shape of `try?` with the
/// story kept, so a failure that was carried on from can still be found in the log.
final class LogAttemptTests: XCTestCase {
    private var lines: [String] = []

    override func setUp() {
        lines = []
        Log.listener = { [weak self] in self?.lines.append($0) }
    }

    override func tearDown() {
        Log.listener = nil
    }

    private struct Boom: Error {}

    func testAnAttemptThatWorksAnswersItsValueAndSaysNothing() {
        XCTAssertEqual(Log.attempt("unit: adding") { 2 + 2 }, 4)
        XCTAssertTrue(lines.isEmpty)
    }

    func testAnAttemptThatFailsAnswersNilAndLogsWhatItWasDoingAndTheError() {
        let answer: Int? = Log.attempt("unit: could not add", ["term": 2]) { throw Boom() }
        XCTAssertNil(answer)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("WARN unit: could not add"), lines[0])
        XCTAssertTrue(lines[0].contains("term=2"), lines[0])
        XCTAssertTrue(lines[0].contains("Boom"), "the error is in the line: \(lines[0])")
    }

    func testAnAttemptThatWaitsLogsTheSameWay() async {
        let answer: Int? = await Log.attempt("unit: could not wait") {
            try await Task.sleep(nanoseconds: 1)
            throw Boom()
        }
        XCTAssertNil(answer)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("unit: could not wait"), lines[0])
    }

    /// Being cancelled is the caller's decision: answered as nil, like a
    /// failure, but not logged as one.
    func testAnAttemptThatIsCancelledAnswersNilAndSaysNothing() async {
        let waited: Int? = await Log.attempt("unit: could not wait") { () async throws -> Int in
            try await Task.sleep(nanoseconds: 1)
            throw CancellationError()
        }
        let checked: Int? = Log.attempt("unit: could not check") { () throws -> Int in throw CancellationError() }
        XCTAssertNil(waited)
        XCTAssertNil(checked)
        XCTAssertTrue(lines.isEmpty, "a cancellation is not a failure: \(lines)")
    }

    func testARemovalOfSomethingThatIsNotThereIsDoneAndSaysNothing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-attempt-\(UUID().uuidString)")
        Log.attemptUnlessAbsent("unit: could not remove") { try FileManager.default.removeItem(at: missing) }
        XCTAssertTrue(lines.isEmpty, "absence is the goal met: \(lines)")
    }

    func testARemovalThatFailsForAnotherReasonIsLogged() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-attempt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let inside = folder.appendingPathComponent("kept.txt")
        try Data("x".utf8).write(to: inside)
        // A folder that cannot be written to cannot lose a file.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: folder)
        }
        Log.attemptUnlessAbsent("unit: could not remove") { try FileManager.default.removeItem(at: inside) }
        XCTAssertEqual(lines.count, 1, "a permission failure leaves the file behind and is news")
        XCTAssertTrue(lines[0].contains("unit: could not remove"), lines[0])
    }

    func testAnAbsenceIsRecognisedWhateverTheLayerThatReportsIt() {
        XCTAssertTrue(Log.isAbsence(CocoaError(.fileNoSuchFile)))
        XCTAssertTrue(Log.isAbsence(CocoaError(.fileReadNoSuchFile)))
        XCTAssertTrue(Log.isAbsence(POSIXError(.ENOENT)))
        XCTAssertFalse(Log.isAbsence(CocoaError(.fileWriteNoPermission)))
        XCTAssertFalse(Log.isAbsence(Boom()))
    }

    func testAConstantPatternBuildsAndMatches() {
        let pattern = NSRegularExpression.constant("a+b", options: [.caseInsensitive])
        XCTAssertEqual(pattern.numberOfMatches(in: "xAAB", range: NSRange(location: 0, length: 4)), 1)
    }
}

/// What a person reads when a failure reaches them: Lodestar's words, never
/// the error's own text, which goes to the log with its reference.
final class FailureWordsTests: XCTestCase {
    private var lines: [String] = []

    override func setUp() {
        lines = []
        Log.listener = { [weak self] in self?.lines.append($0) }
    }

    override func tearDown() {
        Log.listener = nil
    }

    func testAConfigWriteSaysWhatHappenedAndWhatToDoAndNothingElse() {
        let secret = CocoaError(.fileWriteNoPermission, userInfo: [
            NSLocalizedDescriptionKey: "You don't have permission to save /Users/someone/.config/lodestar/lodestar.json"])
        let sentence = withAmbient({ $0.presenter = .foundation }) {
            FailureWords.sentence(for: ConfigWriteFailure(underlying: secret), doing: "unit: config-edit")
        }
        XCTAssertEqual(sentence, "Lodestar could not save the config. Try again.")
        XCTAssertFalse(sentence.contains("/Users/someone"), "the error's own text is not shown: \(sentence)")
        XCTAssertFalse(sentence.contains("permission"), sentence)
        XCTAssertFalse(sentence.contains("—") || sentence.contains(";"), "the copy has no dashes or semicolons")
    }

    func testTheWholeErrorGoesToTheLogWithAReference() throws {
        let secret = CocoaError(.fileWriteNoPermission, userInfo: [NSLocalizedDescriptionKey: "no write to /Users/someone"])
        _ = FailureWords.sentence(for: ConfigWriteFailure(underlying: secret), doing: "unit: config-edit")
        let logged = try XCTUnwrap(lines.first { $0.contains("unit: config-edit") })
        XCTAssertTrue(logged.contains("ERR"), logged)
        XCTAssertTrue(logged.contains("reference="), logged)
        XCTAssertTrue(logged.contains("/Users/someone"), "the raw error is in the log: \(logged)")
    }

    func testAFoundationErrorIsWordedByTheFoundationPresenterWhenOneIsInstalled() {
        let sentence = withAmbient({ $0.presenter = .foundation }) {
            FailureWords.sentence(for: CocoaError(.fileWriteOutOfSpace), doing: "unit: disk")
        }
        XCTAssertTrue(sentence.hasPrefix("There isn't enough space on this device."), sentence)
    }

    // MARK: An edit of the config that did not happen

    private func shown(_ error: any Error) -> String {
        FailureWords.sentence(forEdit: error, doing: "unit: config-edit")
    }

    func testAStorageFailureIsSaidInLodestarsWordsAndItsTextGoesOnlyToTheLog() throws {
        let raw = "write(2) failed: No space left on device at /Users/someone/.config/lodestar/lodestar.json.tmp"
        let sentence = shown(Config.EditError.storage(raw))
        XCTAssertEqual(sentence, "Lodestar could not save the config. Try again.")
        let logged = try XCTUnwrap(lines.first { $0.contains("unit: config-edit") })
        XCTAssertTrue(logged.contains("reference="), logged)
        XCTAssertTrue(logged.contains("/Users/someone"), "the store's own text is in the log: \(logged)")
    }

    func testAConfigAnotherProcessIsWritingSaysToWaitAndNotHowLongTheLockWasWaitedFor() {
        let sentence = shown(Config.EditError.busy("waited 2 s for the lock on lodestar.json"))
        XCTAssertEqual(sentence, "Another copy of Lodestar is saving the config. Try again in a little while.")
    }

    func testAParseProblemKeepsItsLineAndColumn() {
        let sentence = shown(Config.EditError.unparsed("lodestar.json:3:5: unexpected end of input"))
        XCTAssertEqual(sentence, "The config has a problem at lodestar.json:3:5: unexpected end of input. "
                       + "Fix it, then try again.")
    }

    func testAValueTheSchemaRefusesKeepsWhatIsWrongWithIt() {
        let sentence = shown(Config.EditError.invalid("lode.trigger: must be one of hold, tap"))
        XCTAssertEqual(sentence, "That would make the config invalid: lode.trigger: must be one of hold, tap. "
                       + "Check what you entered.")
    }

    func testAConfigFromANewerLodestarSaysToUpdate() {
        XCTAssertEqual(shown(Config.EditError.newer("lodestar.json")),
                       "A newer Lodestar wrote the config. Update Lodestar.")
    }

    func testAPathTheHandTypedIsSaidAsTyped() {
        XCTAssertEqual(shown(GraphJsonEditor.EditError.taken("g")), "lode g is already bound.")
        XCTAssertEqual(shown(GraphJsonEditor.EditError.blockedByLeaf("g s")), "lode g s is already a destination.")
        XCTAssertEqual(shown(WebJsonEditor.EditError.taken(name: "gh", target: "github.com")),
                       "gh is already github.com.")
        XCTAssertEqual(shown(WebJsonEditor.EditError.noProfile), "Pick a profile. A route has to name one.")
    }

    /// The log is made to be pasted, so it never becomes a list of where
    /// someone goes: a refused link or route is shown with what they typed,
    /// and logged as which refusal it was.
    func testARefusedLinkOrRouteIsShownWithItsDestinationAndLoggedWithoutIt() throws {
        let refused: [any Error] = [
            WebJsonEditor.EditError.taken(name: "diary", target: "https://secret.example/me"),
            WebJsonEditor.EditError.missing("secret.example"),
            Config.EditError.invalid("web.routes.secret.example: expected a string"),
            Config.EditError.unparsed("lodestar.json:3:5: unexpected 'secret.example'"),
        ]
        for error in refused {
            lines = []
            XCTAssertTrue(shown(error).contains("secret.example"), "the person is told what it was")
            let logged = try XCTUnwrap(lines.first { $0.contains("unit: config-edit") })
            XCTAssertTrue(logged.contains("reference=") && logged.contains("refused=lodestar."), logged)
            XCTAssertFalse(lines.joined().contains("secret.example"), lines.joined())
        }
    }

    func testAnEditThatFailedSomeOtherWayIsAConfigWriteFailure() {
        XCTAssertEqual(shown(CocoaError(.fileWriteNoPermission)), "Lodestar could not save the config. Try again.")
    }

    /// Two problems in one edit, as the store words them.
    func testTwoRefusedValuesReadWithoutASemicolon() throws {
        XCTAssertThrowsError(try ConfigStore.file(from: ["app": .table(["sounds": .int(3)]),
                                                         "lode": .table(["trigger": .string("nonsense")])])) {
            let sentence = shown($0)
            XCTAssertTrue(sentence.contains("app.sounds") && sentence.contains("lode.trigger"), sentence)
            XCTAssertFalse(sentence.contains("—") || sentence.contains(";"), sentence)
        }
    }

    func testNoEditFailureIsShownWithADashOrASemicolon() {
        let all: [any Error] = [
            Config.EditError.unreadable("lodestar.json"), Config.EditError.unparsed("draft.input"),
            Config.EditError.invalid("scroll.speed: too fast"), Config.EditError.newer("lodestar.json"),
            Config.EditError.busy("waited"), Config.EditError.storage("disk"),
            GraphJsonEditor.EditError.missing("q"), WebJsonEditor.EditError.emptyName,
            WebJsonEditor.EditError.emptyPattern, WebJsonEditor.EditError.missing("nope"),
            WebJsonEditor.EditError.blocked("web"), WebJsonEditor.EditError.noProfile,
        ]
        for error in all {
            let sentence = shown(error)
            XCTAssertFalse(sentence.contains("—") || sentence.contains(";") || sentence.contains(" - "), sentence)
            XCTAssertTrue(sentence.hasSuffix("."), sentence)
        }
    }

    func testEveryRecoveryReadsAsPlainWords() {
        let all: [Recovery] = [.tryAgain, .wait(until: nil), .signInAgain, .changeInput(fields: []), .checkFirst,
                               .updateApp, .contactSupport, .nothing]
        for recovery in all {
            let words = FailureWords.recovery(recovery)
            XCTAssertFalse(words.contains("—") || words.contains(";") || words.contains(" - "), words)
        }
    }
}
