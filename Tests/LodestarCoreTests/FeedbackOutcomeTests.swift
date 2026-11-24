import Foundation
import Stoic
import StoicHTTP
import XCTest
@testable import LodestarCore

/// What a try at the site came to: delivered, refused for good, or kept
/// for the next. Every status the site can give, and every way the road to
/// it can fail, has one answer.
final class FeedbackOutcomeTests: XCTestCase {
    private func status(_ code: Int) -> HTTPError {
        .status(code, excerpt: "", retryAfter: nil, keyed: true, attempts: 1)
    }

    func testTheSitesOwnYesIsDelivered() {
        XCTAssertEqual(FeedbackOutcome.classify(HTTPResponse(status: 200, body: Array(#"{"ok":true}"#.utf8))), .delivered)
        XCTAssertEqual(FeedbackOutcome.classify(HTTPResponse(status: 200, body: Array(#"{ "ok" : true }"#.utf8))), .delivered)
    }

    func testAnyOtherTwoHundredIsNotProofOfDelivery() {
        // A wifi sign-in page answers 200 to everything; acknowledging a note
        // on its word would lose the note.
        for body in ["<html>Sign in to wifi</html>", "", "{}", #"{"ok":false}"#, #"{"ok":"true"}"#, #"{"ok":1}"#, "[true]"] {
            XCTAssertEqual(FeedbackOutcome.classify(HTTPResponse(status: 200, body: Array(body.utf8))),
                           .unsent(.unrecognized), body)
        }
        for code in [201, 202, 204] {
            XCTAssertEqual(FeedbackOutcome.classify(HTTPResponse(status: code, body: Array(#"{"ok":true}"#.utf8))),
                           .unsent(.status(code)), "only exactly 200 is the site's answer")
        }
    }

    func testOnlyA400IsRefusedForGood() {
        XCTAssertEqual(FeedbackOutcome.classify(status(400)), .refused)
    }

    func testEveryOtherStatusIsKept() {
        // 503 is "not set up", 502 Resend out of reach, 429 and the 5xx the
        // site's host gives; the 4xx that are not about the note (a 403 from
        // a firewall, a 404 in the middle of a deploy) are about the road.
        for code in [401, 403, 404, 405, 408, 409, 413, 422, 425, 429, 500, 502, 503, 504] {
            XCTAssertEqual(FeedbackOutcome.classify(status(code)), .unsent(.status(code)), "\(code)")
        }
    }

    func testNoAnswerIsKept() {
        XCTAssertEqual(FeedbackOutcome.classify(HTTPError.timedOut(attempt: 1)), .unsent(.timeout))
        for code in [URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                     .dnsLookupFailed, .secureConnectionFailed, .badServerResponse] {
            XCTAssertEqual(FeedbackOutcome.classify(HTTPError.transport(code, attempts: 1)), .unsent(.network), "\(code)")
        }
        XCTAssertEqual(FeedbackOutcome.classify(URLError(.notConnectedToInternet)), .unsent(.network))
    }

    func testAFailureOfTheClientsOwnMakingIsKeptToo() {
        XCTAssertEqual(FeedbackOutcome.classify(HTTPError.responseTooLarge(limit: 1, attempts: 1)), .unsent(.unrecognized))
        XCTAssertEqual(FeedbackOutcome.classify(HTTPError.redirectRefused(.downgrade, status: 301, location: "", attempts: 1)),
                       .unsent(.unrecognized))
    }

    func testOnlyDeliveredAndRefusedLeaveTheQueue() {
        // The queue acknowledges exactly the outcomes that are not `unsent`.
        let leaving: [FeedbackOutcome] = [.delivered, .refused]
        let staying: [FeedbackOutcome] = [.unsent(.network), .unsent(.timeout), .unsent(.status(503)), .unsent(.unrecognized)]
        for outcome in leaving { if case .unsent = outcome { XCTFail("\(outcome)") } }
        for outcome in staying { if case .unsent = outcome {} else { XCTFail("\(outcome)") } }
    }

    func testTheLogWordsCarryNoNoteAndNoAddress() {
        let words = [FeedbackOutcome.delivered, .refused, .unsent(.network), .unsent(.timeout), .unsent(.status(503)),
                     .unsent(.unrecognized)].map(\.word)
        XCTAssertEqual(words, ["delivered", "refused", "unsent_network", "unsent_timeout", "unsent_status_503",
                               "unsent_unrecognized"])
    }
}
