import Testing
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The Send Feedback window, driven the way a person drives it, with the
/// site stood in for. What the queue does behind it is `FeedbackOutboxTests`.
@MainActor
final class FeedbackWindowTests: XCTestCase {
    func testAnEmptyNoteIsNotSentAndSaysWhy() async throws {
        try await FeedbackRig.run { rig, _ in
            rig.script([FeedbackRig.thanks])
            rig.controller.pressSend()
            XCTAssertEqual(rig.transport.requestCount, 0)
            XCTAssertEqual(rig.controller.shownStatus, Feedback.Problem.empty.sentence)
            let queued = await rig.queue.pendingCount
            XCTAssertEqual(queued, 0, "a note that may not be sent is not kept either")
            XCTAssertFalse(FileManager.default.fileExists(atPath: rig.directory.path), "and nothing is made for it")
        }
    }

    func testABadReplyAddressIsNotSent() async throws {
        try await FeedbackRig.run { rig, _ in
            rig.controller.fill(message: "hello", replyTo: "not an address")
            rig.controller.pressSend()
            XCTAssertEqual(rig.transport.requestCount, 0)
            XCTAssertEqual(rig.controller.shownStatus, Feedback.Problem.replyAddress.sentence)
        }
    }

    func testANoteIsSentAndThanked() async throws {
        try await FeedbackRig.run { rig, _ in
            rig.script([FeedbackRig.thanks])
            await rig.send("It works", replyTo: "me@example.com")
            XCTAssertEqual(rig.transport.requestCount, 1)
            XCTAssertEqual(rig.body()["message"], "It works")
            XCTAssertEqual(rig.body()["replyTo"], "me@example.com")
            XCTAssertNil(rig.body()["diagnostics"], "the report stays home unless it was asked for")
            XCTAssertTrue(rig.controller.isSent)
        }
    }

    func testTheReportGoesOnlyWhenAskedFor() async throws {
        try await FeedbackRig.run { rig, _ in
            rig.script([FeedbackRig.thanks])
            await rig.send("It broke", attachReport: true)
            XCTAssertEqual(rig.body()["diagnostics"], "REPORT")
        }
    }

    func testTheWindowShowsSendingWhileTheTryIsOut() async throws {
        try await FeedbackRig.run { rig, clock in
            rig.script([FeedbackRig.thanks.after(.seconds(5))])
            rig.controller.fill(message: "Slow")
            rig.controller.pressSend()
            // The scripted delay and the client's attempt timeout.
            await clock.waitForSleepers(count: 2)
            XCTAssertTrue(rig.controller.isSending)
            await clock.advance(by: .seconds(5))
            await rig.controller.settled()
            XCTAssertTrue(rig.controller.isSent)
        }
    }

    func testAfterTheThanksTheWindowOpensEmpty() async throws {
        try await FeedbackRig.run { rig, _ in
            rig.script([FeedbackRig.thanks])
            await rig.send("One")
            rig.controller.close()
            rig.controller.show()
            XCTAssertEqual(rig.controller.noteText, "", "a sent note is not offered again")
        }
    }

    func testAnUnsentNoteWaitsForTheNextOpening() async throws {
        try await FeedbackRig.run { rig, _ in
            rig.controller.fill(message: "Half a thought")
            rig.controller.close()
            rig.controller.show()
            XCTAssertEqual(rig.controller.noteText, "Half a thought")
        }
    }

    // MARK: - A note that did not arrive

    func testAnOfflineNoteIsSavedAndThePersonIsToldItWillBeSent() async throws {
        try await FeedbackRig.run { rig, _ in
            rig.script([FeedbackRig.offline])
            await rig.send("It broke")
            XCTAssertTrue(rig.controller.isSaved)
            XCTAssertFalse(rig.controller.isSent)
            XCTAssertNil(rig.controller.shownStatus)
            XCTAssertNil(rig.board.string(forType: .string), "the clipboard is not the way a note is kept any more")
            let queued = await rig.queue.pendingCount
            XCTAssertEqual(queued, 1)
        }
    }

    func testTheSavedPageOffersTheNoteOnTheClipboardForAnyoneWhoWantsItElsewhere() async throws {
        try await FeedbackRig.run { rig, _ in
            rig.script([FeedbackRig.offline])
            await rig.send("It broke", replyTo: "me@example.com")
            XCTAssertNil(rig.board.string(forType: .string))
            rig.controller.pressCopy()
            XCTAssertEqual(rig.board.string(forType: .string)?.hasPrefix("It broke"), true)
            XCTAssertEqual(rig.board.string(forType: .string)?.contains("me@example.com"), false,
                           "the clipboard has the note and where it came from, not the address")
        }
    }

    func testAfterTheSavedPageTheWindowOpensEmpty() async throws {
        try await FeedbackRig.run { rig, _ in
            rig.script([FeedbackRig.offline])
            await rig.send("One")
            rig.controller.close()
            rig.controller.show()
            XCTAssertEqual(rig.controller.noteText, "")
            XCTAssertFalse(rig.controller.isSaved)
        }
    }

    func testARefusedNoteStaysInTheWindowAndOnTheClipboard() async throws {
        try await FeedbackRig.run { rig, _ in
            rig.script([.status(400, body: #"{"error":"empty"}"#)])
            await rig.send("Not taken")
            XCTAssertFalse(rig.controller.isSent)
            XCTAssertFalse(rig.controller.isSaved)
            XCTAssertEqual(rig.controller.shownStatus, FeedbackController.refusal)
            XCTAssertEqual(rig.controller.noteText, "Not taken", "the window keeps the note")
            XCTAssertEqual(rig.board.string(forType: .string)?.hasPrefix("Not taken"), true, "and the clipboard has it too")
            let queued = await rig.queue.pendingCount
            XCTAssertEqual(queued, 0, "the queue has let go of it")
        }
    }

    func testARefusalIsStillThereWhenTheWindowIsOpenedAgain() async throws {
        try await FeedbackRig.run { rig, _ in
            rig.script([.status(400)])
            rig.controller.fill(message: "Not taken")
            rig.controller.pressSend()
            rig.controller.close()
            await rig.controller.settled()
            rig.controller.show()
            XCTAssertEqual(rig.controller.shownStatus, FeedbackController.refusal, "refused while the window was shut")
            XCTAssertEqual(rig.controller.noteText, "Not taken")
        }
    }

    func testANoteThatCannotBeSavedIsOnTheClipboardAndInTheWindow() async throws {
        // A file where the queue's folder should be: nothing can be kept.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-feedback-blocked-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocker.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: blocker) }
        try await FeedbackRig.run(directory: blocker) { rig, _ in
            rig.script([FeedbackRig.thanks])
            await rig.send("Nowhere to keep it")
            XCTAssertEqual(rig.transport.requestCount, 0, "a note that could not be kept is not sent: its key would be lost with it")
            XCTAssertEqual(rig.controller.shownStatus, FeedbackController.unsaved)
            XCTAssertEqual(rig.controller.noteText, "Nowhere to keep it")
            XCTAssertEqual(rig.board.string(forType: .string)?.hasPrefix("Nowhere"), true)
        }
    }

    func testTheWordsAreTheHouseVoice() {
        for line in [FeedbackController.refusal, FeedbackController.unsaved, FeedbackController.savedSentence] {
            XCTAssertFalse(line.contains("—") || line.contains(";"), line)
            XCTAssertTrue(line.hasSuffix("."), line)
        }
    }

    func testTheSavedSentenceSaysPlainlyWhatHappensNext() {
        XCTAssertTrue(FeedbackController.savedSentence.contains("saved"))
        XCTAssertTrue(FeedbackController.savedSentence.contains("send it on its own"))
    }
}
