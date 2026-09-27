import XCTest
@testable import lodestar
@testable import LodestarCore

/// The Send Feedback window, driven the way a person drives it, with the
/// network stood in for.
final class FeedbackWindowTests: XCTestCase {
    private var controller: FeedbackController!
    private var sent: [URLRequest] = []
    private var answer: Int? = 200
    private var savedClipboard: String?

    override func setUp() {
        super.setUp()
        savedClipboard = NSPasteboard.general.string(forType: .string)
        sent = []
        answer = 200
        controller = FeedbackController()
        controller.report = { "REPORT" }
        controller.deliver = { [unowned self] request, done in
            self.sent.append(request)
            done(self.answer)
        }
        controller.show()
    }

    override func tearDown() {
        controller.close()
        controller = nil
        if let savedClipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(savedClipboard, forType: .string)
        }
        super.tearDown()
    }

    private func body(_ index: Int = 0) -> [String: String] {
        guard let data = sent[index].httpBody else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]
    }

    func testAnEmptyNoteIsNotSentAndSaysWhy() {
        controller.pressSend()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(controller.shownStatus, Feedback.Problem.empty.sentence)
    }

    func testABadReplyAddressIsNotSent() {
        controller.fill(message: "hello", replyTo: "not an address")
        controller.pressSend()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(controller.shownStatus, Feedback.Problem.replyAddress.sentence)
    }

    func testANoteIsSentAndThanked() {
        controller.fill(message: "It works", replyTo: "me@example.com")
        controller.pressSend()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(body()["message"], "It works")
        XCTAssertEqual(body()["replyTo"], "me@example.com")
        XCTAssertNil(body()["diagnostics"], "the report stays home unless it was asked for")
        XCTAssertTrue(controller.isSent)
    }

    func testTheReportGoesOnlyWhenAskedFor() {
        controller.fill(message: "It broke", attachReport: true)
        controller.pressSend()
        XCTAssertEqual(body()["diagnostics"], "REPORT")
    }

    func testAFailedSendLosesNothing() {
        answer = 503
        controller.fill(message: "It broke")
        controller.pressSend()
        XCTAssertFalse(controller.isSent)
        XCTAssertEqual(controller.shownStatus, FeedbackController.failure)
        XCTAssertEqual(controller.noteText, "It broke", "the window keeps the note")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string)?.hasPrefix("It broke"), true,
                       "and the clipboard has it too")
    }

    func testNoAnswerAtAllIsAFailureToo() {
        answer = nil
        controller.fill(message: "Offline")
        controller.pressSend()
        XCTAssertEqual(controller.shownStatus, FeedbackController.failure)
    }

    func testAfterTheThanksTheWindowOpensEmpty() {
        controller.fill(message: "One")
        controller.pressSend()
        controller.close()
        controller.show()
        XCTAssertEqual(controller.noteText, "", "a sent note is not offered again")
    }

    func testAnUnsentNoteWaitsForTheNextOpening() {
        controller.fill(message: "Half a thought")
        controller.close()
        controller.show()
        XCTAssertEqual(controller.noteText, "Half a thought")
    }

    func testTheFailureLineIsTheHouseVoice() {
        XCTAssertFalse(FeedbackController.failure.contains("—") || FeedbackController.failure.contains(";"))
    }
}
