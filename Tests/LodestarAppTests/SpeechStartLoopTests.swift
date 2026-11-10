import AVFoundation
import LodestarCore
import Stoic
import StoicTesting
import Testing
import XCTest
@testable import lodestar

/// The loop that opens the headset's microphone, with a start that throws
/// what each test says. It needs no engine: the loop is handed the start,
/// the bridge's re-arm, the session's stopped flag and the draft's voice.
///
/// Each catch has its own meaning, and the draft's state (listening, failed,
/// wedged, or nothing said at all) follows from it. The audio start has a
/// history of regressions, and these pin every outcome the loop can reach.
final class SpeechStartLoopTests: XCTestCase {
    private struct Glitch: LocalizedError {
        var errorDescription: String? { "engine glitch" }
    }

    /// What the loop did, in order, and what it was told.
    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private var _steps: [String] = []
        private var _within: [TimeInterval] = []
        private var _said: [SpeechState] = []
        var stopped = false
        /// Each call to the start throws the next of these, then succeeds.
        var script: [Error?] = []
        var steps: [String] { lock.withLock { _steps } }
        var within: [TimeInterval] { lock.withLock { _within } }
        var said: [SpeechState] { lock.withLock { _said } }
        func note(_ step: String) { lock.withLock { _steps.append(step) } }
        func count(_ step: String) -> Int { steps.filter { $0 == step }.count }

        static let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

        func start(_ seconds: TimeInterval) throws -> SpeechStart.Started {
            lock.withLock { _steps.append("start"); _within.append(seconds) }
            let next = lock.withLock { script.isEmpty ? nil : script.removeFirst() }
            if let error = next ?? nil { throw error }
            return (Self.format, "Stage Headset")
        }
        func say(_ state: SpeechState) { lock.withLock { _said.append(state) } }
    }

    /// The draft's log lines while a loop runs.
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [String] = []
        var all: [String] { lock.withLock { _all } }
        func add(_ line: String) { lock.withLock { _all.append(line) } }
    }
    private let lines = Lines()

    override func setUp() {
        super.setUp()
        Log.listener = { [lines] in lines.add($0) }
    }
    override func tearDown() {
        Log.listener = nil
        super.tearDown()
    }

    private func speech(_ lines: [String]) -> [String] { lines.filter { $0.contains(" draft speech=") } }

    private func loop(_ run: Run, began: Date = Date()) async -> SpeechStart.Outcome {
        await SpeechStart.startLoop(
            began: began,
            start: { try run.start($0) },
            bridgeAgain: { run.note("bridgeAgain") },
            stopped: { run.stopped },
            stopOwnBridge: { run.note("stopOwnBridge") },
            say: { run.say($0) })
    }

    /// The loop run to its end on a clock the test owns: the settle between
    /// two attempts is waited out in virtual time, so a test of a second
    /// attempt takes no real 650 ms.
    private func loopThroughTheSettle(_ run: Run, began: Date = Date()) async -> SpeechStart.Outcome {
        let clock = TestClock()
        return await withTestAmbient(clock: clock) {
            let waiting = Task { await self.loop(run, began: began) }
            await clock.waitForSleepers()
            await clock.advance(by: .seconds(SpeechStart.settleSeconds))
            return await waiting.value
        }
    }

    private func assertStarted(_ outcome: SpeechStart.Outcome, file: StaticString = #filePath, line: UInt = #line) {
        guard case .started(let started) = outcome else { return XCTFail("\(outcome)", file: file, line: line) }
        XCTAssertEqual(started.name, "Stage Headset", file: file, line: line)
    }
    private func assertUnstarted(_ outcome: SpeechStart.Outcome, wedged: Bool,
                                 file: StaticString = #filePath, line: UInt = #line) {
        guard case .unstarted(let refused) = outcome else { return XCTFail("\(outcome)", file: file, line: line) }
        XCTAssertEqual(refused, wedged, file: file, line: line)
    }
    private func assertEnded(_ outcome: SpeechStart.Outcome, file: StaticString = #filePath, line: UInt = #line) {
        guard case .ended = outcome else { return XCTFail("\(outcome)", file: file, line: line) }
    }

    // MARK: - A start that lands

    /// The first attempt is given the whole budget, so a slow start is
    /// waited for rather than abandoned at the first deadline.
    func testAStartThatLandsIsOneAttemptWithTheWholeBudget() async {
        let run = Run()
        assertStarted(await loop(run))
        XCTAssertEqual(run.steps, ["start"], "no re-arm, no pause, no bridge stopped")
        XCTAssertEqual(run.within.count, 1)
        XCTAssertEqual(run.within[0], SpeechStart.startBudget, accuracy: 0.5)
        XCTAssertEqual(run.said, [], "listening is said by the caller, not the loop")
        XCTAssertEqual(speech(lines.all), [], "a start that lands logs nothing here")
    }

    // MARK: - Ends the session

    /// The caller went away (the draft closed during the start): the
    /// session ends, its bridge is stopped, nothing is said, no second try.
    func testACancelledStartEndsTheSessionSilently() async {
        let run = Run()
        run.script = [CancellationError()]
        assertEnded(await loop(run))
        XCTAssertEqual(run.steps, ["start", "stopOwnBridge"])
        XCTAssertEqual(run.said, [])
        XCTAssertEqual(speech(lines.all), [])
    }

    /// A newer session has the microphone and this draft is gone.
    func testASupersededStartEndsTheSessionSilently() async {
        let run = Run()
        run.script = [AudioInput.Superseded()]
        assertEnded(await loop(run))
        XCTAssertEqual(run.steps, ["start", "stopOwnBridge"])
        XCTAssertEqual(run.said, [])
        XCTAssertEqual(speech(lines.all), [])
    }

    /// An input that is off is not a start that failed: it says why, once,
    /// and does not try again.
    func testAnInputThatIsOffSaysWhyAndIsNotTriedAgain() async {
        let run = Run()
        run.script = [AudioInput.InputOff(why: "no microphone is connected")]
        assertEnded(await loop(run))
        XCTAssertEqual(run.steps, ["start", "stopOwnBridge"])
        XCTAssertEqual(run.said, [.failed("no microphone is connected")])
        XCTAssertEqual(speech(lines.all), [], "the caller's say() logs the state, not the loop")
    }

    // MARK: - Ends the loop

    /// Every slot of the audio start holds one that never came back:
    /// another would be refused the same way. The loop ends, saying
    /// nothing itself, and reports the wedge for the session to say.
    func testAWedgeEndsTheLoopAndIsReported() async {
        let run = Run()
        run.script = [SpeechStart.Wedged(label: "speech.start")]
        assertUnstarted(await loop(run), wedged: true)
        XCTAssertEqual(run.steps, ["start"], "no second attempt, no re-arm, the bridge is left as it stands")
        XCTAssertEqual(run.said, [])
        let said = speech(lines.all)
        XCTAssertEqual(said.count, 1, "\(said)")
        XCTAssertTrue(said[0].contains("ERR  draft speech=\"audio start is wedged\" label=speech.start attempt=1"), "\(said)")
    }

    /// The start is still out on the engine's queue: another would queue
    /// behind it and stop whatever it started. The budget is spent.
    func testAStartStillOutOnTheQueueEndsTheLoopWithoutAnotherAttempt() async {
        let run = Run()
        run.script = [SpeechStart.TimedOut()]
        assertUnstarted(await loop(run), wedged: false)
        XCTAssertEqual(run.steps, ["start"], "no second attempt, no re-arm, and the start is not stopped here")
        XCTAssertEqual(run.said, [])
        let said = speech(lines.all)
        XCTAssertEqual(said.count, 1, "\(said)")
        XCTAssertTrue(said[0].contains("INFO draft speech=\"audio start timed out\" attempt=1 seconds=0"), "\(said)")
    }

    // MARK: - Tried again

    /// Any other failure is tried again once: the bridge is armed again
    /// first, the radio has its settle, and the second attempt is given what
    /// is left of the budget.
    func testAnyOtherFailureIsTriedAgainAfterTheBridgeIsArmed() async {
        let run = Run()
        run.script = [Glitch()]
        let began = Date()
        assertStarted(await loop(run, began: began))
        XCTAssertEqual(run.steps, ["start", "bridgeAgain", "start"])
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(began), SpeechStart.settleSeconds - 0.05,
                                    "the settle was waited out between them")
        XCTAssertEqual(run.within.count, 2)
        XCTAssertEqual(run.within[1], SpeechStart.startBudget - SpeechStart.settleSeconds, accuracy: 0.5,
                       "what is left of the budget, not a fresh one")
        XCTAssertLessThan(run.within[1], run.within[0])
        XCTAssertEqual(run.said, [])
        let said = speech(lines.all)
        XCTAssertEqual(said.count, 1, "\(said)")
        XCTAssertTrue(said[0].contains("INFO draft speech=\"audio start failed\" attempt=1 error=Glitch()"), "\(said)")
    }

    /// The settle is waited on Stoic's clock, so a test moves it: no second
    /// attempt begins until the whole settle has passed, and the bridge is
    /// armed before it, not after.
    func testTheSettleIsWaitedOnStoicsClock() async {
        let clock = TestClock()
        let run = Run()
        run.script = [Glitch()]
        await withTestAmbient(clock: clock) {
            let waiting = Task { await self.loop(run) }
            await clock.waitForSleepers()
            XCTAssertEqual(run.steps, ["start", "bridgeAgain"], "armed, and settling")
            await clock.advance(by: .seconds(SpeechStart.settleSeconds - 0.01))
            XCTAssertEqual(run.count("start"), 1, "the radio has not had its settle yet")
            XCTAssertEqual(clock.sleeperCount, 1)
            await clock.advance(by: .seconds(0.01))
            self.assertStarted(await waiting.value)
            XCTAssertEqual(run.steps, ["start", "bridgeAgain", "start"])
            XCTAssertEqual(clock.sleeperCount, 0, "nothing is left waiting")
        }
    }

    /// Two failures are the end: the bridge was armed once, before the
    /// second attempt, and not after the last; the session says nothing
    /// itself and reports an ordinary failure, not a wedge.
    func testTwoFailuresAreTheEndAndAreNotAWedge() async {
        let run = Run()
        run.script = [Glitch(), Glitch()]
        assertUnstarted(await loopThroughTheSettle(run), wedged: false)
        XCTAssertEqual(run.steps, ["start", "bridgeAgain", "start"])
        XCTAssertEqual(run.said, [])
        let said = speech(lines.all)
        XCTAssertEqual(said.count, 2, "\(said)")
        XCTAssertTrue(said[0].contains("attempt=1"), "\(said)")
        XCTAssertTrue(said[1].contains("attempt=2"), "\(said)")
    }

    /// The attempt number the log says is the loop's own count.
    func testALaterAttemptSaysWhichAttemptItWas() async {
        let run = Run()
        run.script = [Glitch(), SpeechStart.TimedOut()]
        assertUnstarted(await loopThroughTheSettle(run), wedged: false)
        XCTAssertEqual(run.steps, ["start", "bridgeAgain", "start"])
        let said = speech(lines.all)
        XCTAssertEqual(said.count, 2, "\(said)")
        XCTAssertTrue(said[1].contains("audio start timed out") && said[1].contains("attempt=2"), "\(said)")
    }

    func testAWedgeOnTheSecondAttemptIsAWedge() async {
        let run = Run()
        run.script = [Glitch(), SpeechStart.Wedged(label: "speech.start")]
        assertUnstarted(await loopThroughTheSettle(run), wedged: true)
        XCTAssertEqual(run.steps, ["start", "bridgeAgain", "start"])
    }

    /// The caller going away on the second attempt is the same silent end.
    func testACancelOnTheSecondAttemptEndsTheSessionSilently() async {
        let run = Run()
        run.script = [Glitch(), CancellationError()]
        assertEnded(await loopThroughTheSettle(run))
        XCTAssertEqual(run.steps, ["start", "bridgeAgain", "start", "stopOwnBridge"])
        XCTAssertEqual(run.said, [])
    }

    // MARK: - Between the attempts

    /// The session stopped while the radio settled: no second attempt, and
    /// the session's bridge is stopped. The bridge had been armed first.
    func testASessionStoppedDuringTheSettleIsNotStartedAgain() async {
        let run = Run()
        run.script = [Glitch()]
        let clock = TestClock()
        let outcome = await withTestAmbient(clock: clock) {
            let waiting = Task {
                await SpeechStart.startLoop(
                    began: Date(),
                    start: { try run.start($0) },
                    bridgeAgain: { run.note("bridgeAgain"); run.stopped = true },
                    stopped: { run.stopped },
                    stopOwnBridge: { run.note("stopOwnBridge") },
                    say: { run.say($0) })
            }
            await clock.waitForSleepers()
            await clock.advance(by: .seconds(SpeechStart.settleSeconds))
            return await waiting.value
        }
        assertEnded(outcome)
        XCTAssertEqual(run.steps, ["start", "bridgeAgain", "stopOwnBridge"], "no second start")
        XCTAssertEqual(run.said, [])
    }

    /// The budget is checked again after the settle: a second attempt that
    /// cannot cover a start is not begun (it was begun with 0.9 s of 5.65
    /// and abandoned at the deadline, four times of four). The bridge was
    /// armed before the check.
    func testASecondAttemptTheBudgetCannotPayIsNotBegun() async {
        let run = Run()
        run.script = [Glitch()]
        let began = Date().addingTimeInterval(-(SpeechStart.startBudget - 0.9))
        assertUnstarted(await loop(run, began: began), wedged: false)
        XCTAssertEqual(run.steps, ["start", "bridgeAgain"], "the second attempt is not begun")
        XCTAssertEqual(run.within.count, 1)
        XCTAssertEqual(run.within[0], 0.9, accuracy: 0.2)
    }

    /// A budget already spent begins nothing, and says nothing.
    func testASpentBudgetBeginsNothing() async {
        let run = Run()
        assertUnstarted(await loop(run, began: Date().addingTimeInterval(-SpeechStart.startBudget)), wedged: false)
        XCTAssertEqual(run.steps, [])
        XCTAssertEqual(run.said, [])
        XCTAssertEqual(speech(lines.all), [])
    }

    /// The least a start can be given and still begin.
    func testTheLeastAStartIsGivenStillBegins() async {
        let run = Run()
        let began = Date().addingTimeInterval(-(SpeechStart.startBudget - SpeechStart.minimumStart - 0.2))
        assertStarted(await loop(run, began: began))
        XCTAssertEqual(run.steps, ["start"])
        XCTAssertGreaterThan(run.within[0], SpeechStart.minimumStart)
    }
}
