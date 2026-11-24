import AVFoundation
import XCTest
@testable import lodestar

/// The process's one `AudioInput`, driven the way two drafts in a row drive
/// it. The engine is a script: no device is read and no microphone opens.
final class AudioInputStopTests: XCTestCase {
    /// The script's engine: when it runs, and what stopped it.
    private final class Engine: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [String] = []
        private var _running = false
        private var starts = 0
        private var _stopsRun = 0
        let slowStart = DispatchSemaphore(value: 0)
        var events: [String] { lock.withLock { _events } }
        var running: Bool { lock.withLock { _running } }
        /// Every time the input ran its stop, whether or not an engine was running.
        var stopsRun: Int { lock.withLock { _stopsRun } }

        /// The first start is a Bluetooth headset's, slow; later ones are quick.
        func start() -> (format: AVAudioFormat, name: String?) {
            let number = lock.withLock { () -> Int in starts += 1; return starts }
            if number == 1 { slowStart.wait() }
            lock.withLock {
                _running = true
                _events.append("start \(number)")
            }
            return (AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!, "script")
        }

        func stopped() {
            lock.withLock {
                _stopsRun += 1
                guard _running else { return }
                _running = false
                _events.append("stop")
            }
        }
    }

    private func input(_ engine: Engine) -> AudioInput {
        let input = AudioInput()
        input.stand = AudioInput.Stand(start: { _ in engine.start() }, stopped: { engine.stopped() })
        return input
    }

    private func start(_ input: AudioInput, ticket: Int,
                       completion: @escaping (Result<(format: AVAudioFormat, name: String?), Error>) -> Void = { _ in }) {
        input.start(device: nil, ticket: ticket, sink: { _ in }, completion: completion)
    }

    /// Draft A asked for the headset, and the start is slow. Esc closes the
    /// draft and `lode .` opens the next: both stop first, and the next
    /// one's start queues behind A's. A's start returns, A finds it was
    /// stopped, and says stop once more, which lands after the next
    /// draft's start. That stop was meant for A's engine, and the engine is
    /// the next draft's now.
    func testAStopFromADraftThatWasReplacedDoesNotStopTheNextDraftsEngine() {
        let engine = Engine()
        let input = input(engine)
        let a = input.reserveTicket()
        let aReturned = DispatchSemaphore(value: 0)
        start(input, ticket: a) { _ in aReturned.signal() }                                    // draft A
        input.stop()                                                                           // esc
        input.stop()                                                                           // lode ., the next listen
        let b = input.reserveTicket()
        let bStarted = DispatchSemaphore(value: 0)
        start(input, ticket: b) { _ in bStarted.signal() }                                     // draft B
        engine.slowStart.signal()                                                              // A's start returns
        XCTAssertEqual(aReturned.wait(timeout: .now() + 5), .success)
        // A's listen resumes, sees `stopped`, and lets go of the microphone
        // (SpeechSession.swift, `guard !stopped else { microphone.stop(ticket: micTicket); return }`).
        input.stop(ticket: a)
        XCTAssertEqual(bStarted.wait(timeout: .now() + 5), .success)
        input.drain()
        XCTAssertTrue(engine.running,
                      "draft B's engine runs: \(engine.events), and a stop that was A's cannot touch it")
    }

    /// The stop A's start timing out says (`.nothing`) is the same stop, and
    /// is ignored the same way; and it does not charge the engine's keeper
    /// or take the session out of flight, so B's silence watch still runs.
    func testAnIgnoredStopLeavesTheCurrentSessionInFlightAndChargesNothing() {
        let engine = Engine()
        let input = input(engine)
        let a = input.reserveTicket()
        start(input, ticket: a)
        input.stop()
        input.stop()
        let b = input.reserveTicket()
        let bStarted = DispatchSemaphore(value: 0)
        start(input, ticket: b) { _ in bStarted.signal() }
        engine.slowStart.signal()
        XCTAssertEqual(bStarted.wait(timeout: .now() + 5), .success)
        input.drain()
        XCTAssertTrue(input.sessionInFlight, "B is in flight")
        let stops = engine.stopsRun
        input.stop(ticket: a)
        input.drain()
        XCTAssertEqual(engine.stopsRun, stops, "an ignored stop never reaches stopNow, where the keeper is charged")
        XCTAssertTrue(input.sessionInFlight, "and B stays in flight, which is what its silence watch looks for")
        XCTAssertTrue(engine.running)
    }

    /// A's start loop tries twice. The second attempt comes after B's start
    /// was asked for, and would stop B's engine on its way to starting: it
    /// is refused, and touches nothing.
    func testAnOlderSessionsSecondStartAfterANewerOneTouchesNothing() {
        let engine = Engine()
        let input = input(engine)
        let a = input.reserveTicket()
        start(input, ticket: a)
        input.stop()
        input.stop()
        let b = input.reserveTicket()
        let bStarted = DispatchSemaphore(value: 0)
        start(input, ticket: b) { _ in bStarted.signal() }
        let retry = DispatchSemaphore(value: 0)
        var refused: Error?
        start(input, ticket: a) { result in                                                    // A's second attempt
            if case .failure(let error) = result { refused = error }
            retry.signal()
        }
        engine.slowStart.signal()
        XCTAssertEqual(bStarted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(retry.wait(timeout: .now() + 5), .success)
        input.drain()
        XCTAssertTrue(refused is AudioInput.Superseded, "refused: \(String(describing: refused))")
        XCTAssertTrue(engine.running, "B's engine runs: \(engine.events)")
        XCTAssertEqual(engine.events.filter { $0.hasPrefix("start") }, ["start 1", "start 2"], "no third start")
        XCTAssertTrue(input.sessionInFlight)
    }

    /// A session's retry, with nothing newer, is its own business.
    func testASessionsOwnSecondStartRuns() {
        let engine = Engine()
        let input = input(engine)
        let a = input.reserveTicket()
        let first = DispatchSemaphore(value: 0)
        start(input, ticket: a) { _ in first.signal() }
        engine.slowStart.signal()
        XCTAssertEqual(first.wait(timeout: .now() + 5), .success)
        let second = DispatchSemaphore(value: 0)
        var result: Result<(format: AVAudioFormat, name: String?), Error>?
        start(input, ticket: a) { result = $0; second.signal() }
        XCTAssertEqual(second.wait(timeout: .now() + 5), .success)
        guard case .success? = result else { return XCTFail("the retry ran: \(String(describing: result))") }
        XCTAssertTrue(engine.running)
    }

    /// The same stop, with nothing replacing the draft, is the stop it
    /// always was: the engine goes quiet.
    func testAStopFromTheCurrentDraftStopsItsEngine() {
        let engine = Engine()
        let input = input(engine)
        let a = input.reserveTicket()
        let started = DispatchSemaphore(value: 0)
        start(input, ticket: a) { _ in started.signal() }
        engine.slowStart.signal()
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        input.stop(ticket: a)
        input.drain()
        XCTAssertFalse(engine.running)
        XCTAssertEqual(engine.events, ["start 1", "stop"])
    }

    /// The session's own unscoped stop (`listen` and `stop` on the session)
    /// stops whatever runs.
    func testTheSessionsUnscopedStopStopsWhateverRuns() {
        let engine = Engine()
        let input = input(engine)
        let started = DispatchSemaphore(value: 0)
        start(input, ticket: input.reserveTicket()) { _ in started.signal() }
        engine.slowStart.signal()
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        input.stop()
        input.drain()
        XCTAssertFalse(engine.running)
    }

    /// A stop from a session that is no longer the newest does not disturb
    /// a wait on the current one (the settle after a refused radio start
    /// watches the tick), but a stop that is current's own does.
    func testAStaleStopDoesNotSupersedeTheCurrentSessionsWaits() {
        let engine = Engine()
        let input = input(engine)
        let a = input.reserveTicket()
        let b = input.reserveTicket()
        start(input, ticket: b)
        engine.slowStart.signal()
        input.drain()
        let before = input.tickForTests
        input.stop(ticket: a)
        XCTAssertEqual(input.tickForTests, before)
        input.stop(ticket: b)
        XCTAssertNotEqual(input.tickForTests, before)
    }
}
