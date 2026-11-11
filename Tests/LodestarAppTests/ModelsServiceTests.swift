import Foundation
import Stoic
import StoicTesting
import StoicXPC
import XCTest
@testable import lodestar
@testable import LodestarCore
@testable import LodestarEars

/// The models run in an XPC service. Here the service's own object
/// (`ModelsService`) runs on a real `XPCHost` with a fake engine, behind
/// StoicXPC's simulated service, and the app's client (`ModelsClient`, on a
/// real `XPCPeer`) talks to it on a virtual clock: no MLX, no GPU and no
/// sleeping, but every request crosses the wire's encoding, with its
/// handshake, its cancels, its crashes and its idle exit.
///
/// What the library decides is tested in Stoic (design/25's failure-mode
/// table: a lost run, an ended one, the retry by repeat safety, the stuck
/// verdict, the watchdog, the idle exit, the build handshake). What is
/// tested here is what Lodestar says to the library and what it makes of
/// its answers: each method's declaration, the failures the editor and
/// dictation see, what the app loads again when a run is lost, and what the
/// service holds against its idle exit. Only the launch by name, and MLX
/// finding its kernels in the service's bundle, are left to the signed app's
/// self-test (`SelfTest.modelsService`).
final class ModelsServiceTests: XCTestCase {
    // MARK: - The fake engine

    /// How a question is answered.
    enum Mood: Sendable {
        case prompt
        /// Waits until cancelled, as a generation does at its next token.
        case cooperative
        /// Never stops, cancelled or not: an evaluation stuck in MLX.
        case stubborn
        /// The service's process ends while it answers, as a crash would.
        case ending
    }

    final class Gauge: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        private var parked: [CheckedContinuation<Void, Never>] = []
        var specs: [LanguageModelSpec] = []
        var heard: [([Float], [String])] = []
        /// What `.ending` does: the test crashes the service's process.
        var end: @Sendable () -> Void = {}

        func note(_ what: String) { lock.withLock { counts[what, default: 0] += 1 } }
        func count(_ what: String) -> Int { lock.withLock { counts[what] ?? 0 } }
        func remember(_ spec: LanguageModelSpec) { lock.withLock { specs.append(spec) } }
        func remember(_ samples: [Float], _ context: [String]) { lock.withLock { heard.append((samples, context)) } }
        func park() async {
            await withCheckedContinuation { continuation in lock.withLock { parked.append(continuation) } }
        }
        var parkedCount: Int { lock.withLock { parked.count } }
        func unpark() {
            let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                defer { parked = [] }
                return parked
            }
            all.forEach { $0.resume() }
        }
    }

    struct FakeModel: ServedLanguageModel {
        let gauge: Gauge
        let mood: Mood
        func respond(to sentence: String, instructions: String) async throws -> String {
            gauge.note("respond")
            try await behave()
            return sentence.replacingOccurrences(of: "Their", with: "They're") + " [\(instructions.prefix(5))]"
        }
        func rewrite(_ text: String, prompt: IntentPass.Prompt) async throws -> String {
            gauge.note("rewrite")
            try await behave()
            return text.replacingOccurrences(of: "um, ", with: "") + " [\(prompt.examples.count)]"
        }
        func warm(_ prompt: IntentPass.Prompt) async throws {
            gauge.note("warm")
        }
        private func behave() async throws {
            switch mood {
            case .prompt: return
            case .cooperative:
                do { try await Task.sleep(for: .seconds(3600)) } catch {
                    gauge.note("cancelled")
                    throw error
                }
            case .stubborn:
                await gauge.park()
            case .ending:
                gauge.end()
                await gauge.park()
            }
        }
    }

    struct FakeEar: ServedEar {
        let gauge: Gauge
        let mood: Mood
        func transcribe(_ samples: [Float], context: [String]) async throws -> Heard {
            gauge.note("transcribe")
            gauge.remember(samples, context)
            if mood == .stubborn { await gauge.park() }
            return Heard("\(samples.count) samples, \(context.joined(separator: " "))")
        }
        func unload() { gauge.note("unload ear") }
    }

    final class FakeEngine: ModelsEngine, @unchecked Sendable {
        let gauge: Gauge
        let moods: [Mood]
        let earMood: Mood
        let earLoadParks: Bool
        /// How many of the first loads end the service's process.
        let loadCrashes: Int
        init(gauge: Gauge, moods: [Mood] = [.prompt], earMood: Mood = .prompt, earLoadParks: Bool = false,
             loadCrashes: Int = 0) {
            self.gauge = gauge
            self.moods = moods
            self.earMood = earMood
            self.earLoadParks = earLoadParks
            self.loadCrashes = loadCrashes
        }
        func loadLanguageModel(_ spec: LanguageModelSpec) async throws -> any ServedLanguageModel {
            let number = gauge.count("load")
            gauge.note("load")
            gauge.remember(spec)
            if number < loadCrashes {
                gauge.end()
                await gauge.park()
            }
            return FakeModel(gauge: gauge, mood: moods[min(number, moods.count - 1)])
        }
        func loadEar(_ spec: EarSpec) async throws -> any ServedEar {
            gauge.note("load ear")
            if earLoadParks { await gauge.park() }
            return FakeEar(gauge: gauge, mood: earMood)
        }
        func clearCache() { gauge.note("clear") }
        func memory() -> (activeMB: Int, cacheMB: Int)? { (2486, 64) }
        func check() throws -> String { "sum of squares 30 on fake" }
    }

    // MARK: - The rig

    /// A client over a simulated service, on a test clock.
    struct Rig {
        let clock: TestClock
        let events: RecordingInstrumentation
        let gauge: Gauge
        let service: XPCSimulatedService
        let client: ModelsClient

        /// Moves the clock by `duration`, once a timer is asleep: work woken
        /// by the test's last step (a grace, a backoff, an idle period) goes
        /// to sleep on a task of its own, and a clock moved before it does
        /// leaves it asleep past the advance. `expecting: false` for an
        /// advance over a service that holds something, which has no timer
        /// to wait for.
        func advance(by duration: Duration, expecting: Bool = true, file: StaticString = #filePath, line: UInt = #line) async {
            if expecting {
                let asleep = await ModelsServiceTests.eventually("no timer went to sleep for the advance of \(duration)", file: file, line: line) {
                    !clock.pendingDeadlines.isEmpty
                }
                guard asleep else { return }
            }
            await clock.advance(by: duration)
        }

        /// Waits until the peer is watching a request its caller left, which
        /// it starts on a task of its own once the caller has gone: a clock
        /// moved before it does counts the verdict from a later moment.
        func watching(for grace: Duration, file: StaticString = #filePath, line: UInt = #line) async {
            await ModelsServiceTests.eventually("the stuck watch of \(grace) never began", file: file, line: line) {
                clock.pendingDeadlines.contains { clock.now.duration(to: $0) == grace }
            }
        }

        func editor(answerDeadline: TimeInterval = 8, stuckAfter: TimeInterval = ModelCalls.defaultStuckAfter) -> EditorModel {
            let client = self.client
            return EditorModel(engine: .standard, idleRelease: 3600, answerDeadline: answerDeadline, gateWait: 3,
                               loadDeadline: 60, stuckAfter: stuckAfter, gate: MLXGate(),
                               loader: { _ in
                                   try await EditorModel.load(
                                       fromDirectory: URL(fileURLWithPath: "/models/gemma-4-e2b-it-4bit"),
                                       label: "standard", additionalContext: [:], client: client)
                               })
        }

        func ear(phraseDeadline: TimeInterval = 30) -> ServiceEar {
            ServiceEar(name: "qwen3-asr-1.7b", folder: URL(fileURLWithPath: "/ears/q"), client: client,
                       gate: MLXGate(), phraseDeadline: phraseDeadline)
        }
    }

    /// Runs `body` with a client of build `build` over a service whose
    /// hosts are build `hostBuild`, each run with a fresh engine state and
    /// a fresh MLX lane, as a fresh process has.
    private func withRig(
        moods: [Mood] = [.prompt], earMood: Mood = .prompt, earLoadParks: Bool = false, loadCrashes: Int = 0,
        sessionsEndFirst: Bool = false,
        build: String = Build.id, hostBuild: String = Build.id,
        host hostPolicy: XPCHostPolicy = XPCHostPolicy(),
        _ body: (Rig) async throws -> Void
    ) async throws {
        let clock = TestClock()
        let events = RecordingInstrumentation()
        try await withTestAmbient(clock: clock, seed: 7, events: events) { () async throws in
            let gauge = Gauge()
            gauges.append(gauge)
            let engine = FakeEngine(gauge: gauge, moods: moods, earMood: earMood, earLoadParks: earLoadParks,
                                    loadCrashes: loadCrashes)
            let service = XPCSimulatedService {
                let host = XPCHost(build: hostBuild, policy: hostPolicy)
                _ = ModelsService(host: host, engine: engine, gate: MLXGate())
                return host
            }
            gauge.end = { Task { await service.crash(sessionsEndFirst: sessionsEndFirst) } }
            let peer = XPCPeer(service: Models.serviceName, build: build, transport: service)
            defer { peer.shutdown() }
            try await body(Rig(clock: clock, events: events, gauge: gauge, service: service,
                               client: ModelsClient(peer: peer)))
        }
    }

    private var gauges: [Gauge] = []

    override func tearDown() {
        gauges.forEach { $0.unpark() }
        gauges = []
    }

    /// Polls `condition` in real time, briefly: for what another task does
    /// after the virtual clock moved or a message was sent.
    @discardableResult
    static func eventually(_ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        let held = condition()
        XCTAssertTrue(held, what, file: file, line: line)
        return held
    }

    private func eventually(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () -> Bool) async {
        await Self.eventually(what, file: file, line: line, condition)
    }

    /// The memory reading, which blocks its thread, taken off the pool's.
    private func reading(_ client: ModelsClient) async -> ModelsStats? {
        await Task.detached { client.memoryReading() }.value
    }

    // MARK: - What crosses

    /// Load, respond, rewrite and warm each cross and come back; the
    /// service is told the folder, so a fresh one could be told again; and
    /// a model let go in the app is let go in the service, its cache cleared.
    func testALanguageModelLoadsAndAnswersThroughTheService() async throws {
        try await withRig { rig in
            var model: ServiceLanguageModel? = try await rig.client.loadLanguageModel(LanguageModelSpec(
                directory: "/models/Qwen3.6-35B-A3B-4bit", label: "full", context: ["enable_thinking": false],
                cachesInstructions: false))
            XCTAssertEqual(rig.gauge.specs.first?.directory, "/models/Qwen3.6-35B-A3B-4bit")
            XCTAssertEqual(rig.gauge.specs.first?.context, ["enable_thinking": false])
            XCTAssertEqual(rig.gauge.specs.first?.cachesInstructions, false)
            let answer = try await model!.respond(to: "Their going.", instructions: "Correct it.")
            XCTAssertEqual(answer, "They're going. [Corre]")
            let prompt = IntentPass.Prompt(instructions: "Mean it.", examples: [.init(said: "uh hi", meant: "Hi")])
            try await model!.warm(prompt)
            let meant = try await model!.rewrite("um, hello", prompt: prompt)
            XCTAssertEqual(meant, "hello [1]", "the worked examples crossed with the prompt")
            XCTAssertEqual(rig.gauge.count("warm"), 1)
            XCTAssertEqual(rig.service.runs, 1)
            XCTAssertTrue(rig.client.holds)
            let read = await reading(rig.client)
            let stats = try XCTUnwrap(read)
            XCTAssertEqual(stats.languageModels, 1)
            XCTAssertEqual(stats.mlxActiveMB, 2486)
            XCTAssertEqual(stats.pid, getpid(), "hosted in this process here; its own in the app")

            model = nil
            XCTAssertFalse(rig.client.holds)
            await eventually("the service let it go and cleared MLX's cache") { rig.gauge.count("clear") == 1 }
            let after = try await rig.client.stats()
            XCTAssertEqual(after.languageModels, 0)
        }
    }

    /// The ear's samples cross as their bytes, exactly, with the names.
    func testTheEarLoadsHearsAndUnloadsThroughTheService() async throws {
        try await withRig { rig in
            let ear = rig.ear()
            XCTAssertFalse(ear.isLoaded)
            try await ear.load()
            XCTAssertTrue(ear.isLoaded)
            let samples: [Float] = (0..<16_000).map { Float($0) / 16_000 - 0.5 }
            let heard = try await ear.transcribe(samples, context: ["Lodestar", "Ghostty"])
            XCTAssertEqual(heard.text, "16000 samples, Lodestar Ghostty")
            XCTAssertEqual(rig.gauge.heard.first?.0, samples, "every sample, bit for bit")
            let held = await reading(rig.client)
            XCTAssertEqual(held?.ear, true)
            ear.unload()
            XCTAssertFalse(ear.isLoaded)
            await eventually("the service let the ear go") { rig.gauge.count("unload ear") == 1 }
            let stats = try await rig.client.stats()
            XCTAssertFalse(stats.ear)
        }
    }

    /// A stats reading never starts a service: with nothing loaded it is
    /// nil at once, and a reading that does ask (`ifRunning`) of a service
    /// that is not running fails at once, starting nothing. The status line
    /// would otherwise launch the model it reports on.
    func testAMemoryReadingNeverStartsAService() async throws {
        try await withRig { rig in
            let none = await reading(rig.client)
            XCTAssertNil(none)
            do {
                _ = try await rig.client.stats(ifRunning: true)
                XCTFail("a service that is not running answered")
            } catch ModelsError.unavailable {}
            XCTAssertEqual(rig.service.runs, 0, "no process was started")
            XCTAssertEqual(rig.service.sessions, 0)
            // `editor check` does want one.
            _ = try await rig.client.stats()
            XCTAssertEqual(rig.service.runs, 1)
            // With one running and nothing of ours in it, there is nothing to
            // say about: the line is nil, and the service is not asked.
            let sessions = rig.service.sessions
            let still = await reading(rig.client)
            XCTAssertNil(still)
            XCTAssertEqual(rig.service.sessions, sessions)
        }
    }

    /// Letting a model go after its service ended is nothing to tell the
    /// service: the next process holds no such model, and a release must
    /// not start one to say so.
    func testLettingAModelGoAfterItsServiceEndedStartsNothing() async throws {
        try await withRig { rig in
            var model: ServiceLanguageModel? = try await rig.client.loadLanguageModel(LanguageModelSpec(directory: "/m", label: "s"))
            await rig.service.crash()
            await eventually("the client heard") { rig.client.run == nil }
            model = nil
            // The release is asked from the model's deinit on a task of its
            // own: give it the moment it needs, then look.
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(rig.service.runs, 1, "no process was started to let a model go")
            XCTAssertNil(model)
            let ear = rig.ear()
            try await ear.load()
            await rig.service.crash()
            await eventually("the client heard the second") { rig.client.run == nil }
            ear.unload()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(rig.service.runs, 2, "nor to let the ear go")
        }
    }

    /// The service the signed bundle is checked by: it answers the GPU
    /// evaluation the self-test asks, from the process that ran it.
    func testTheCheckThatTheSelfTestAsksIsAnsweredByTheService() async throws {
        try await withRig { rig in
            let check = try await rig.client.check()
            XCTAssertEqual(check.answer, "sum of squares 30 on fake")
            XCTAssertEqual(rig.client.peer.run?.build, Build.id, "the build handshake passed with it")
        }
    }

    // MARK: - When the service fails

    /// The service ends while it answers: the editor hears at once (the
    /// clock never moved, so it was not the deadline), the generation is not
    /// sent again (it names a handle only the run that ended held), and the
    /// next sentence loads the model again in the fresh service and is
    /// answered.
    func testAServiceThatEndsMidGenerationIsLostNotResentAndTheNextQuestionLoadsAgain() async throws {
        try await withRig(moods: [.ending, .prompt]) { rig in
            let model = rig.editor()
            let started = rig.clock.now
            let lost = await model.correct("Their going.")
            XCTAssertNil(lost)
            XCTAssertEqual(rig.clock.now, started, "heard from the run's loss, not the deadline")
            XCTAssertEqual(rig.gauge.count("respond"), 1, "a generation that may have run is not sent again")
            XCTAssertEqual(rig.service.runs, 1, "and no run was started for it")
            let again = await model.correct("Their going.")
            XCTAssertEqual(again?.hasPrefix("They're going."), true, "answered by a fresh service")
            XCTAssertEqual(rig.gauge.count("load"), 2, "the model was loaded again")
            XCTAssertEqual(rig.service.runs, 2)
            XCTAssertEqual(rig.events.count("xpc.run_lost"), 1)
        }
    }

    /// The same for the intent pass's model: lost when its service ends,
    /// and loaded again by the next dictation.
    func testTheDraftsModelIsLoadedAgainAfterItsServiceEnded() async throws {
        try await withRig { rig in
            let client = rig.client
            let model = DraftModel(model: .gemma, gate: MLXGate(), loader: { _ in
                try await EditorModel.load(fromDirectory: URL(fileURLWithPath: "/models/gemma"), label: "gemma",
                                           additionalContext: [:], client: client)
            })
            let prompt = IntentPass.Prompt(instructions: "x", examples: [])
            await model.load()
            let isLoaded = await model.isLoaded
            XCTAssertTrue(isLoaded)
            await rig.service.crash()
            await eventually("the client heard") { client.run == nil }
            let gone = await model.isLoaded
            XCTAssertFalse(gone)
            let unasked = await model.rewrite("um, hi", prompt: prompt)
            XCTAssertNil(unasked, "the pass never loads")
            await model.load()
            let meant = await model.rewrite("um, hi", prompt: prompt)
            XCTAssertEqual(meant, "hi [0]")
            XCTAssertEqual(rig.gauge.count("load"), 2)

            // Ended again, and the next dictation starts before any pass asks:
            // its load is the one that finds the model lost.
            await rig.service.crash()
            await eventually("the client heard again") { client.run == nil }
            await model.load()
            XCTAssertEqual(rig.gauge.count("load"), 3, "dictation starting loads it again")
            let again = await model.rewrite("um, hi", prompt: prompt)
            XCTAssertEqual(again, "hi [0]")
        }
    }

    /// The ear, lost with its service, loads itself again at the next
    /// phrase: a draft open across the restart keeps hearing.
    func testTheEarLoadsAgainAtTheNextPhraseAfterItsServiceEnded() async throws {
        try await withRig { rig in
            let ear = rig.ear()
            try await ear.load()
            await rig.service.crash()
            await eventually("the client heard") { rig.client.run == nil }
            XCTAssertFalse(ear.isLoaded)
            let heard = try await ear.transcribe([0, 0, 0], context: [])
            XCTAssertEqual(heard.text, "3 samples, ")
            XCTAssertEqual(rig.gauge.count("load ear"), 2)
            XCTAssertTrue(ear.isLoaded)
        }
    }

    /// A load holds nothing yet, so one lost with its service is sent to
    /// the next (`idempotent`); a generation is not (`notRepeatable`). The
    /// first request of each kind reaches a run that crashes under it.
    func testALoadLostWithItsServiceIsSentOnceMoreButAGenerationIsNot() async throws {
        try await withRig(moods: [.ending]) { rig in
            // The first load's run crashes while the model is answering; the
            // model itself loaded on that run, which is gone.
            let model = try await rig.client.loadLanguageModel(LanguageModelSpec(directory: "/m", label: "s"))
            do {
                _ = try await model.respond(to: "Their going.", instructions: "x")
                XCTFail("a generation on a crashing service answered")
            } catch ModelsError.interrupted {}
            XCTAssertTrue(model.isLost)
            XCTAssertEqual(rig.gauge.count("respond"), 1, "not sent again")
        }
        try await withRig(loadCrashes: 1) { rig in
            // The first run crashes under the load; the load holds nothing
            // yet, so it is sent again, to a new run, which holds the model.
            let client = rig.client
            let loading = Task { try await client.loadLanguageModel(LanguageModelSpec(directory: "/m", label: "s")) }
            await eventually("the first attempt was lost with its run") { rig.events.count("retry.attempt_failed") >= 1 }
            await rig.advance(by: .seconds(3))  // past the backoff before the second attempt
            let model = try await loading.value
            XCTAssertEqual(rig.gauge.count("load"), 2)
            XCTAssertEqual(rig.service.runs, 2)
            XCTAssertFalse(model.isLost, "it is on the run that answered")
            let answer = try await model.respond(to: "Their going.", instructions: "x")
            XCTAssertEqual(answer, "They're going. [x]")
        }
    }

    /// What tells the app that a service is gone is two signals, the replies
    /// that fail and the session that ends, and the system delivers them in
    /// either order (the old client was caught by it: XPC reported a dead
    /// endpoint as an interruption in some runs and as an invalidation in
    /// others, and a retry that kept the connection of the first met the
    /// dead one again). A load lost with its run is sent to a new run
    /// whichever signal comes first, and the model is held by the run that
    /// answered.
    func testALoadLostWithItsServiceIsSentAgainWhicheverSignalOfTheLossComesFirst() async throws {
        for sessionsEndFirst in [false, true] {
            let order = sessionsEndFirst ? "the session ending first" : "the replies failing first"
            try await withRig(loadCrashes: 1, sessionsEndFirst: sessionsEndFirst) { rig in
                let client = rig.client
                let loading = Task { try await client.loadLanguageModel(LanguageModelSpec(directory: "/m", label: "s")) }
                await eventually("the first attempt was lost with its run, \(order)") { rig.events.count("retry.attempt_failed") >= 1 }
                await rig.advance(by: .seconds(3))  // past the backoff before the second attempt
                let model = try await loading.value
                XCTAssertEqual(rig.gauge.count("load"), 2, order)
                XCTAssertEqual(rig.service.runs, 2, "a new run, \(order)")
                XCTAssertFalse(model.isLost, "it is on the run that answered, \(order)")
                let answer = try await model.respond(to: "Their going.", instructions: "x")
                XCTAssertEqual(answer, "They're going. [x]", order)
            }
        }
    }

    /// A question whose deadline passes is cancelled in the service: the
    /// cancel crosses, the generation stops at its next token, and the
    /// model answers the next question.
    func testADeadlineCancelsTheGenerationInTheService() async throws {
        try await withRig(moods: [.cooperative]) { rig in
            let model = rig.editor(answerDeadline: 0.3)
            let asking = Task { await model.correct("Their going.") }
            await eventually("the generation began in the service") { rig.gauge.count("respond") == 1 }
            await rig.advance(by: .milliseconds(300))
            let unanswered = await asking.value
            XCTAssertNil(unanswered)
            await eventually("the service stopped the generation") { rig.gauge.count("cancelled") == 1 }
            XCTAssertEqual(model.ability, .unable)
            XCTAssertEqual(rig.gauge.count("load"), 1, "a cancelled answer is not a lost model")
            XCTAssertEqual(rig.service.runs, 1, "and it did not end the service: it stopped")
        }
    }

    /// A generation that never stops, cancelled or not, is the one the app
    /// cannot stop by asking. Once its caller has given up on it for the
    /// time the method declares (`ModelsAPI.stuckAfter`), the peer ends the
    /// service, while the generation is still stuck; and the question after
    /// loads a fresh model in a fresh service. (The host's own watchdog is
    /// held off here, so it is the declaration that ends it.)
    func testAWedgedGenerationEndsTheServiceWhileItIsStillStuck() async throws {
        try await withRig(moods: [.stubborn, .prompt], host: XPCHostPolicy(watchdogGrace: .seconds(600))) { rig in
            let model = rig.editor(answerDeadline: 1.0)
            let asking = Task { await model.correct("Their going.") }
            await eventually("the generation is stuck in the service") { rig.gauge.parkedCount == 1 }
            await rig.advance(by: .seconds(1))
            let first = await asking.value
            XCTAssertNil(first)
            XCTAssertEqual(rig.service.exits, [], "not ended for being late: it may yet stop")
            await rig.watching(for: ModelsAPI.stuckAfter)
            await rig.advance(by: ModelsAPI.stuckAfter - .milliseconds(1))
            XCTAssertEqual(rig.service.exits, [])
            await rig.advance(by: .milliseconds(1))
            await eventually("the service was ended") { rig.service.exits == [0] }
            XCTAssertEqual(rig.gauge.parkedCount, 1, "ended while the generation was still stuck")
            XCTAssertEqual(rig.events.count("xpc.call_stuck"), 1)
            await eventually("the peer reported the end it decided") { rig.events.count("xpc.run_ended") == 1 }
            XCTAssertEqual(rig.events.events(named: "xpc.run_ended").first?.text("reason"), "models.respond was stuck")
            let answer = await model.correct("Their going.")  // finds it stuck, loads again, in a fresh service
            XCTAssertEqual(answer?.hasPrefix("They're going."), true)
            XCTAssertEqual(rig.gauge.count("load"), 2)
            XCTAssertEqual(rig.service.runs, 2)
        }
    }

    /// A generation that ignores its cancellation past its budget and the
    /// host's grace ends the service from the inside, which is the only way
    /// a wedged service ends in a sandbox: the app sees its run lost.
    func testAGenerationThatIgnoresItsCancellationEndsTheServiceFromTheInside() async throws {
        try await withRig(moods: [.stubborn]) { rig in
            let model = rig.editor(answerDeadline: 2.0)
            let asking = Task { await model.correct("Their going.") }
            await eventually("the generation is stuck in the service") { rig.gauge.parkedCount == 1 }
            await rig.advance(by: .seconds(2))
            let answer = await asking.value
            XCTAssertNil(answer)
            XCTAssertEqual(rig.service.exits, [])
            // Its budget was two seconds; the host's grace is ten.
            await rig.advance(by: .seconds(10))
            await eventually("the host ended its own process") { rig.service.exits == [1] }
            XCTAssertEqual(rig.events.events(named: "xpc.watchdog_exit").first?.text("method"), "models.respond")
        }
    }

    /// An ear phrase that does not come back by its deadline is cancelled
    /// and, when it does not stop in the grace the method declares, ends the
    /// service: it is the only way a stuck evaluation stops.
    func testAnEarPhrasePastItsDeadlineEndsTheService() async throws {
        try await withRig(earMood: .stubborn, host: XPCHostPolicy(watchdogGrace: .seconds(600))) { rig in
            let ear = rig.ear(phraseDeadline: 0.3)
            try await ear.load()
            let hearing = Task { try await ear.transcribe([0], context: []) }
            await eventually("the phrase is stuck in the service") { rig.gauge.parkedCount == 1 }
            await rig.advance(by: .milliseconds(300))
            do {
                _ = try await hearing.value
                XCTFail("a stuck phrase answered")
            } catch ModelsError.timedOut {}
            XCTAssertEqual(rig.service.exits, [], "the phrase had the grace to notice its cancellation")
            await rig.watching(for: ModelsAPI.earStuckAfter)
            await rig.advance(by: ModelsAPI.earStuckAfter)
            await eventually("the service was ended") { rig.service.exits == [0] }
            XCTAssertEqual(rig.gauge.parkedCount, 1, "while the phrase was stuck")
            await eventually("the client heard") { rig.client.run == nil }
            XCTAssertFalse(ear.isLoaded)
            XCTAssertEqual(rig.gauge.count("transcribe"), 1)
        }
    }

    // MARK: - What the failures are to the editor and dictation

    /// A request the service answers with a model it does not hold says so,
    /// and the model is lost for good: its owner loads another.
    func testAHandleTheServiceDoesNotHoldSaysNotLoadedAndTheModelIsLost() async throws {
        try await withRig { rig in
            let model = try await rig.client.loadLanguageModel(LanguageModelSpec(directory: "/m", label: "s"))
            let stranger = ServiceLanguageModel(client: rig.client, handle: "not a handle", run: rig.client.run, label: "x")
            XCTAssertFalse(stranger.isLost)
            do {
                _ = try await stranger.respond(to: "x", instructions: "y")
                XCTFail("a handle that was never loaded answered")
            } catch ModelsFailure.notLoaded {}
            XCTAssertTrue(stranger.isLost)
            XCTAssertFalse(model.isLost, "and the one that was loaded is not")
            XCTAssertEqual(rig.gauge.count("respond"), 0)
        }
    }

    /// A caller that leaves is cancelled (`CancellationError`, which the
    /// editor already treats as nothing), and the service is told.
    func testACallerThatLeavesIsCancelledAndTheServiceStopsTheGeneration() async throws {
        try await withRig(moods: [.cooperative]) { rig in
            let model = try await rig.client.loadLanguageModel(LanguageModelSpec(directory: "/m", label: "s"))
            let asking = Task { try await model.respond(to: "Their going.", instructions: "x") }
            await eventually("the generation began") { rig.gauge.count("respond") == 1 }
            asking.cancel()
            do {
                _ = try await asking.value
                XCTFail("a cancelled call answered")
            } catch is CancellationError {}
            await eventually("the service cancelled it") { rig.gauge.count("cancelled") == 1 }
            XCTAssertFalse(model.isLost, "a caller that left did not lose the model")
        }
    }

    /// The app ending the service (the peer's `end`, which the stuck verdict
    /// and a quit use) is an interruption to what was waiting on it, and
    /// not a failure of the service.
    func testWhatIsWaitingWhenTheAppEndsTheServiceIsInterrupted() async throws {
        try await withRig(moods: [.cooperative], host: XPCHostPolicy(watchdogGrace: .seconds(600))) { rig in
            let model = try await rig.client.loadLanguageModel(LanguageModelSpec(directory: "/m", label: "s"))
            let asking = Task { try await model.respond(to: "Their going.", instructions: "x") }
            await eventually("the generation began") { rig.gauge.count("respond") == 1 }
            let ending = Task { await rig.client.peer.end(reason: "a test") }
            do {
                _ = try await asking.value
                XCTFail("a generation on an ended service answered")
            } catch ModelsError.interrupted {}
            let result = await ending.value
            XCTAssertEqual(result, .exited)
            XCTAssertTrue(model.isLost)
            XCTAssertEqual(rig.events.count("xpc.run_lost"), 0, "an end the app decided is not the service failing")
        }
    }

    /// A service of another build than the app is refused, and what the
    /// editor sees says to restart, and nothing is sent again.
    func testAServiceOfAnotherBuildIsUnavailableWithTheReasonAndNothingIsRepeated() async throws {
        try await withRig(build: "0.0.0-older", hostBuild: Build.id) { rig in
            do {
                _ = try await rig.client.stats()
                XCTFail("a service of another build answered")
            } catch let error as ModelsError {
                guard case .unavailable(let why) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(why.contains("restart Lodestar"), why)
                XCTAssertTrue(why.contains(Build.id), why)
            }
            XCTAssertEqual(rig.service.runs, 1)
            XCTAssertEqual(rig.events.events(named: "xpc.build_mismatch").count { $0.label == Models.serviceName }, 1)
            do {
                _ = try await rig.client.stats()
                XCTFail("it was refused once")
            } catch ModelsError.unavailable {}
            XCTAssertEqual(rig.service.sessions, 1, "no second try on a service that is another build")
        }
    }

    /// A service the bundle does not carry is unavailable at once.
    func testAServiceNotInTheBundleIsUnavailable() async throws {
        try await withRig { rig in
            rig.service.refusesConnections = "no such service"
            do {
                _ = try await rig.client.loadLanguageModel(LanguageModelSpec(directory: "/m", label: "s"))
                XCTFail("a service that is not there answered")
            } catch ModelsError.unavailable {}
            XCTAssertEqual(rig.service.runs, 0)
        }
    }

    /// A request the service has no handler for is a bug in this build,
    /// and says so: unreadable, not a service that ended.
    func testARequestTheServiceDoesNotKnowIsUnreadable() async throws {
        let clock = TestClock()
        try await withTestAmbient(clock: clock, seed: 7) { () async throws in
            let service = XPCSimulatedService { XPCHost(build: Build.id) }
            let peer = XPCPeer(service: Models.serviceName, build: Build.id, transport: service)
            defer { peer.shutdown() }
            do {
                _ = try await ModelsClient(peer: peer).stats()
                XCTFail("a service with no handlers answered")
            } catch ModelsError.unreadable {}
        }
    }

    // MARK: - Memory

    /// A warning lets the model go (`EditorController.memoryPressure`
    /// releases the proofreader), and a service that then holds nothing
    /// ends itself after the idle period, so every page MLX held goes with
    /// the process. One that still holds the ear stays: a warning keeps
    /// the ear (`EarHost`).
    func testAWarningLetsTheModelGoAndAnEmptyServiceEnds() async throws {
        try await withRig(host: XPCHostPolicy(idleExit: Models.idleExit)) { rig in
            let ear = rig.ear()
            try await ear.load()
            let model = rig.editor()
            await model.prepare()
            await model.release(reason: "memory pressure")
            await eventually("the model let go in the service") { rig.gauge.count("clear") == 1 }
            await rig.advance(by: Models.idleExit * 3, expecting: false)
            XCTAssertEqual(rig.service.exits, [], "the ear is still held")
            ear.unload()
            await eventually("the service let the ear go") { rig.gauge.count("unload ear") == 1 }
            await rig.advance(by: Models.idleExit)
            await eventually("holding nothing, it ended") { rig.service.exits == [0] }
            XCTAssertEqual(rig.events.count("xpc.idle_exit"), 1)
        }
    }

    /// What the service holds is held against its idle exit by the model and
    /// by the ear each, and only the last release starts the period.
    func testAnyOneThingHeldKeepsTheServiceAndTheLastReleaseStartsTheIdlePeriod() async throws {
        try await withRig(host: XPCHostPolicy(idleExit: Models.idleExit)) { rig in
            let first = try await rig.client.loadLanguageModel(LanguageModelSpec(directory: "/m", label: "a"))
            var second: ServiceLanguageModel? = try await rig.client.loadLanguageModel(LanguageModelSpec(directory: "/m", label: "b"))
            XCTAssertNotNil(second)
            await rig.advance(by: Models.idleExit * 3, expecting: false)
            XCTAssertEqual(rig.service.exits, [], "two models held")
            let stats = try await rig.client.stats()
            XCTAssertEqual(stats.languageModels, 2, "and it still answers")
            second = nil
            await eventually("one went") { rig.gauge.count("clear") == 1 }
            await rig.advance(by: Models.idleExit * 3, expecting: false)
            XCTAssertEqual(rig.service.exits, [], "one model still held")
            withExtendedLifetime(first) {}
        }
        try await withRig(host: XPCHostPolicy(idleExit: Models.idleExit)) { rig in
            var model: ServiceLanguageModel? = try await rig.client.loadLanguageModel(LanguageModelSpec(directory: "/m", label: "a"))
            model = nil
            await eventually("it went") { rig.gauge.count("clear") == 1 }
            await rig.advance(by: Models.idleExit - .milliseconds(1))
            XCTAssertEqual(rig.service.exits, [], "the period starts at the release, and has not passed")
            await rig.advance(by: .milliseconds(1))
            await eventually("then it ended") { rig.service.exits == [0] }
            XCTAssertNil(model)
        }
    }

    /// Asked something while it waits to end, it does not end.
    func testAServiceAskedAgainBeforeItEndsStays() async throws {
        try await withRig(host: XPCHostPolicy(idleExit: .seconds(10))) { rig in
            var model: ServiceLanguageModel? = try await rig.client.loadLanguageModel(LanguageModelSpec(directory: "/m", label: "s"))
            model = nil
            await eventually("it went") { rig.gauge.count("clear") == 1 }
            await rig.advance(by: .seconds(5))
            model = try await rig.client.loadLanguageModel(LanguageModelSpec(directory: "/m", label: "s"))
            await rig.advance(by: .seconds(30), expecting: false)
            XCTAssertEqual(rig.service.exits, [])
            XCTAssertEqual(rig.service.runs, 1)
            XCTAssertNotNil(model)
        }
    }

    /// An unload that overtakes an ear's load lets the loaded ear go when
    /// it lands, rather than hold it for no one: the load is answered
    /// `cancelled`, which the caller sees as a cancellation, and the service
    /// holds nothing of it (so nothing keeps it from idling out).
    func testAnUnloadThatOvertakesAnEarLoadLetsItGo() async throws {
        try await withRig(earLoadParks: true, host: XPCHostPolicy(idleExit: Models.idleExit)) { rig in
            let loading = Task { try await rig.client.loadEar(EarSpec(name: "qwen3-asr-1.7b", directory: "/q")) }
            await eventually("the load is parked in the engine") { rig.gauge.parkedCount == 1 }
            _ = try await rig.client.peer.call(ModelsAPI.unloadEar, XPCEmpty())
            rig.gauge.unpark()
            do {
                _ = try await loading.value
                XCTFail("an overtaken load answered")
            } catch is CancellationError {}
            XCTAssertEqual(rig.gauge.count("unload ear"), 1, "the late ear was let go")
            let stats = try await rig.client.stats()
            XCTAssertFalse(stats.ear)
            await rig.advance(by: Models.idleExit)
            await eventually("nothing held, it ended") { rig.service.exits == [0] }
        }
    }
}

private extension RecordingInstrumentation {
    func count(_ name: EventName) -> Int { events(named: name).count }
}

private extension Event {
    func text(_ key: String) -> String? {
        if case .string(let value)? = self[key] { value } else { nil }
    }
}
