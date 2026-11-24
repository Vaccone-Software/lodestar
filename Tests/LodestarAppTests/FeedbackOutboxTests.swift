import Testing
import Foundation
import StoicHTTP
import StoicStore
import XCTest
@testable import lodestar
@testable import LodestarCore

/// A note is never lost and never sent twice: through the window, the queue
/// on disk, the client and a script for the site, on a clock the test moves.
@MainActor
final class FeedbackOutboxTests: XCTestCase {
    private func isHex32(_ key: String?) -> Bool {
        key?.count == 32 && key?.allSatisfy { $0.isHexDigit && !$0.isUppercase } == true
    }

    func testDeliveredOnTheFirstTry() async throws {
        try await FeedbackRig.run { rig, clock in
            rig.script([FeedbackRig.thanks])
            await rig.send("It works")
            XCTAssertTrue(rig.controller.isSent)
            XCTAssertEqual(rig.transport.requestCount, 1)
            XCTAssertTrue(isHex32(rig.key()), "one key for the note, sent as the header")
            let queued = await rig.queue.pendingCount
            XCTAssertEqual(queued, 0, "acknowledged, so gone from the outbox")
            XCTAssertEqual(clock.sleeperCount, 0, "nothing is left to retry, so nothing waits")
        }
    }

    func testTheRequestIsTheNoteWithItsHeaders() async throws {
        try await FeedbackRig.run { rig, _ in
            rig.script([FeedbackRig.thanks])
            await rig.send("Words", replyTo: "me@example.com", attachReport: true)
            let sent = rig.transport.requests[0]
            XCTAssertEqual(sent.url?.absoluteString, "https://lodestar.vaccone.software/api/feedback")
            XCTAssertEqual(sent.method, .post)
            XCTAssertEqual(sent.headers["Content-Type"], "application/json")
            XCTAssertEqual(sent.headers["x-lodestar-feedback"], "1")
            XCTAssertEqual(rig.body(), ["message": "Words", "replyTo": "me@example.com", "version": Lodestar.version,
                                        "macos": Feedback.macosVersion, "diagnostics": "REPORT"])
        }
    }

    func testOfflineThenDeliveredOnTheRetryWithTheSameKey() async throws {
        try await FeedbackRig.run { rig, clock in
            rig.script([FeedbackRig.offline, FeedbackRig.thanks])
            await rig.send("It broke")
            XCTAssertTrue(rig.controller.isSaved)
            XCTAssertEqual(rig.transport.requestCount, 1)
            await clock.waitForSleepers()
            // The first wait is a minute, drawn between half and the whole.
            await clock.advance(by: .seconds(29))
            XCTAssertEqual(rig.transport.requestCount, 1, "not before half a minute")
            await clock.advance(by: .seconds(31))
            await rig.queue.loopFinished()
            XCTAssertEqual(rig.transport.requestCount, 2)
            XCTAssertEqual(rig.key(1), rig.key(0), "a retry is the same note, so the site can tell")
            XCTAssertEqual(rig.body(1), rig.body(0))
            let queued = await rig.queue.pendingCount
            XCTAssertEqual(queued, 0)
        }
    }

    func testAServerErrorAndTheNotSetUpAnswerAreRetriedToo() async throws {
        for failure in [503, 502, 500, 429, 504] {
            try await FeedbackRig.run { rig, clock in
                rig.script([.status(failure, body: #"{"error":"feedback is not set up"}"#), FeedbackRig.thanks])
                await rig.send("Later")
                XCTAssertTrue(rig.controller.isSaved, "\(failure)")
                await clock.waitForSleepers()
                await clock.advance(by: .seconds(60))
                await rig.queue.loopFinished()
                XCTAssertEqual(rig.transport.requestCount, 2, "\(failure)")
                XCTAssertEqual(rig.key(1), rig.key(0))
            }
        }
    }

    func testATimeoutIsKeptAndRetriedAfterTwentySeconds() async throws {
        try await FeedbackRig.run { rig, clock in
            rig.script([.hang, FeedbackRig.thanks])
            rig.controller.fill(message: "Never answered")
            rig.controller.pressSend()
            // The attempt timeout is the only sleeper: the transport hangs on no clock.
            await clock.waitForSleepers()
            XCTAssertTrue(rig.controller.isSending)
            await clock.advance(by: .seconds(19))
            XCTAssertTrue(rig.controller.isSending, "a try has twenty seconds")
            await clock.advance(by: .seconds(1))
            await rig.controller.settled()
            XCTAssertTrue(rig.controller.isSaved)
            XCTAssertEqual(rig.transport.abortedCount, 1)
            let queued = await rig.queue.pendingCount
            XCTAssertEqual(queued, 1)
        }
    }

    func testAPageThatIsNotTheSitesAnswerIsNotADelivery() async throws {
        try await FeedbackRig.run { rig, clock in
            rig.script([.status(200, body: "<html>Sign in to the wifi</html>"), FeedbackRig.thanks])
            await rig.send("Behind a portal")
            XCTAssertTrue(rig.controller.isSaved)
            XCTAssertFalse(rig.controller.isSent)
            await clock.waitForSleepers()
            await clock.advance(by: .seconds(60))
            await rig.queue.loopFinished()
            XCTAssertEqual(rig.transport.requestCount, 2)
            let queued = await rig.queue.pendingCount
            XCTAssertEqual(queued, 0)
        }
    }

    func testARefusedNoteIsRemovedAndNeverSentAgain() async throws {
        try await FeedbackRig.run { rig, clock in
            rig.script([.status(400, body: #"{"error":"empty"}"#), FeedbackRig.thanks])
            await rig.send("Not taken")
            let queued = await rig.queue.pendingCount
            XCTAssertEqual(queued, 0)
            XCTAssertEqual(clock.sleeperCount, 0, "no schedule is left running for it")
            await clock.advance(by: .seconds(7200))
            XCTAssertEqual(rig.transport.requestCount, 1, "a refusal is final")
        }
    }

    func testARefusedNoteDoesNotHoldTheOnesAfterIt() async throws {
        try await FeedbackRig.run { rig, _ in
            rig.script([.status(400), FeedbackRig.thanks])
            await rig.send("Refused")
            rig.controller.fill(message: "Fine")
            rig.controller.pressSend()
            await rig.controller.settled()
            XCTAssertTrue(rig.controller.isSent)
            XCTAssertEqual(rig.messages, ["Refused", "Fine"])
        }
    }

    func testANoteSurvivesARelaunchAndIsDeliveredWithItsKey() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-feedback-relaunch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var firstKey: String?
        var firstBody: [String: String] = [:]
        try await FeedbackRig.run(directory: directory) { rig, _ in
            rig.script([FeedbackRig.offline])
            await rig.send("Written on a plane", replyTo: "me@example.com")
            XCTAssertTrue(rig.controller.isSaved)
            firstKey = rig.key()
            firstBody = rig.body()
        }
        // The first run is gone. A new one finds the note where it was left.
        try await FeedbackRig.run(directory: directory) { rig, clock in
            rig.script([FeedbackRig.thanks])
            await rig.queue.resume()
            await clock.waitForSleepers()
            XCTAssertEqual(rig.transport.requestCount, 0, "not at once: the launch is busy")
            await clock.advance(by: FeedbackQueue.launchDelay)
            await rig.queue.loopFinished()
            XCTAssertEqual(rig.transport.requestCount, 1)
            XCTAssertEqual(rig.key(), firstKey, "the same note, the same key, across the launch")
            XCTAssertEqual(rig.body(), firstBody)
            let queued = await rig.queue.pendingCount
            XCTAssertEqual(queued, 0)
        }
    }

    func testALaunchWithNothingQueuedOpensNothing() async throws {
        try await FeedbackRig.run { rig, clock in
            await rig.queue.resume()
            XCTAssertEqual(clock.sleeperCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: rig.directory.path))
        }
    }

    func testALaunchThatFindsTheQueueEmptyStopsAfterOneLook() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-feedback-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await FeedbackRig.run(directory: directory) { rig, _ in
            rig.script([FeedbackRig.thanks])
            await rig.send("Delivered")
        }
        try await FeedbackRig.run(directory: directory) { rig, clock in
            await rig.queue.resume()
            await clock.waitForSleepers()
            await clock.advance(by: FeedbackQueue.launchDelay)
            await rig.queue.loopFinished()
            XCTAssertEqual(rig.transport.requestCount, 0)
            XCTAssertEqual(clock.sleeperCount, 0)
        }
    }

    func testQueuedNotesAreDeliveredOldestFirstByTheSchedule() async throws {
        try await FeedbackRig.run { rig, clock in
            rig.script([FeedbackRig.offline])
            await rig.send("First")
            XCTAssertTrue(rig.controller.isSaved)
            rig.controller.show()
            await rig.send("Second")
            XCTAssertTrue(rig.controller.isSaved)
            XCTAssertEqual(rig.messages, ["First", "Second"], "each is tried when it is sent")
            let queued = await rig.queue.pendingCount
            XCTAssertEqual(queued, 2)
            rig.script([FeedbackRig.thanks])
            await clock.waitForSleepers()
            await clock.advance(by: .seconds(60))
            await rig.queue.loopFinished()
            XCTAssertEqual(rig.messages, ["First", "Second", "First", "Second"], "oldest first")
            XCTAssertEqual(Set([rig.key(0), rig.key(1)]).count, 2, "each note has a key of its own")
            XCTAssertEqual(rig.key(2), rig.key(0))
            XCTAssertEqual(rig.key(3), rig.key(1))
            let remaining = await rig.queue.pendingCount
            XCTAssertEqual(remaining, 0)
        }
    }

    /// A note that cannot go does not hold a new one: the new note is
    /// tried at once and, if the site takes it, is delivered; the older one
    /// is tried once more in the same go, and stays queued if it still fails.
    func testANewNoteIsNotHeldBehindOneThatIsFailing() async throws {
        try await FeedbackRig.run { rig, _ in
            rig.script([FeedbackRig.offline, FeedbackRig.thanks, FeedbackRig.offline])
            await rig.send("Stuck")
            XCTAssertTrue(rig.controller.isSaved)
            rig.controller.show()
            await rig.send("Fine")
            XCTAssertTrue(rig.controller.isSent, "the new note went")
            XCTAssertEqual(rig.messages, ["Stuck", "Fine", "Stuck"])
            let queued = await rig.queue.pendingCount
            XCTAssertEqual(queued, 1, "the stuck one is still queued, and the schedule has it")
        }
    }

    func testANewNoteIsTriedAgainInAMinuteNotAtTheEndOfAnHour() async throws {
        try await FeedbackRig.run { rig, clock in
            rig.script([FeedbackRig.offline])
            await rig.send("Old")
            await clock.waitForSleepers()
            // The schedule runs on to its hourly step...
            for wait in [60, 300, 1800] {
                await rig.tick(to: clock.now.advanced(by: .seconds(wait)), on: clock)
            }
            let before = rig.transport.requestCount
            rig.controller.show()
            await rig.send("New")
            // ...and a new note that cannot go starts it over.
            XCTAssertEqual(rig.transport.requestCount, before + 1)
            await clock.waitForSleepers()
            await rig.tick(to: clock.now.advanced(by: .seconds(60)), on: clock)
            XCTAssertEqual(rig.transport.requestCount, before + 2)
        }
    }

    func testItKeepsTryingAMinuteFiveHalfAnHourThenEveryHour() async throws {
        try await FeedbackRig.run { rig, clock in
            rig.script([FeedbackRig.offline])
            await rig.send("Patient")
            await clock.waitForSleepers()
            var tries = rig.transport.requestCount
            XCTAssertEqual(tries, 1)
            for wait in [60, 300, 1800, 3600, 3600, 3600] {
                let next = try XCTUnwrap(clock.pendingDeadlines.first)
                XCTAssertEqual(clock.pendingDeadlines.count, 1, "the schedule's wait is all that sleeps")
                let nap = clock.now.duration(to: next)
                XCTAssertGreaterThanOrEqual(nap, .seconds(wait) / 2, "jittered, never under half")
                XCTAssertLessThanOrEqual(nap, .seconds(wait), "and never over the step")
                await rig.tick(to: next, on: clock)
                tries += 1
                XCTAssertEqual(rig.transport.requestCount, tries)
            }
            let queued = await rig.queue.pendingCount
            XCTAssertEqual(queued, 1, "it never gives up on a note")
        }
    }

    func testNeverTwoDeliveriesAtOnce() async throws {
        try await FeedbackRig.run { rig, clock in
            // Each answer takes five seconds to come.
            rig.script([FeedbackRig.thanks.after(.seconds(5))])
            let first = Task { await rig.queue.submit(Feedback(message: "A")) }
            await clock.waitForSleepers(count: 2)
            // A second note arrives while the first is out.
            let second = Task { await rig.queue.submit(Feedback(message: "B")) }
            while await rig.queue.deliveriesInProgress < 2 { await Task.yield() }
            XCTAssertEqual(rig.transport.requestCount, 1, "B waits for A's run, and does not start its own")
            let mark = clock.totalSleeps
            await clock.advance(by: .seconds(5))
            await clock.waitForSleepers(newerThan: mark, count: 2)
            await clock.advance(by: .seconds(5))
            let (a, b) = await (first.value, second.value)
            XCTAssertEqual([a, b], [.delivered, .delivered])
            XCTAssertEqual(rig.transport.maxInFlightCount, 1)
            XCTAssertEqual(rig.messages, ["A", "B"])
        }
    }

    func testTheScheduleDoesNotStartARunWhileASendIsInFlight() async throws {
        try await FeedbackRig.run { rig, clock in
            // The first try fails; every later answer takes fifteen seconds.
            rig.script([FeedbackRig.offline, FeedbackRig.thanks.after(.seconds(15))])
            await rig.send("Old")
            await clock.waitForSleepers()
            let due = try XCTUnwrap(clock.pendingDeadlines.first, "the schedule is waiting for its first tick")
            await clock.advance(to: due.advanced(by: .seconds(-1)))
            XCTAssertEqual(rig.transport.requestCount, 1)
            // A new note is sent a second before the tick...
            rig.controller.show()
            rig.controller.fill(message: "New")
            rig.controller.pressSend()
            // (the loop's own wait, the answer's delay, the try's timeout)
            await clock.waitForSleepers(count: 3)
            XCTAssertEqual(rig.messages, ["Old", "New"], "the new note is tried at once, not held behind the old")
            // ...and the tick comes due while it is out: it finds the queue
            // busy and goes back to sleep, having started nothing.
            var mark = clock.totalSleeps
            await clock.advance(to: due)
            await clock.waitForSleepers(newerThan: mark)
            XCTAssertEqual(rig.transport.requestCount, 2, "the tick starts no try of its own")
            // The new note is answered; the old one is tried in the same go.
            mark = clock.totalSleeps
            await clock.advance(by: .seconds(15))
            await clock.waitForSleepers(newerThan: mark, count: 2)
            XCTAssertEqual(rig.messages, ["Old", "New", "Old"], "each note went once more, and no more")
            await clock.advance(by: .seconds(15))
            await rig.controller.settled()
            XCTAssertTrue(rig.controller.isSent)
            // Nothing is queued: the schedule's next look ends it.
            await clock.advance(by: .seconds(7200))
            await rig.queue.loopFinished()
            XCTAssertEqual(rig.transport.maxInFlightCount, 1)
            XCTAssertEqual(rig.messages, ["Old", "New", "Old"])
        }
    }

    func testANoteThatNoLongerReadsIsDroppedAndDoesNotHoldTheRest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-feedback-garbled-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Something in the outbox that is not a note: a format this build
        // cannot read, or damage the journal's own checks let through.
        try PosixFileSystem().createDirectory(directory.path)
        let outbox = try Outbox<[UInt8]>.open(
            at: directory.appendingPathComponent("outbox").path, codec: .bytes, fileSystem: FeedbackQueue.privateFileSystem())
        try await outbox.enqueue(Array("not a note".utf8))
        try await outbox.close()
        try await FeedbackRig.run(directory: directory) { rig, _ in
            rig.script([FeedbackRig.thanks])
            await rig.send("A real one")
            XCTAssertTrue(rig.controller.isSent, "the note behind it was delivered in the same go")
            XCTAssertEqual(rig.messages, ["A real one"])
            let queued = await rig.queue.pendingCount
            XCTAssertEqual(queued, 0)
        }
    }

    // MARK: - On disk

    func testTheQueueIsPrivateAndOutOfBackups() async throws {
        try await FeedbackRig.run { rig, _ in
            rig.script([FeedbackRig.offline])
            await rig.send("Private words")
            let fm = FileManager.default
            func mode(_ url: URL) -> Int { (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1 }
            XCTAssertEqual(mode(rig.directory), 0o700)
            let names = try fm.contentsOfDirectory(atPath: rig.directory.path)
            XCTAssertFalse(names.isEmpty)
            for name in names {
                XCTAssertEqual(mode(rig.directory.appendingPathComponent(name)), 0o600, name)
            }
            let excluded = try rig.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            XCTAssertEqual(excluded, true)
        }
    }

    func testTheLogNeverCarriesTheNote() async throws {
        var lines: [String] = []
        let saved = Log.listener
        Log.listener = { lines.append($0) }
        defer { Log.listener = saved }
        try await FeedbackRig.run { rig, clock in
            rig.script([FeedbackRig.offline, .status(400), FeedbackRig.thanks])
            await rig.send("SECRET-WORDS", replyTo: "secret@example.com", attachReport: true)
            rig.controller.show()
            await clock.waitForSleepers()
            await clock.advance(by: .seconds(60))
            await rig.queue.loopFinished()
            rig.controller.show()
            await rig.send("SECRET-WORDS-2", replyTo: "secret@example.com")
        }
        let log = lines.joined(separator: "\n")
        XCTAssertTrue(log.contains("feedback"), "it does say what happened")
        XCTAssertFalse(log.contains("SECRET"), "the note")
        XCTAssertFalse(log.contains("secret@example.com"), "the reply address")
        XCTAssertFalse(log.contains("REPORT"), "the report")
    }
}
