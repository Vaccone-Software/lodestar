import Foundation
import XCTest
@testable import lodestar
@testable import LodestarCore
@testable import LodestarEars

/// The models run in an XPC service. Here the service's own object
/// (`ModelsService`) is hosted behind an anonymous listener with a fake
/// engine: no MLX and no GPU, but every request and answer crosses real
/// XPC, with its interruption and invalidation, its cancels and its exit.
/// Only the launch by name, and MLX finding its kernels in the service's
/// bundle, are left to the signed app's self-test (`SelfTest.modelsService`).
final class ModelsServiceTests: XCTestCase {
    // MARK: - The fake engine

    /// How a question is answered.
    enum Mood: Sendable {
        case prompt
        /// Waits until cancelled, as a generation does at its next token.
        case cooperative
        /// Never stops, cancelled or not: an evaluation stuck in MLX.
        case stubborn
        /// The service ends while it answers, as a crash would.
        case ending
    }

    final class Gauge: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        private var parked: [CheckedContinuation<Void, Never>] = []
        var specs: [LanguageModelSpec] = []
        var heard: [([Float], [String])] = []
        /// What `.ending` does: the test ends the service's connections.
        var end: () -> Void = {}

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
        init(gauge: Gauge, moods: [Mood] = [.prompt], earMood: Mood = .prompt, earLoadParks: Bool = false) {
            self.gauge = gauge
            self.moods = moods
            self.earMood = earMood
            self.earLoadParks = earLoadParks
        }
        func loadLanguageModel(_ spec: LanguageModelSpec) async throws -> any ServedLanguageModel {
            let number = gauge.count("load")
            gauge.note("load")
            gauge.remember(spec)
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

    // MARK: - The host

    /// A listener standing in for launchd: each connection is handed the
    /// object `exported` makes for it (the same one, for one process; a new
    /// one, for a service started afresh).
    final class Host: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
        let listener = NSXPCListener.anonymous()
        let exported: (Int) -> ModelsService
        private let lock = NSLock()
        private(set) var connections = 0
        private var open: [NSXPCConnection] = []
        init(_ exported: @escaping (Int) -> ModelsService) {
            self.exported = exported
            super.init()
            listener.delegate = self
            listener.resume()
        }
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            let number = lock.withLock { () -> Int in
                connections += 1
                open.append(connection)
                return connections
            }
            let service = exported(number)
            connection.exportedInterface = NSXPCInterface(with: ModelsXPC.self)
            connection.exportedObject = service
            connection.invalidationHandler = { [weak connection] in
                if let connection { service.connectionEnded(connection) }
            }
            connection.resume()
            return true
        }
        /// The service's process ended: every connection to it goes.
        func endService() {
            let all = lock.withLock { () -> [NSXPCConnection] in
                defer { open = [] }
                return open
            }
            all.forEach { $0.invalidate() }
        }
    }

    final class Exits: @unchecked Sendable {
        private let lock = NSLock()
        private var reasons: [String] = []
        var parkedAtExit: [Int] = []
        func note(_ reason: String, parked: Int) {
            lock.withLock {
                reasons.append(reason)
                parkedAtExit.append(parked)
            }
        }
        var all: [String] { lock.withLock { reasons } }
    }

    private var hosts: [Host] = []
    private var gauges: [Gauge] = []

    override func tearDown() {
        gauges.forEach { $0.unpark() }
        hosts.forEach { $0.listener.invalidate() }
        hosts = []
        gauges = []
    }

    /// A service process and a client connected to it by endpoint.
    private func served(moods: [Mood] = [.prompt], earMood: Mood = .prompt, earLoadParks: Bool = false,
                        freshPerConnection: Bool = false, endsWhenEmptyAfter: TimeInterval? = nil,
                        exits: Exits? = nil) -> (ModelsClient, Host, Gauge, Counter) {
        let gauge = Gauge()
        gauges.append(gauge)
        let engine = FakeEngine(gauge: gauge, moods: moods, earMood: earMood, earLoadParks: earLoadParks)
        var host: Host!
        let make = { () -> ModelsService in
            ModelsService(engine: engine, gate: MLXGate(), endsWhenEmptyAfter: endsWhenEmptyAfter) { reason in
                exits?.note(reason, parked: gauge.parkedCount)
                // The process ends, and its connections with it.
                host.endService()
            }
        }
        let one = make()
        host = Host { _ in freshPerConnection ? make() : one }
        gauge.end = { [unowned host] in host!.endService() }
        hosts.append(host)
        let made = Counter()
        let client = ModelsClient { [unowned host] in
            made.add()
            return NSXPCConnection(listenerEndpoint: host!.listener.endpoint)
        }
        return (client, host, gauge, made)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func add() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private func eventually(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), what)
    }

    private func editor(_ client: ModelsClient, answerDeadline: TimeInterval = 8, stuckAfter: TimeInterval = 20,
                        onWedged: (@Sendable () -> Void)? = nil) -> EditorModel {
        EditorModel(engine: .standard, idleRelease: 3600, answerDeadline: answerDeadline, gateWait: 3,
                    loadDeadline: 60, stuckAfter: stuckAfter, gate: MLXGate(),
                    loader: { _ in
                        try await EditorModel.load(fromDirectory: URL(fileURLWithPath: "/models/gemma-4-e2b-it-4bit"),
                                                   label: "standard", additionalContext: [:], client: client)
                    },
                    onWedged: onWedged ?? { client.end(reason: "editor.model wedged") })
    }

    // MARK: - What crosses

    /// Load, respond, rewrite and warm each cross and come back; the
    /// service is told the folder, so a fresh one could be told again; and
    /// a model let go in the app is let go in the service, its cache cleared.
    func testALanguageModelLoadsAndAnswersThroughTheService() async throws {
        let (client, host, gauge, _) = served()
        var model: ServiceLanguageModel? = try await client.loadLanguageModel(LanguageModelSpec(
            directory: "/models/Qwen3.6-35B-A3B-4bit", label: "full", context: ["enable_thinking": false],
            cachesInstructions: false))
        XCTAssertEqual(gauge.specs.first?.directory, "/models/Qwen3.6-35B-A3B-4bit")
        XCTAssertEqual(gauge.specs.first?.context, ["enable_thinking": false])
        XCTAssertEqual(gauge.specs.first?.cachesInstructions, false)
        let answer = try await model!.respond(to: "Their going.", instructions: "Correct it.")
        XCTAssertEqual(answer, "They're going. [Corre]")
        let prompt = IntentPass.Prompt(instructions: "Mean it.", examples: [.init(said: "uh hi", meant: "Hi")])
        try await model!.warm(prompt)
        let meant = try await model!.rewrite("um, hello", prompt: prompt)
        XCTAssertEqual(meant, "hello [1]", "the worked examples crossed with the prompt")
        XCTAssertEqual(gauge.count("warm"), 1)
        XCTAssertEqual(host.connections, 1)
        XCTAssertTrue(client.holds)
        let stats = try XCTUnwrap(client.memoryReading())
        XCTAssertEqual(stats.languageModels, 1)
        XCTAssertEqual(stats.mlxActiveMB, 2486)
        XCTAssertEqual(stats.pid, getpid(), "hosted in this process here; its own in the app")

        model = nil
        XCTAssertFalse(client.holds)
        await eventually("the service let it go and cleared MLX's cache") { gauge.count("clear") == 1 }
        let after = try await client.stats()
        XCTAssertEqual(after.languageModels, 0)
    }

    /// The ear's samples cross as their bytes, exactly, with the names.
    func testTheEarLoadsHearsAndUnloadsThroughTheService() async throws {
        let (client, _, gauge, _) = served()
        let ear = ServiceEar(name: "qwen3-asr-1.7b", folder: URL(fileURLWithPath: "/ears/Qwen3-ASR-1.7B-8bit"),
                             client: client, gate: MLXGate())
        XCTAssertFalse(ear.isLoaded)
        try await ear.load()
        XCTAssertTrue(ear.isLoaded)
        let samples: [Float] = (0..<16_000).map { Float($0) / 16_000 - 0.5 }
        let heard = try await ear.transcribe(samples, context: ["Lodestar", "Ghostty"])
        XCTAssertEqual(heard.text, "16000 samples, Lodestar Ghostty")
        XCTAssertEqual(gauge.heard.first?.0, samples, "every sample, bit for bit")
        XCTAssertEqual(client.memoryReading()?.ear, true)
        ear.unload()
        XCTAssertFalse(ear.isLoaded)
        await eventually("the service let the ear go") { gauge.count("unload ear") == 1 }
        let stats = try await client.stats()
        XCTAssertFalse(stats.ear)
    }

    /// A stats reading never starts a service: with nothing loaded it is
    /// nil at once and no connection is made.
    func testAMemoryReadingNeverStartsAService() {
        let (client, _, _, made) = served()
        XCTAssertNil(client.memoryReading())
        XCTAssertEqual(made.value, 0)
    }

    // MARK: - When the service fails

    /// The service ends while it answers: the editor hears at once, well
    /// inside its deadline, the connection is only interrupted (no new one
    /// is made), and the next sentence loads the model again in the fresh
    /// service and is answered.
    func testAServiceThatEndsMidGenerationIsInterruptedAndTheNextQuestionLoadsAgain() async throws {
        let (client, host, gauge, made) = served(moods: [.ending, .prompt], freshPerConnection: true)
        let model = editor(client)
        let started = Date()
        let lost = await model.correct("Their going.")
        XCTAssertNil(lost)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "heard through the error handler, not the deadline")
        XCTAssertEqual(made.value, 1, "an interruption leaves the connection usable")
        let again = await model.correct("Their going.")
        XCTAssertEqual(again?.hasPrefix("They're going."), true, "answered by a fresh service")
        XCTAssertEqual(gauge.count("load"), 2, "the model was loaded again")
        XCTAssertEqual(host.connections, 2, "by the next message, which reached a fresh service")
        XCTAssertEqual(made.value, 1)
    }

    /// The same for the intent pass's model: lost when its service ends,
    /// and loaded again by the next dictation.
    func testTheDraftsModelIsLoadedAgainAfterItsServiceEnded() async throws {
        let (client, host, gauge, _) = served(moods: [.prompt], freshPerConnection: true)
        let model = DraftModel(model: .gemma, gate: MLXGate(), loader: { _ in
            try await EditorModel.load(fromDirectory: URL(fileURLWithPath: "/models/gemma"), label: "gemma",
                                       additionalContext: [:], client: client)
        })
        await model.load()
        let isLoaded = await model.isLoaded
        XCTAssertTrue(isLoaded)
        host.endService()
        await eventually("the client heard") { client.epoch == 1 }
        let gone = await model.isLoaded
        XCTAssertFalse(gone)
        let unasked = await model.rewrite("um, hi", prompt: IntentPass.Prompt(instructions: "x", examples: []))
        XCTAssertNil(unasked, "the pass never loads")
        await model.load()
        let meant = await model.rewrite("um, hi", prompt: IntentPass.Prompt(instructions: "x", examples: []))
        XCTAssertEqual(meant, "hi [0]")
        XCTAssertEqual(gauge.count("load"), 2)

        // Ended again, and the next dictation starts before any pass asks:
        // its load is the one that finds the model lost.
        host.endService()
        await eventually("the client heard again") { client.epoch == 2 }
        await model.load()
        XCTAssertEqual(gauge.count("load"), 3, "dictation starting loads it again")
        let again = await model.rewrite("um, hi", prompt: IntentPass.Prompt(instructions: "x", examples: []))
        XCTAssertEqual(again, "hi [0]")
    }

    /// The ear, lost with its service, loads itself again at the next
    /// phrase: a draft open across the restart keeps hearing.
    func testTheEarLoadsAgainAtTheNextPhraseAfterItsServiceEnded() async throws {
        let (client, host, gauge, _) = served(freshPerConnection: true)
        let ear = ServiceEar(name: "qwen3-asr-1.7b", folder: URL(fileURLWithPath: "/ears/q"), client: client, gate: MLXGate())
        try await ear.load()
        host.endService()
        await eventually("the client heard") { client.epoch == 1 }
        XCTAssertFalse(ear.isLoaded)
        let heard = try await ear.transcribe([0, 0, 0], context: [])
        XCTAssertEqual(heard.text, "3 samples, ")
        XCTAssertEqual(gauge.count("load ear"), 2)
        XCTAssertTrue(ear.isLoaded)
    }

    /// A connection that cannot reach its service is invalidated and let
    /// go: a question on it fails at once, and a load, which holds nothing
    /// yet, is sent once more on a new connection.
    func testAnInvalidatedConnectionIsReplacedAndALoadIsSentAgain() async throws {
        let gauge = Gauge()
        gauges.append(gauge)
        let engine = FakeEngine(gauge: gauge)
        let working = Host { _ in ModelsService(engine: engine, gate: MLXGate(), endsWhenEmptyAfter: nil) }
        hosts += [working]
        let made = Counter()
        // The first connection is invalidated before it is used, which XPC
        // answers with NSXPCConnectionInvalid for certain; how soon XPC
        // gives up on a listener that is gone is not something to time
        // (it failed on a slow runner).
        let client = ModelsClient {
            made.add()
            let connection = NSXPCConnection(listenerEndpoint: working.listener.endpoint)
            if made.value == 1 { connection.invalidate() }
            return connection
        }
        let model = try await client.loadLanguageModel(LanguageModelSpec(directory: "/m", label: "standard"))
        XCTAssertEqual(made.value, 2, "the invalidated connection was let go and a new one made")
        XCTAssertEqual(working.connections, 1)
        XCTAssertFalse(model.isLost)
        let answer = try await model.respond(to: "Their going.", instructions: "x")
        XCTAssertEqual(answer, "They're going. [x]")
    }

    /// A question whose deadline passes is cancelled in the service: the
    /// cancel crosses, the generation stops at its next token, and the
    /// model answers the next question.
    func testADeadlineCancelsTheGenerationInTheService() async throws {
        let (client, _, gauge, _) = served(moods: [.cooperative])
        let model = editor(client, answerDeadline: 0.3)
        let unanswered = await model.correct("Their going.")
        XCTAssertNil(unanswered)
        await eventually("the service stopped the generation") { gauge.count("cancelled") == 1 }
        XCTAssertEqual(model.ability, .unable)
        XCTAssertEqual(gauge.count("load"), 1, "a cancelled answer is not a lost model")
    }

    /// A cancel that reaches the service before its request refuses it.
    func testACancelThatComesFirstRefusesTheRequest() throws {
        let gauge = Gauge()
        let service = ModelsService(engine: FakeEngine(gauge: gauge), gate: MLXGate(), endsWhenEmptyAfter: nil)
        service.cancel(7)
        let done = expectation(description: "replied")
        let body = try XCTUnwrap(Models.encode(ModelsGenerate(id: 7, handle: "none", text: "x",
                                                               prompt: .init(instructions: "", examples: []))))
        service.respond(body) { data in
            XCTAssertEqual(Models.decode(ModelsReply<String>.self, from: data)?.failure, .cancelled)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(gauge.count("respond"), 0)
    }

    /// A generation that never stops, cancelled or not, is the one the
    /// app cannot stop by asking: once it has been given up on for
    /// `stuckAfter`, the next question ends the service, whose `exit` is
    /// heard on a queue of its own while the generation is still stuck,
    /// and the question after loads a fresh model in a fresh service.
    func testAWedgedGenerationEndsTheServiceWhileItIsStillStuck() async throws {
        let exits = Exits()
        let (client, host, gauge, _) = served(moods: [.stubborn, .prompt], freshPerConnection: true, exits: exits)
        // Deadlines with room for a loaded machine: the healthy answer after
        // recovery must never pass its deadline, or it counts a load more.
        let model = editor(client, answerDeadline: 1.0, stuckAfter: 1.5)
        let first = await model.correct("Their going.")
        XCTAssertNil(first)
        XCTAssertEqual(gauge.parkedCount, 1, "the generation is still running in the service")
        try await Task.sleep(for: .milliseconds(2000))
        _ = await model.correct("Their going.")  // finds it stuck, ends the service, loads again
        await eventually("the service was asked to exit") { exits.all == ["editor.model wedged"] }
        XCTAssertEqual(exits.parkedAtExit, [1], "heard while the generation was stuck")
        let answer = await model.correct("Their going.")
        XCTAssertEqual(answer?.hasPrefix("They're going."), true)
        XCTAssertEqual(gauge.count("load"), 2)
        XCTAssertGreaterThanOrEqual(host.connections, 2)
    }

    /// An ear phrase that does not come back by its deadline ends the
    /// service: it is the only way a stuck evaluation stops.
    func testAnEarPhrasePastItsDeadlineEndsTheService() async throws {
        let exits = Exits()
        let (client, _, gauge, _) = served(earMood: .stubborn, freshPerConnection: true, exits: exits)
        let ear = ServiceEar(name: "qwen3-asr-1.7b", folder: URL(fileURLWithPath: "/ears/q"), client: client,
                             gate: MLXGate(), phraseDeadline: 0.3)
        try await ear.load()
        do {
            _ = try await ear.transcribe([0], context: [])
            XCTFail("a stuck phrase answered")
        } catch ModelsError.timedOut {}
        await eventually("the service was asked to exit") { exits.all.count == 1 }
        XCTAssertEqual(exits.parkedAtExit, [1])
        XCTAssertFalse(ear.isLoaded)
        XCTAssertEqual(gauge.count("transcribe"), 1)
    }

    // MARK: - Memory

    /// A warning lets the model go (`EditorController.memoryPressure`
    /// releases the proofreader), and a service that then holds nothing
    /// ends itself, so every page MLX held goes with the process. One that
    /// still holds the ear stays: a warning keeps the ear (`EarHost`).
    func testAWarningLetsTheModelGoAndAnEmptyServiceEnds() async throws {
        let exits = Exits()
        let (client, _, gauge, _) = served(endsWhenEmptyAfter: 0.2, exits: exits)
        let ear = ServiceEar(name: "qwen3-asr-1.7b", folder: URL(fileURLWithPath: "/ears/q"), client: client, gate: MLXGate())
        try await ear.load()
        let model = editor(client)
        await model.prepare()
        await model.release(reason: "memory pressure")
        await eventually("the model let go in the service") { gauge.count("clear") == 1 }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(exits.all, [], "the ear is still held")
        ear.unload()
        await eventually("holding nothing, it ended") { exits.all == ["holds nothing"] }
    }

    /// Asked something while it waits to end, it does not end.
    func testAServiceAskedAgainBeforeItEndsStays() async throws {
        let exits = Exits()
        let (client, _, _, _) = served(endsWhenEmptyAfter: 0.4, exits: exits)
        var model: ServiceLanguageModel? = try await client.loadLanguageModel(LanguageModelSpec(directory: "/m", label: "s"))
        model = nil
        try await Task.sleep(for: .milliseconds(200))
        model = try await client.loadLanguageModel(LanguageModelSpec(directory: "/m", label: "s"))
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(exits.all, [])
        XCTAssertNotNil(model)
    }

    /// An unload that overtakes an ear's load lets the loaded ear go when
    /// it lands, rather than hold it for no one.
    func testAnUnloadThatOvertakesAnEarLoadLetsItGo() throws {
        let gauge = Gauge()
        gauges.append(gauge)
        let service = ModelsService(engine: FakeEngine(gauge: gauge, earLoadParks: true), gate: MLXGate(),
                                    endsWhenEmptyAfter: nil)
        let landed = expectation(description: "the load answered")
        let body = try XCTUnwrap(Models.encode(EarLoad(id: 1, spec: EarSpec(name: "qwen3-asr-1.7b", directory: "/q"))))
        service.loadEar(body) { data in
            XCTAssertEqual(Models.decode(ModelsReply<Bool>.self, from: data)?.failure, .cancelled)
            landed.fulfill()
        }
        let deadline = Date().addingTimeInterval(5)
        while gauge.parkedCount == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        service.unloadEar()
        gauge.unpark()
        wait(for: [landed], timeout: 5)
        XCTAssertEqual(gauge.count("unload ear"), 1, "the late ear was let go")
        let stats = expectation(description: "stats")
        service.stats { data in
            XCTAssertEqual(Models.decode(ModelsStats.self, from: data)?.ear, false)
            stats.fulfill()
        }
        wait(for: [stats], timeout: 5)
    }
}
