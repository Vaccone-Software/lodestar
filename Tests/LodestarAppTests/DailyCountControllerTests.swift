import Foundation
import Stoic
import StoicHTTP
import XCTest
import LodestarCore
@testable import lodestar

/// The daily count in the shell, on a clock of the test's own and a site
/// played by a scripted transport: the notice comes first and only counts
/// as seen when a key meets it, a day is sent once after its wait, a failed
/// send is tried three more times and then let go, the switch stops it, and
/// a copy that may not count never speaks.
@MainActor
final class DailyCountControllerTests: XCTestCase {
    /// A clock the test moves: work runs when the clock passes its moment.
    private final class Hands {
        var now: Date
        var queued: [(due: Date, work: DispatchWorkItem)] = []

        init(_ now: Date) { self.now = now }

        var clock: Clock {
            Clock(now: { [unowned self] in now }, after: { [unowned self] delay, work in
                queued.append((now.addingTimeInterval(delay), work))
            })
        }

        /// Move to `moment`, running every work item that falls due on the
        /// way, in order, including what they queue.
        func advance(to moment: Date) {
            while let next = queued.enumerated().filter({ $0.element.due <= moment })
                .min(by: { $0.element.due < $1.element.due }) {
                queued.remove(at: next.offset)
                now = max(now, next.element.due)
                if !next.element.work.isCancelled { next.element.work.perform() }
            }
            now = moment
        }

        func advance(by seconds: TimeInterval) { advance(to: now.addingTimeInterval(seconds)) }
    }

    /// 2026-11-12T15:00:00Z.
    private let noon = Date(timeIntervalSince1970: 1_794_495_600)
    private var hands: Hands!
    private var transport: ScriptedTransport!
    private var record = DailyCount.Record()
    private var notices: [String] = []
    private var lastKey = Date.distantPast
    private var quiet = true

    override func setUp() {
        super.setUp()
        hands = Hands(noon)
        transport = ScriptedTransport()
        record = DailyCount.Record()
        notices = []
        lastKey = .distantPast
        quiet = true
    }

    private func controller(eligible: Bool = true) -> DailyCountController {
        let controller = DailyCountController(eligible: eligible, clock: hands.clock,
                                              client: DailyCount.client(transport: transport), random: .seeded(3))
        controller.channel = { .preview }
        controller.lastHumanKeyAt = { [unowned self] in lastKey }
        controller.quiet = { [unowned self] in quiet }
        controller.stateKnown = { true }
        controller.read = { [unowned self] in record }
        controller.write = { [unowned self] in record = $0 }
        controller.evidence = { [unowned self] in [noon.addingTimeInterval(-10 * 86_400)] }
        controller.showNotice = { [unowned self] in notices.append($0) }
        current = controller
        return controller
    }

    private var sent: [HTTPRequest] { transport.requests }

    private var current: DailyCountController?

    /// Wait for the try in flight, if any, to come back: its answer lands
    /// on the main actor before the task ends.
    private func settle() async {
        await current?.inFlight?.value
    }

    /// Show the notice and strike a key while it stands.
    private func seeNotice(_ controller: DailyCountController) {
        controller.used(byHand: true)
        XCTAssertEqual(notices, [DailyCount.notice])
        lastKey = hands.now.addingTimeInterval(2)
        hands.advance(by: HUD.heldCeiling + 1)
    }

    func testACopyThatMayNotCountNeverSpeaks() async {
        let controller = controller(eligible: false)
        controller.start()
        controller.used(byHand: true)
        hands.advance(by: 86_400)
        await settle()
        XCTAssertEqual(notices, [])
        XCTAssertEqual(record, DailyCount.Record())
        XCTAssertEqual(sent.count, 0)
    }

    func testAUseWithoutAHandIsNotAUse() {
        let controller = controller()
        controller.used(byHand: false)
        controller.used() // a fix with no key for an hour
        XCTAssertEqual(notices, [])
        lastKey = hands.now.addingTimeInterval(-60)
        controller.used() // a fix a minute after a key
        XCTAssertEqual(notices, [DailyCount.notice])
    }

    func testTheNoticeWaitsForQuietAndOnlyAKeyMakesItSeen() {
        let controller = controller()
        quiet = false
        controller.used(byHand: true)
        hands.advance(by: 30)
        XCTAssertEqual(notices, [], "never over a chain, a bar or a chip")
        quiet = true
        hands.advance(by: DailyCountController.noticePoll)
        XCTAssertEqual(notices.count, 1)
        // Nobody struck a key while it stood.
        hands.advance(by: HUD.heldCeiling + 1)
        XCTAssertNil(record.noticeSeenAt)
        XCTAssertNil(record.pending, "nothing waits to be sent before the notice is seen")
        controller.used(byHand: true)
        XCTAssertEqual(notices.count, 1, "not again within half an hour")
        hands.advance(by: DailyCountController.noticeSpacing)
        controller.used(byHand: true)
        XCTAssertEqual(notices.count, 2)
    }

    func testOnceSeenTheDayIsSentOnceAfterItsWait() async throws {
        transport.on(.post(DailyCount.path, body: [], contentType: "application/json"), respond: [.status(204)])
        let controller = controller()
        controller.start()
        seeNotice(controller)
        XCTAssertNotNil(record.noticeSeenAt)
        XCTAssertEqual(record.installedAt, noon.addingTimeInterval(-10 * 86_400), "the oldest evidence")
        let pending = try XCTUnwrap(record.pending)
        XCTAssertEqual(pending.day, "2026-11-12")
        XCTAssertLessThanOrEqual(pending.due.timeIntervalSince(noon), DailyCount.maximumDelay + HUD.heldCeiling + 1)
        XCTAssertEqual(sent.count, 0, "not before its moment")

        hands.advance(to: pending.due)
        await settle()
        XCTAssertEqual(sent.count, 1)
        let body = try XCTUnwrap(sent.first?.body)
        XCTAssertEqual(String(decoding: body, as: UTF8.self),
                       #"{"age":"7-29","channel":"preview","version":"\#(Lodestar.version)"}"#)
        XCTAssertEqual(record.lastSentDay, "2026-11-12")
        XCTAssertNil(record.pending)

        // More uses the same day send nothing more.
        controller.used(byHand: true)
        hands.advance(by: 3 * 3600)
        await settle()
        XCTAssertEqual(sent.count, 1)

        // The next UTC day is a new day.
        hands.advance(to: Date(timeIntervalSince1970: 1_794_528_000 + 3600)) // 2026-11-13T01:00Z
        controller.used(byHand: true)
        hands.advance(by: DailyCount.maximumDelay)
        await settle()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(record.lastSentDay, "2026-11-13")
    }

    func testAFailedSendIsTriedThreeMoreTimesAndThenLetGo() async throws {
        transport.on(.post(DailyCount.path, body: [], contentType: "application/json"), respond: [.status(503)])
        let controller = controller()
        seeNotice(controller)
        let pending = try XCTUnwrap(record.pending)
        hands.advance(to: pending.due)
        await settle()
        for _ in 0..<3 {
            hands.advance(by: 1800)
            await settle()
        }
        hands.advance(by: 3 * 3600)
        await settle()
        XCTAssertEqual(sent.count, 4)
        XCTAssertNil(record.lastSentDay)
    }

    func testARefusalSettlesTheDay() async throws {
        transport.on(.post(DailyCount.path, body: [], contentType: "application/json"), respond: [.status(400)])
        let controller = controller()
        seeNotice(controller)
        hands.advance(to: try XCTUnwrap(record.pending).due)
        await settle()
        hands.advance(by: 3 * 3600)
        await settle()
        XCTAssertEqual(sent.count, 1, "a 400 is not tried again")
        XCTAssertNil(record.pending)
        XCTAssertNil(record.lastSentDay, "refused is not counted")
    }

    func testTurningItOffForgetsTheWaitingDay() async throws {
        transport.on(.post(DailyCount.path, body: [], contentType: "application/json"), respond: [.status(204)])
        let controller = controller()
        seeNotice(controller)
        XCTAssertNotNil(record.pending)
        controller.enabled = false
        XCTAssertNil(record.pending)
        controller.used(byHand: true)
        hands.advance(by: 86_400)
        await settle()
        XCTAssertEqual(sent.count, 0)
    }

    func testALaunchTakesUpTodaysWaitingDayAndDropsYesterdays() async {
        transport.on(.post(DailyCount.path, body: [], contentType: "application/json"), respond: [.status(204)])
        record = DailyCount.Record(installedAt: noon, noticeSeenAt: noon,
                                   pending: DailyCount.Pending(day: "2026-11-12", due: noon.addingTimeInterval(-600)))
        let controller = controller()
        controller.start()
        hands.advance(by: DailyCountController.settle - 1)
        await settle()
        XCTAssertEqual(sent.count, 0, "a minute for the network after a launch")
        hands.advance(by: 1)
        await settle()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(record.lastSentDay, "2026-11-12")

        record = DailyCount.Record(installedAt: noon, noticeSeenAt: noon,
                                   pending: DailyCount.Pending(day: "2026-11-11", due: noon.addingTimeInterval(-86_400)))
        let next = self.controller()
        next.start()
        hands.advance(by: 3600)
        await settle()
        XCTAssertEqual(sent.count, 1, "yesterday's day goes uncounted")
        XCTAssertNil(record.pending)
    }
}
