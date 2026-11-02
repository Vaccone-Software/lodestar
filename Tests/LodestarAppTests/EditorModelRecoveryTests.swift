import LodestarCore
import Stoic
import StoicTesting
import XCTest
@testable import lodestar

/// The editor's model, asked under the process's one MLX lane: a question's
/// deadline bounds the answer and not the line it stood in, a generation
/// that overruns is cancelled and lets the lane go, a model that stopped
/// answering recovers on its own, and a load that hangs gives up. The
/// clock is virtual and the lane is the test's own, so nothing here waits
/// in real time or on another test.
final class EditorModelRecoveryTests: XCTestCase {
    /// Counts what the model was asked, and how the answers behave.
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var _started = 0
        private var _cancelled = 0
        private var _inside = 0
        private(set) var mostInside = 0
        private var parked: [CheckedContinuation<Void, Never>] = []
        var started: Int { lock.withLock { _started } }
        var cancelled: Int { lock.withLock { _cancelled } }
        func begin() {
            lock.withLock {
                _started += 1
                _inside += 1
                mostInside = max(mostInside, _inside)
            }
        }
        func end() { lock.withLock { _inside -= 1 } }
        func sawCancel() { lock.withLock { _cancelled += 1 } }
        /// Waits and never looks at its cancellation, like a generation
        /// stuck in an evaluation.
        func park() async {
            await withCheckedContinuation { continuation in lock.withLock { parked.append(continuation) } }
        }
        func unpark() {
            let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                defer { parked = [] }
                return parked
            }
            for continuation in all { continuation.resume() }
        }
    }

    /// How a question is answered: promptly, by waiting for its
    /// cancellation, or stuck for good.
    private enum Mood: Sendable { case prompt, cooperative, stubborn }

    private struct Fake: EditorBackend {
        let probe: Probe
        let mood: Mood
        func respond(to sentence: String, instructions: String) async throws -> String {
            probe.begin()
            defer { probe.end() }
            switch mood {
            case .prompt:
                await Task.yield()
            case .cooperative:
                do { try await Task.sleep(for: .seconds(3600)) } catch {
                    probe.sawCancel()
                    throw error
                }
            case .stubborn:
                await probe.park()
            }
            return sentence.replacingOccurrences(of: "Their", with: "They're")
        }
        func rewrite(_ text: String, prompt: IntentPass.Prompt) async throws -> String {
            probe.begin()
            defer { probe.end() }
            try await Task.sleep(for: .milliseconds(30))
            return text
        }
    }

    private func model(gate: MLXGate, probe: Probe, moods: [Mood] = [.prompt], loads: LoadCount? = nil,
                       loader: EditorModel.Loader? = nil) -> EditorModel {
        EditorModel(engine: .standard, idleRelease: 3600, answerDeadline: 8, gateWait: 3, loadDeadline: 60,
                    stuckAfter: 20, gate: gate,
                    loader: loader ?? { _ in
                        let number = loads?.next() ?? 0
                        return Fake(probe: probe, mood: moods[min(number, moods.count - 1)])
                    },
                    clearCache: {})
    }

    private final class LoadCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { defer { count += 1 }; return count } }
        var total: Int { lock.withLock { count } }
    }

    /// Waits, in real time and briefly, for something an unstructured task
    /// does after the virtual clock moved.
    private func eventually(_ what: String, _ condition: @Sendable () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("never: \(what)")
    }

    /// The one timer a test is about to move the clock past.
    private func oneSleeper(_ clock: TestClock) async {
        await eventually("one timer sleeps", { clock.sleeperCount == 1 })
    }

    // MARK: - The deadline bounds the answer, not the line

    func testAQuestionStuckInTheQueueIsNilWithinTheBoundAndNeverAbandoned() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let gate = MLXGate()
            let probe = Probe()
            let model = model(gate: gate, probe: probe)
            await model.prepare()
            let lane = await gate.acquire()!          // the ear is mid-phrase
            let asking = Task { await model.correct("Their going.") }
            await eventually("the question queues", { gate.waiting == 1 })
            await oneSleeper(clock)
            await clock.advance(by: .seconds(3.5))
            let answer = await asking.value
            XCTAssertNil(answer, "it could not start within the bound")
            XCTAssertEqual(probe.started, 0, "and it never ran")
            XCTAssertTrue(AbandonedWork.current.isEmpty, "a question that never started is not an abandoned generation")
            XCTAssertEqual(gate.waiting, 0)
            XCTAssertEqual(model.ability, .able, "a busy GPU is not a broken model")
            gate.release(lane)
            let again = await model.correct("Their going.")
            XCTAssertEqual(again, "They're going.")
        }
    }

    func testAQuestionWaitsForAnotherUserOfTheLaneAndThenRuns() async {
        let gate = MLXGate()
        let probe = Probe()
        let model = model(gate: gate, probe: probe)
        await model.prepare()
        let lane = await gate.acquire()!
        let asking = Task { await model.correct("Their going.") }
        await eventually("the question queues", { gate.waiting == 1 })
        XCTAssertEqual(probe.started, 0, "the model does not evaluate while another holds the lane")
        gate.release(lane)
        let answer = await asking.value
        XCTAssertEqual(answer, "They're going.")
    }

    func testTheSentenceCheckAndTheIntentPassNeverEvaluateTogether() async {
        let gate = MLXGate()
        let probe = Probe()
        let model = model(gate: gate, probe: probe)
        await model.prepare()
        let prompt = IntentPass.Prompt(instructions: "x", examples: [])
        async let a = model.correct("Their going.")
        async let b = model.rewrite("hello", prompt: prompt)
        async let c = model.correct("Their here.")
        let results = await (a, b, c)
        XCTAssertEqual(results.0, "They're going.")
        XCTAssertEqual(results.1, "hello")
        XCTAssertEqual(results.2, "They're here.")
        XCTAssertEqual(probe.mostInside, 1, "one evaluation at a time")
    }

    // MARK: - An overrun is cancelled and lets go

    func testAGenerationThatOverrunsIsCancelledAndTheLaneGoesOn() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let gate = MLXGate()
            let probe = Probe()
            let loads = LoadCount()
            let model = model(gate: gate, probe: probe, moods: [.cooperative], loads: loads)
            let asking = Task { await model.correct("Their going.") }
            await eventually("the generation begins", { probe.started == 1 })
            await oneSleeper(clock)
            await clock.advance(by: .seconds(9))
            let answer = await asking.value
            XCTAssertNil(answer, "eight seconds on the model's own clock")
            await eventually("the generation sees its cancellation", { probe.cancelled == 1 })
            await eventually("the lane is free", { !gate.isHeld })
            XCTAssertEqual(model.ability, .unable, "a generation that never came back is said")
            XCTAssertTrue(AbandonedWork.current.filter { $0.label.hasPrefix("editor.model") }.isEmpty,
                          "nothing is left outstanding")
            XCTAssertEqual(loads.total, 1, "the same backend serves the next question")
        }
    }

    func testTheDeadlineStartsOnlyOnceTheModelHoldsTheLane() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let gate = MLXGate()
            let probe = Probe()
            let model = model(gate: gate, probe: probe)
            await model.prepare()
            let lane = await gate.acquire()!
            let asking = Task { await model.correct("Their going.") }
            await eventually("the question queues", { gate.waiting == 1 })
            await oneSleeper(clock)
            await clock.advance(by: .seconds(2))      // two of its three seconds in line
            gate.release(lane)
            let answer = await asking.value
            XCTAssertEqual(answer, "They're going.", "the two seconds in line did not come off the eight")
        }
    }

    // MARK: - A wedge heals

    func testAModelThatStoppedAnsweringRecoversWithAFreshBackend() async {
        let clock = TestClock()
        let lines = LogLines()
        Log.listener = { lines.add($0) }
        defer { Log.listener = nil }
        await withTestAmbient(clock: clock) {
            let gate = MLXGate()
            let probe = Probe()
            let loads = LoadCount()
            // The first backend's generation is stuck for good; the second
            // is well.
            let model = model(gate: gate, probe: probe, moods: [.stubborn, .prompt], loads: loads)
            let first = Task { await model.correct("Their stuck.") }
            await eventually("the generation begins", { probe.started == 1 })
            await oneSleeper(clock)
            await clock.advance(by: .seconds(9))
            let a = await first.value
            XCTAssertNil(a)
            XCTAssertTrue(gate.isHeld, "the stuck generation still holds the lane: it cannot be cancelled")

            // Behind it, a question is turned away quickly, not counted.
            let second = Task { await model.correct("Their busy.") }
            await eventually("it queues", { gate.waiting == 1 })
            await oneSleeper(clock)
            await clock.advance(by: .seconds(4))
            let b = await second.value
            XCTAssertNil(b)
            XCTAssertEqual(loads.total, 1, "not yet given up on: twenty seconds have not passed")

            // Twenty seconds after it was abandoned, the next sentence
            // finds the model lost and loads another.
            await clock.advance(by: .seconds(20))
            let c = await model.correct("Their back.")
            XCTAssertEqual(c, "They're back.", "a fresh backend answers")
            XCTAssertEqual(loads.total, 2)
            XCTAssertEqual(model.ability, .able)
            XCTAssertFalse(gate.isHeld)
            let recovered = lines.all.filter { $0.contains("recovered") }
            XCTAssertEqual(recovered.count, 1, "said once")
            XCTAssertFalse(lines.all.contains { $0.contains("stuck") || $0.contains("Their") }, "no text in the log")
            probe.unpark()
        }
    }

    private final class LogLines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    func testARecoveredLabelIsNotRefusedForWhatTheLastBackendLeftOutstanding() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let gate = MLXGate()
            let calls = ModelCalls(name: "unit", gate: gate, stuckAfter: 20)
            let probe = Probe()
            let before = calls.label
            let asked = Task {
                await calls.ask(deadline: 8, wait: 3) { () -> String? in
                    await probe.park()
                    return "late"
                }
            }
            await oneSleeper(clock)
            await clock.advance(by: .seconds(9))
            guard case .unanswered = await asked.value else { return XCTFail("it was given up on") }
            XCTAssertEqual(calls.recoverIfStuck(), 0, "not yet")
            await clock.advance(by: .seconds(21))
            XCTAssertEqual(calls.recoverIfStuck(), 1)
            XCTAssertNotEqual(calls.label, before, "the next backend counts on a label of its own")
            XCTAssertFalse(gate.isHeld, "the lane was taken back")
            let fresh = await calls.ask(deadline: 8, wait: 3) { "fine" }
            XCTAssertEqual(fresh.value, "fine")
            probe.unpark()
        }
    }

    // MARK: - Loads

    func testALoadThatHangsGivesUpAndCallersAreNotLeftWaiting() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let gate = MLXGate()
            let probe = Probe()
            let model = model(gate: gate, probe: probe, loader: { _ in
                await probe.park()
                return Fake(probe: probe, mood: .prompt)
            })
            let early = Task { await model.prepare() }
            let asking = Task { await model.correct("Their going.") }
            await eventually("the load begins", { gate.isHeld })
            await oneSleeper(clock)
            await clock.advance(by: .seconds(61))
            let answer = await asking.value
            await early.value
            XCTAssertNil(answer, "no model, no answer, and no hang")
            let state = await model.state
            guard case .failed = state else { return XCTFail("a load that timed out is a failed one, not \(state)") }
            XCTAssertEqual(model.ability, .unable)
            probe.unpark()
        }
    }

    func testALoadThatFailsReturnsNilAndSaysUnable() async {
        let gate = MLXGate()
        let probe = Probe()
        let model = model(gate: gate, probe: probe, loader: { engine in throw EditorModelError.missing(engine) })
        let answer = await model.correct("Their going.")
        XCTAssertNil(answer)
        XCTAssertEqual(model.ability, .unable)
        XCTAssertFalse(gate.isHeld, "a failed load gives the lane back")
    }

    func testALoadWaitsForTheLaneLikeAnyOtherEvaluation() async {
        let gate = MLXGate()
        let probe = Probe()
        let loads = LoadCount()
        let model = model(gate: gate, probe: probe, loads: loads)
        let lane = await gate.acquire()!
        let preparing = Task { await model.prepare() }
        await eventually("the load queues", { gate.waiting == 1 })
        XCTAssertEqual(loads.total, 0, "the weights do not load while the ear works")
        gate.release(lane)
        await preparing.value
        XCTAssertEqual(loads.total, 1)
    }

    // MARK: - The draft's own copy

    func testTheDraftsModelAlsoTakesTheLaneAndTurnsAwayAQuestionItCannotStart() async {
        let clock = TestClock()
        await withTestAmbient(clock: clock) {
            let gate = MLXGate()
            let probe = Probe()
            let draft = DraftModel(model: .gemma, gate: gate, loader: { _ in Fake(probe: probe, mood: .prompt) },
                                   clearCache: {})
            await draft.load()
            let lane = await gate.acquire()!
            let prompt = IntentPass.Prompt(instructions: "x", examples: [])
            let asking = Task { await draft.rewrite("hello", prompt: prompt) }
            await eventually("it queues", { gate.waiting == 1 })
            await oneSleeper(clock)
            await clock.advance(by: .seconds(4))
            let answer = await asking.value
            XCTAssertNil(answer)
            XCTAssertEqual(probe.started, 0)
            gate.release(lane)
            let later = await draft.rewrite("hello", prompt: prompt)
            XCTAssertEqual(later, "hello")
        }
    }

    // MARK: - Clearing MLX's cache takes the lane too

    /// What happened, in order, with whether the lane was held at the time.
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    func testLettingGoOfTheModelClearsMLXsCacheHoldingTheLane() async {
        let gate = MLXGate()
        let probe = Probe()
        let events = Events()
        let model = EditorModel(engine: .standard, idleRelease: 3600, gate: gate,
                                loader: { _ in Fake(probe: probe, mood: .prompt) },
                                clearCache: { events.add(gate.isHeld ? "clear held" : "clear free") })
        await model.prepare()
        await model.release(reason: "test")
        await eventually("the cache is cleared", { events.all.count == 1 })
        XCTAssertEqual(events.all, ["clear held"], "the clear waited its turn on the lane like any evaluation")
        XCTAssertFalse(gate.isHeld)
    }

    func testTheClearWaitsForTheLaneAndNeverFollowsTheNextLoad() async {
        let gate = MLXGate()
        let probe = Probe()
        let events = Events()
        let model = EditorModel(engine: .standard, idleRelease: 3600, gate: gate,
                                loader: { _ in events.add("load"); return Fake(probe: probe, mood: .prompt) },
                                clearCache: { events.add("clear") })
        await model.prepare()
        let lane = await gate.acquire()!              // the ear is mid-phrase
        await model.release(reason: "test")
        let loading = Task { await model.prepare() }  // typing resumes at once
        await eventually("the load queues", { gate.waiting >= 1 })
        XCTAssertEqual(events.all, ["load"], "neither the clear nor the second load ran under the ear")
        gate.release(lane)
        await loading.value
        await eventually("the lane is idle", { !gate.isHeld && gate.waiting == 0 })
        XCTAssertEqual(events.all, ["load", "clear", "load"], "cleared once, before the next backend loaded")
    }

    func testTheDraftsModelClearsItsCacheHoldingTheLaneToo() async {
        let gate = MLXGate()
        let probe = Probe()
        let events = Events()
        let draft = DraftModel(model: .gemma, gate: gate, loader: { _ in Fake(probe: probe, mood: .prompt) },
                               clearCache: { events.add(gate.isHeld ? "clear held" : "clear free") })
        await draft.load()
        await draft.release()
        await eventually("the cache is cleared", { events.all.count == 1 })
        XCTAssertEqual(events.all, ["clear held"])
    }
}
