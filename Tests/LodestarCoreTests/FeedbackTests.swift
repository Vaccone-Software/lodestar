import Stoic
import StoicHTTP
import XCTest
@testable import LodestarCore

/// The note on its way: what may go, what goes, and the door it goes to.
final class FeedbackTests: XCTestCase {
    private func decoded(_ feedback: Feedback) -> [String: String] {
        (try? JSONSerialization.jsonObject(with: feedback.payload)) as? [String: String] ?? [:]
    }

    func testANoteNeedsWords() {
        XCTAssertEqual(Feedback(message: "").problem, .empty)
        XCTAssertEqual(Feedback(message: "  \n\t ").problem, .empty)
        XCTAssertNil(Feedback(message: "The launcher is lovely").problem)
    }

    func testANoteTheEndpointWouldCutIsRefusedInstead() {
        XCTAssertNil(Feedback(message: String(repeating: "a", count: Feedback.messageLimit)).problem)
        XCTAssertEqual(Feedback(message: String(repeating: "a", count: Feedback.messageLimit + 1)).problem,
                       .tooLong)
    }

    func testTheReplyAddressIsOptionalButMustLookLikeOne() {
        XCTAssertNil(Feedback(message: "hi", replyTo: "").problem)
        XCTAssertNil(Feedback(message: "hi", replyTo: " a@b.co ").problem)
        XCTAssertNil(Feedback(message: "hi", replyTo: "first.last+lodestar@mail.example.org").problem)
        for bad in ["someone", "a@b", "a b@c.d", "@b.co", "a@@b.co"] {
            XCTAssertEqual(Feedback(message: "hi", replyTo: bad).problem, .replyAddress, bad)
        }
    }

    func testEveryProblemIsASentence() {
        for problem: Feedback.Problem in [.empty, .tooLong, .replyAddress] {
            XCTAssertTrue(problem.sentence.hasSuffix("."), "\(problem)")
            XCTAssertFalse(problem.sentence.contains("—") || problem.sentence.contains(";"),
                           "the voice has no dashes or semicolons")
        }
    }

    func testThePayloadCarriesTheNoteAndWhereItCameFrom() {
        let body = decoded(Feedback(message: "  It works \n", replyTo: " me@example.com ",
                                    version: "0.39.1", macos: "26.1.0"))
        XCTAssertEqual(body, ["message": "It works", "replyTo": "me@example.com",
                              "version": "0.39.1", "macos": "26.1.0"])
    }

    func testNothingOptionalIsSentEmpty() {
        let body = decoded(Feedback(message: "hi", version: "1", macos: "2", diagnostics: ""))
        XCTAssertNil(body["replyTo"], "no address, no key: a note needs no identity")
        XCTAssertNil(body["diagnostics"], "a report is only there when it was asked for")
    }

    func testALongReportKeepsItsNewestLines() {
        let report = "OLDEST\n" + String(repeating: "x", count: Feedback.diagnosticsLimit) + "\nNEWEST"
        let sent = decoded(Feedback(message: "hi", diagnostics: report))["diagnostics"] ?? ""
        XCTAssertEqual(sent.count, Feedback.diagnosticsLimit)
        XCTAssertTrue(sent.hasSuffix("NEWEST"), "the log tail is the end of the report")
        XCTAssertFalse(sent.contains("OLDEST"))
    }

    func testTheRequestGoesToTheSiteAndSaysWhereItIsFrom() async throws {
        let transport = ScriptedTransport()
        transport.on(.post(Feedback.path, body: [], contentType: "application/json"), respond: [.json(#"{"ok":true}"#)])
        let note = Feedback(message: "hi")
        try await Feedback.client(transport: transport).send(note.httpRequest, idempotencyKey: IdempotencyKey(rawValue: "key-1"))
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.url?.absoluteString, "https://lodestar.vaccone.software/api/feedback")
        XCTAssertEqual(sent.method, .post)
        XCTAssertEqual(sent.headers["x-lodestar-feedback"], "1")
        XCTAssertEqual(sent.headers["Content-Type"], "application/json")
        XCTAssertEqual(sent.headers["Idempotency-Key"], "key-1", "the client's keyed send adds it, not the note")
        XCTAssertEqual(sent.body, [UInt8](note.payload))
        XCTAssertEqual(Feedback.endpoint.absoluteString, "https://lodestar.vaccone.software/api/feedback")
    }

    func testTheNoteItselfCarriesNoKey() {
        XCTAssertNil(Feedback(message: "hi").httpRequest.idempotencyKey)
        XCTAssertFalse(Feedback(message: "hi").httpRequest.headers.contains("Idempotency-Key"))
    }

    func testATryIsTwentySecondsWithNothingOfTheClientsOwnToRetryWith() {
        let policy = Feedback.client().policy
        XCTAssertEqual(policy.attemptTimeout, .seconds(20))
        XCTAssertEqual(policy.schedule.maximumAttempts, 1, "the outbox is the retry layer")
        XCTAssertNil(policy.breaker)
    }

    func testTheAppNamesNoAddressOfItsMaker() {
        // The address lives in the site's environment. The only address
        // the request may carry is one the person typed.
        let body = String(data: Feedback(message: "hi").payload, encoding: .utf8) ?? ""
        XCTAssertFalse(body.contains("@"))
    }

    func testTheClipboardCopyIsTheNoteThenWhereItCameFrom() {
        let copy = Feedback(message: " Broken \n", version: "0.39.1", macos: "26.1.0").clipboardCopy
        XCTAssertEqual(copy, "Broken\n\n(Lodestar 0.39.1, macOS 26.1.0)")
    }
}
