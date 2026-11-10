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

    func testEveryRecoveryReadsAsPlainWords() {
        let all: [Recovery] = [.tryAgain, .wait(until: nil), .signInAgain, .changeInput(fields: []), .checkFirst,
                               .updateApp, .contactSupport, .nothing]
        for recovery in all {
            let words = FailureWords.recovery(recovery)
            XCTAssertFalse(words.contains("—") || words.contains(";") || words.contains(" - "), words)
        }
    }
}
