import AppKit
import LodestarCore
import XCTest
@testable import lodestar

/// When the editor's weights are in memory and when they are not: a release
/// asked for while they load, an engine changed while they load, and a
/// memory warning that must keep every road to the model shut, the
/// dictation's and the draft's as well as the field's. The loader is a
/// script, so no weights are read, and the lane is the test's own.
final class ModelResidencyTests: XCTestCase {
    /// A backend that says which engine it was loaded for.
    private struct Tagged: EditorBackend {
        let engine: EditorEngine
        func respond(to sentence: String, instructions: String) async throws -> String {
            "\(engine.rawValue): \(sentence)"
        }
        func rewrite(_ text: String, prompt: IntentPass.Prompt) async throws -> String {
            "\(engine.rawValue): \(text)"
        }
    }

    /// The loader's ledger: what was asked to load, and which engines' loads
    /// wait at the door until the test opens it.
    private final class Loads: @unchecked Sendable {
        private let lock = NSLock()
        private var _entered: [EditorEngine] = []
        private var parked: Set<EditorEngine>
        private var waiting: [EditorEngine: [CheckedContinuation<Void, Never>]] = [:]
        private var inside = 0
        private var _mostInside = 0
        init(parking engines: Set<EditorEngine> = []) { parked = engines }
        var entered: [EditorEngine] { lock.withLock { _entered } }
        /// The most loads under way at one moment.
        var mostInside: Int { lock.withLock { _mostInside } }
        func park(_ engine: EditorEngine) { lock.withLock { _ = parked.insert(engine) } }
        func count(_ engine: EditorEngine) -> Int { lock.withLock { _entered.filter { $0 == engine }.count } }
        var total: Int { lock.withLock { _entered.count } }

        func load(_ engine: EditorEngine) async -> any EditorBackend {
            let wait = lock.withLock { () -> Bool in
                _entered.append(engine)
                inside += 1
                _mostInside = max(_mostInside, inside)
                return parked.contains(engine)
            }
            defer { lock.withLock { inside -= 1 } }
            if wait {
                await withCheckedContinuation { continuation in
                    let through = lock.withLock { () -> Bool in
                        if parked.contains(engine) { waiting[engine, default: []].append(continuation) }
                        return !parked.contains(engine)
                    }
                    if through { continuation.resume() }
                }
            }
            return Tagged(engine: engine)
        }

        func open(_ engine: EditorEngine) {
            let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                parked.remove(engine)
                defer { waiting[engine] = [] }
                return waiting[engine] ?? []
            }
            all.forEach { $0.resume() }
        }
    }

    /// Time, which a test moves. Nothing is scheduled on it: the run loop
    /// is not pumped from inside an async test, so the moving is only of
    /// what `now` says.
    final class TestTime: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = Date()
        var now: Date { lock.withLock { _now } }
        func advance(by seconds: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(seconds) } }
        var clock: Clock { Clock(now: { [self] in now }, after: { _, _ in }) }
    }

    private final class Clears: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func note() { lock.withLock { _count += 1 } }
    }

    private func model(_ loads: Loads, engine: EditorEngine = .standard, clears: Clears? = nil,
                       clock: TestTime? = nil) -> EditorModel {
        return EditorModel(engine: engine, idleRelease: 3600, answerDeadline: 8, gateWait: 3, loadDeadline: 60,
                           stuckAfter: 20, gate: MLXGate(),
                           loader: { engine in await loads.load(engine) },
                           clearCache: { clears?.note() },
                           holdClock: { clock?.now ?? Date() },
                           memoryLevel: { .normal })
    }

    private let prompt = IntentPass.Prompt(instructions: "", examples: [])

    /// Waits, in real time, for something an unstructured task does.
    private func eventually(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("never: \(what)")
    }

    /// Real time for a task started from the main actor to reach the model
    /// and for the model to act on it. A road that is shut shows nothing
    /// happening, so the only way to see it is to wait out a window.
    private func window() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    // MARK: - A release during a load

    /// The weights are 20 GB. A release that arrives while they load must
    /// still mean they are not kept: the load finishes, and nothing holds
    /// the result.
    @MainActor func testAReleaseDuringALoadLeavesTheWeightsUnloaded() async {
        let loads = Loads(parking: [.standard])
        let model = model(loads)
        let loading = Task { await model.prepare() }
        await eventually("the load begins") { loads.count(.standard) == 1 }
        await model.release(reason: "memory pressure")
        loads.open(.standard)
        await loading.value
        let state = await model.state
        XCTAssertEqual(state, .unloaded, "the release was asked for while the weights loaded")
        let kept = await model.rewrite("Their going.", prompt: prompt)
        XCTAssertNil(kept, "and the model holds no backend to answer with")
    }

    /// A sentence waiting on that load is not left without an answer or a
    /// hang, and the release still stands.
    @MainActor func testAReleaseDuringALoadStillLetsTheQuestionsWaitingOnItReturn() async {
        let loads = Loads(parking: [.standard])
        let model = model(loads)
        let asking = Task { await model.correct("Their going.") }
        await eventually("the load begins") { loads.count(.standard) == 1 }
        await model.release(reason: "memory pressure")
        loads.open(.standard)
        let answer = await asking.value
        XCTAssertNil(answer, "a question that waited before the release gets nothing from the load")
        let state = await model.state
        XCTAssertEqual(state, .unloaded)
        XCTAssertEqual(model.ability, .able, "a load nobody wanted is not a model that cannot answer")
    }

    /// The weights that were loaded and dropped are really gone: the cache
    /// they filled is cleared, as a release of a loaded model clears it.
    func testWeightsThatLoadedUnwantedHaveTheirCacheCleared() async {
        let loads = Loads(parking: [.standard])
        let clears = Clears()
        let model = model(loads, clears: clears)
        let loading = Task { await model.prepare() }
        await eventually("the load begins") { loads.count(.standard) == 1 }
        await model.release(reason: "memory pressure")
        XCTAssertEqual(clears.count, 0, "nothing to clear while they load")
        loads.open(.standard)
        await loading.value
        await eventually("the cache is cleared") { clears.count == 1 }
    }

    func testWeightsOfAnEngineChangedAwayFromHaveTheirCacheCleared() async {
        let loads = Loads(parking: [.standard])
        let clears = Clears()
        let model = model(loads, clears: clears)
        let loading = Task { await model.prepare() }
        await eventually("the load begins") { loads.count(.standard) == 1 }
        await model.setEngine(.full)
        loads.open(.standard)
        await loading.value
        await eventually("the cache is cleared") { clears.count == 1 }
        let state = await model.state
        XCTAssertEqual(state, .unloaded, "no load is left standing as loading")
    }

    func testMinimalHoldsNoMLXMemoryToClearWhenDropped() async {
        let loads = Loads(parking: [.minimal])
        let clears = Clears()
        let model = model(loads, engine: .minimal, clears: clears)
        let loading = Task { await model.prepare() }
        await eventually("the load begins") { loads.count(.minimal) == 1 }
        await model.release(reason: "memory pressure")
        loads.open(.minimal)
        await loading.value
        await window()
        XCTAssertEqual(clears.count, 0)
    }

    /// A load nobody wanted that fails is nothing the hand should hear of.
    func testAnUnwantedLoadThatFailsIsNotAFailure() async {
        let gate = MLXGate()
        let latch = Loads(parking: [.standard])
        let model = EditorModel(engine: .standard, idleRelease: 3600, answerDeadline: 8, gateWait: 3, loadDeadline: 60,
                                stuckAfter: 20, gate: gate,
                                loader: { engine in
                                    _ = await latch.load(engine)
                                    throw EditorModelError.missing(engine)
                                },
                                clearCache: {}, memoryLevel: { .normal })
        let loading = Task { await model.prepare() }
        await eventually("the load begins") { latch.count(.standard) == 1 }
        await model.release(reason: "memory pressure")
        latch.open(.standard)
        await loading.value
        let state = await model.state
        XCTAssertEqual(state, .unloaded)
        XCTAssertEqual(model.ability, .able)
    }

    /// A question for the same engine after a release, with no hold, wants
    /// the load that is still running again: one load, one copy, kept.
    func testAQuestionAfterAReleaseWantsTheRunningLoadAgain() async {
        let loads = Loads(parking: [.standard])
        let model = model(loads)
        let loading = Task { await model.prepare() }
        await eventually("the load begins") { loads.count(.standard) == 1 }
        await model.release(reason: "idle")
        let asking = Task { await model.correct("Their going.") }
        await window()
        loads.open(.standard)
        let answer = await asking.value
        await loading.value
        XCTAssertEqual(answer, "standard: Their going.")
        XCTAssertEqual(loads.entered, [.standard], "a second copy of the weights never began to load")
        let state = await model.state
        XCTAssertEqual(state, .ready)
    }

    /// With a hold standing, the same question wants nothing.
    func testAQuestionAfterAReleaseDuringAHoldDoesNotWantTheLoadAgain() async {
        let clock = TestTime()
        let loads = Loads(parking: [.standard])
        let model = model(loads, clock: clock)
        let loading = Task { await model.prepare() }
        await eventually("the load begins") { loads.count(.standard) == 1 }
        model.memoryHold.pressed(at: clock.now)
        await model.release(reason: "memory pressure")
        let answer = await model.correct("Their going.")
        XCTAssertNil(answer)
        loads.open(.standard)
        await loading.value
        let state = await model.state
        XCTAssertEqual(state, .unloaded)
        XCTAssertEqual(loads.entered, [.standard])
    }

    // MARK: - The engine changes during a load

    /// A question asked after the engine changed is the new engine's, never
    /// the old one's, even when the old one's load is still under way.
    @MainActor func testAQuestionAfterAnEngineChangeIsNotAnsweredByTheOldEngine() async {
        let loads = Loads(parking: [.standard])
        let model = model(loads)
        let loading = Task { await model.prepare() }
        await eventually("the first load begins") { loads.count(.standard) == 1 }
        await model.setEngine(.full)
        let asking = Task { await model.correct("Their going.") }
        // The question reaches the model while the old load is still out.
        await window()
        loads.open(.standard)
        let answer = await asking.value
        await loading.value
        XCTAssertNotEqual(answer, "standard: Their going.", "the standard model answered a question put to Full")
        XCTAssertEqual(answer, "full: Their going.")
    }

    /// Questions for another engine wait for the load that is running to
    /// end and then share one load of their own: two never run at once, and
    /// nothing spins on a task that has ended.
    func testQuestionsForAnotherEngineWaitForTheRunningLoadAndShareOne() async {
        let loads = Loads(parking: [.standard])
        let model = model(loads)
        let loading = Task { await model.prepare() }
        await eventually("the first load begins") { loads.count(.standard) == 1 }
        await model.setEngine(.full)
        let asking = (0..<3).map { number in Task { await model.correct("Their going \(number).") } }
        await window()
        XCTAssertEqual(loads.entered, [.standard], "Full waits for the load that is running")
        loads.open(.standard)
        var answers: [String?] = []
        for question in asking { answers.append(await question.value) }
        await loading.value
        XCTAssertEqual(answers, (0..<3).map { "full: Their going \($0)." })
        XCTAssertEqual(loads.entered, [.standard, .full], "one load for Full, shared")
        XCTAssertEqual(loads.mostInside, 1, "never two loads at once")
    }

    // MARK: - Roads to the weights during a hold

    /// The shared proofreader, the editor's controller beside it, and the
    /// draft's editor, wired as the app wires them: one model for all.
    private final class World {
        let loads: Loads
        let model: EditorModel
        let clock = TestTime()
        let source = FakeFieldSource()
        let controller: EditorController

        init(_ loads: Loads = Loads(), test: ModelResidencyTests) {
            self.loads = loads
            model = test.model(loads, clock: clock)
            controller = EditorController(source: source, queue: DispatchQueue(label: "test.residency.ax"),
                                          proofreader: model, drawing: FakeMarksDrawing(), hover: nil,
                                          clock: clock.clock, polls: false, modelReady: { $0.usesModel },
                                          memoryLevel: { .normal })
            controller.frontmostApp = { (4242, "com.apple.TextEdit", "TextEdit") }
            controller.apply(enabled: true, engine: .standard, language: "en_US", vocabulary: [], skipApps: [])
        }

        /// The hand typed a finished sentence and paused: a few beats, each
        /// giving the model's question time to be asked.
        func type(_ text: String) async {
            let field = EditorRig.field(text)
            source.field = field
            for _ in 0..<6 {
                clock.advance(by: 2)
                controller.receive(source.field)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// Dictation starts with the ear warm: the language model it asks is the
    /// editor's, and `EarHost` has the editor's copy prepared. The closure is
    /// the one `main.swift` hands `prepareShared`.
    private func dictate(_ world: World) -> EarHost {
        let host = EarHost(clock: world.clock.clock)
        host.hasCleanup = { _ in true }
        host.install(ear: SlowEar(loaded: true), tier: .max)
        host.sharesEditor = { _ in true }
        let proofreader = world.controller.proofreader
        host.prepareShared = { Task { await proofreader.prepare() } }
        host.warm()
        return host
    }

    @MainActor func testDictationStartingDuringAHoldDoesNotLoadTheWeights() async {
        let world = World(test: self)
        world.controller.memoryPressure()
        await window()
        _ = dictate(world)
        await window()
        XCTAssertEqual(world.loads.entered, [], "warm() reached prepare() and the weights loaded in the middle of the hold")
    }

    @MainActor func testDictationStartingWithNoHoldLoadsTheWeights() async {
        let world = World(test: self)
        _ = dictate(world)
        await eventually("the weights load") { world.loads.count(.standard) == 1 }
    }

    @MainActor func testTheDraftsEditorReadingASentenceDuringAHoldDoesNotLoadTheWeights() async {
        let world = World(test: self)
        world.controller.memoryPressure()
        await window()
        let editor = DraftEditor(proofreader: world.model, clock: world.clock.clock)
        editor.apply(enabled: true, engine: .standard, language: "en_US", vocabulary: [], modelReady: true)
        let text = "Their going to push it."
        _ = editor.textChanged(text, caret: (text as NSString).length, ghost: false)
        await window()
        XCTAssertEqual(world.loads.entered, [], "drain() asked the model for a sentence and the weights loaded in the middle of the hold")
        withExtendedLifetime(editor) {}
    }

    @MainActor func testTheDraftsEditorReadingASentenceWithNoHoldLoadsTheWeights() async {
        let world = World(test: self)
        let editor = DraftEditor(proofreader: world.model, clock: world.clock.clock)
        editor.apply(enabled: true, engine: .standard, language: "en_US", vocabulary: [], modelReady: true)
        let text = "Their going to push it."
        _ = editor.textChanged(text, caret: (text as NSString).length, ghost: false)
        await eventually("the weights load") { world.loads.count(.standard) == 1 }
        withExtendedLifetime(editor) {}
    }

    /// The road that already keeps to the hold, for the rig's sake: the
    /// field's own typing, with the same controller and the same model.
    @MainActor func testTypingInAFieldDuringAHoldDoesNotLoadTheWeights() async {
        let world = World(test: self)
        world.controller.memoryPressure()
        await window()
        await world.type("Their going to push it.")
        XCTAssertEqual(world.loads.entered, [])
    }

    @MainActor func testTypingInAFieldWithNoHoldLoadsTheWeights() async {
        let world = World(test: self)
        await world.type("Their going to push it.")
        await eventually("the weights load") { world.loads.count(.standard) == 1 }
    }

    // MARK: - The hold is the model's

    /// Whatever asks, the weights stay away; a nil from the hold is not a
    /// failure; a backend already here still answers.
    func testNothingLoadsTheWeightsDuringAHold() async {
        let clock = TestTime()
        let loads = Loads()
        let model = model(loads, clock: clock)
        model.memoryHold.pressed(at: clock.now)
        await model.prepare()
        let answer = await model.correct("Their going.")
        XCTAssertNil(answer)
        XCTAssertEqual(loads.entered, [])
        let state = await model.state
        XCTAssertEqual(state, .unloaded, "waiting is not failing")
        XCTAssertEqual(model.ability, .able)
        clock.advance(by: ModelHold.quiet)
        let later = await model.correct("Their going.")
        XCTAssertEqual(later, "standard: Their going.", "and once the hold is over, the weights load")
        XCTAssertEqual(loads.entered, [.standard])
    }

    func testABackendAlreadyLoadedAnswersDuringAHold() async {
        let clock = TestTime()
        let loads = Loads()
        let model = model(loads, clock: clock)
        await model.prepare()
        model.memoryHold.pressed(at: clock.now)
        let answer = await model.correct("Their going.")
        XCTAssertEqual(answer, "standard: Their going.")
        XCTAssertEqual(loads.entered, [.standard])
    }

    /// The log says when the wait starts and when it ends, not per question.
    func testTheHoldSaysItsStartAndItsEndOnce() {
        final class Lines: @unchecked Sendable {
            private let lock = NSLock()
            private var all: [String] = []
            func add(_ line: String) { lock.withLock { all.append(line) } }
            var held: [String] { lock.withLock { all.filter { $0.contains("editor held=") } } }
        }
        let lines = Lines()
        Log.listener = { lines.add($0) }
        defer { Log.listener = nil }
        let hold = EditorHold()
        let start = Date()
        hold.pressed(at: start)
        for _ in 0..<5 { XCTAssertTrue(hold.holds(at: start.addingTimeInterval(1), level: .normal)) }
        for _ in 0..<5 { XCTAssertFalse(hold.holds(at: start.addingTimeInterval(ModelHold.quiet), level: .normal)) }
        let said = lines.held
        XCTAssertEqual(said.count, 2, "\(said)")
        XCTAssertTrue(said.first?.contains("memory pressure") == true, "\(said)")
        XCTAssertTrue(said.last?.contains("over") == true, "\(said)")
    }

    /// A sentence the draft asked as the warning came is not answered, and
    /// not recorded as unanswered: after the third such warning a recorded
    /// one would never be asked again, and it is asked once the hold is over.
    @MainActor func testAHeldQuestionIsNotRecordedAsUnansweredByTheDraft() async {
        let loads = Loads()
        let world = World(loads, test: self)
        let editor = DraftEditor(proofreader: world.model, clock: world.clock.clock, memoryLevel: { .normal })
        editor.apply(enabled: true, engine: .standard, language: "en_US", vocabulary: [], modelReady: true)
        let text = "Their going to push it."
        let caret = (text as NSString).length
        for round in 1...3 {
            loads.park(.standard)
            _ = editor.textChanged(text, caret: caret, ghost: false)
            await eventually("round \(round): the load begins") { loads.count(.standard) == round }
            world.controller.memoryPressure()
            await window()
            loads.open(.standard)
            await window()
            world.clock.advance(by: ModelHold.quiet)
        }
        _ = editor.textChanged(text, caret: caret, ghost: false)
        await eventually("asked once the hold was over") { loads.count(.standard) == 4 }
        withExtendedLifetime(editor) {}
    }

    /// The field's editor too: three held questions are not three
    /// unanswered ones, and the hand is not told grammar checking paused.
    @MainActor func testAHeldQuestionIsNotCountedAsSilenceByTheField() async {
        let loads = Loads()
        let world = World(loads, test: self)
        var flashes: [String] = []
        world.controller.flash = { flashes.append($0) }
        for round in 1...EditorController.silentAfter {
            loads.park(.standard)
            await world.type("Their going to push change \(round).")
            await eventually("round \(round): the load begins") { loads.count(.standard) >= round }
            world.controller.memoryPressure()
            await window()
            loads.open(.standard)
            await window()
            world.clock.advance(by: ModelHold.quiet)
        }
        XCTAssertEqual(flashes, [], "held away is not silent")
    }

    // MARK: - The editor's own controller

    /// Memory pressure and switching the editor off both release while a
    /// load may be under way: typing has just started the early load.
    @MainActor func testMemoryPressureDuringTheEarlyLoadLeavesTheWeightsUnloaded() async {
        let loads = Loads(parking: [.standard])
        let world = World(loads, test: self)
        let early = Task { await world.model.prepare() }
        await eventually("the early load begins") { loads.count(.standard) == 1 }
        world.controller.memoryPressure()
        await window()
        loads.open(.standard)
        await early.value
        let state = await world.model.state
        XCTAssertEqual(state, .unloaded, "the warning came while the weights loaded, and they were kept")
    }

    @MainActor func testSwitchingTheEditorOffDuringTheEarlyLoadLeavesTheWeightsUnloaded() async {
        let loads = Loads(parking: [.standard])
        let world = World(loads, test: self)
        let early = Task { await world.model.prepare() }
        await eventually("the early load begins") { loads.count(.standard) == 1 }
        world.controller.apply(enabled: false, engine: .standard, language: "en_US", vocabulary: [], skipApps: [])
        await window()
        loads.open(.standard)
        await early.value
        let state = await world.model.state
        XCTAssertEqual(state, .unloaded, "the editor went off while the weights loaded, and they were kept")
    }
}
