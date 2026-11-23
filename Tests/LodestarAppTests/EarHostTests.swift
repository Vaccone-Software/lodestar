import Stoic
import StoicTesting
import XCTest
@testable import lodestar
@testable import LodestarEars
import LodestarCore

/// An ear that is cold until told its load is done, and says when it was
/// let go.
final class SlowEar: SettlingEar, @unchecked Sendable {
    let name = "slow"
    private let lock = NSLock()
    private var _loaded: Bool
    private var _unloads = 0
    private var waiting: CheckedContinuation<Void, Never>?
    private var opened = false
    private var _fails = false
    private var _whenLoading: (@Sendable () -> Void)?
    init(loaded: Bool = false) { _loaded = loaded }
    /// Runs as the load begins, in whatever context the load was started in.
    func whenLoading(_ body: @escaping @Sendable () -> Void) { lock.withLock { _whenLoading = body } }
    var isLoaded: Bool { lock.withLock { _loaded } }
    var unloads: Int { lock.withLock { _unloads } }
    /// The next load throws instead of finishing.
    func failTheLoad() { lock.withLock { _fails = true } }
    /// The load in flight finishes (or one not yet begun will not wait).
    func finishLoading() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            opened = true
            defer { waiting = nil }
            return waiting
        }
        waiter?.resume()
    }
    func load() async throws {
        lock.withLock { _whenLoading }?()
        await withCheckedContinuation { continuation in
            let through = lock.withLock { () -> Bool in
                if !opened { waiting = continuation }
                return opened
            }
            if through { continuation.resume() }
        }
        if lock.withLock({ _fails }) { throw NSError(domain: "SlowEar", code: 1) }
        lock.withLock { _loaded = true }
    }
    func unload() { lock.withLock { _loaded = false; _unloads += 1 } }
    func transcribe(_ samples: [Float], context: [String]) async throws -> Heard { Heard("") }
}

/// An ear that hears every phrase as `words`, and counts its loads.
final class WordsEar: SettlingEar, @unchecked Sendable {
    let name: String
    private let words: String
    private let lock = NSLock()
    private var _loaded: Bool
    private var _loads = 0
    private var _context: [String] = []
    init(_ name: String, hears words: String, loaded: Bool = true) {
        self.name = name; self.words = words; _loaded = loaded
    }
    var isLoaded: Bool { lock.withLock { _loaded } }
    var loads: Int { lock.withLock { _loads } }
    var context: [String] { lock.withLock { _context } }
    func load() async throws { lock.withLock { _loaded = true; _loads += 1 } }
    func unload() { lock.withLock { _loaded = false } }
    func transcribe(_ samples: [Float], context: [String]) async throws -> Heard {
        lock.withLock { _context = context }
        return Heard(words)
    }
}

/// A language model backend that is loaded on the test's say-so, and
/// remembers that it was asked to.
private final class Loads: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func note() { lock.withLock { _count += 1 } }
}

/// Holds whoever reaches it until it is opened.
private final class Door: @unchecked Sendable {
    private let lock = NSLock()
    private var opened: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(opened: Bool = false) { self.opened = opened }
    /// How many wait at it now.
    var held: Int { lock.withLock { waiting.count } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let through = lock.withLock { () -> Bool in
                if !opened { waiting.append(continuation) }
                return opened
            }
            if through { continuation.resume() }
        }
    }
    func open() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            defer { waiting = [] }
            return waiting
        }
        all.forEach { $0.resume() }
    }
}

/// Which pieces ran, in what order, and the most inside at one moment.
private final class Ledger: @unchecked Sendable {
    private let lock = NSLock()
    private var _order: [Int] = []
    private var inside = 0
    private var _mostInside = 0
    var order: [Int] { lock.withLock { _order } }
    var mostInside: Int { lock.withLock { _mostInside } }
    func enter() { lock.withLock { inside += 1; _mostInside = max(_mostInside, inside) } }
    func leave(_ piece: Int) { lock.withLock { inside -= 1; _order.append(piece) } }
}

/// Language model weights that say how many are in memory.
private final class Weights: @unchecked Sendable {
    private final class Loaded: EditorBackend, @unchecked Sendable {
        private let ledger: Weights
        init(_ ledger: Weights) { self.ledger = ledger }
        deinit { ledger.lock.withLock { ledger._alive -= 1 } }
        func respond(to sentence: String, instructions: String) async throws -> String { sentence }
        func rewrite(_ text: String, prompt: IntentPass.Prompt) async throws -> String { text }
    }
    private let lock = NSLock()
    private var _made = 0
    private var _alive = 0
    var made: Int { lock.withLock { _made } }
    var alive: Int { lock.withLock { _alive } }
    func make() -> any EditorBackend {
        lock.withLock { _made += 1; _alive += 1 }
        return Loaded(self)
    }
}

private struct Quiet: EditorBackend {
    func respond(to sentence: String, instructions: String) async throws -> String { sentence }
    func rewrite(_ text: String, prompt: IntentPass.Prompt) async throws -> String { text }
}

/// How long the ear and the model are kept, and the order they load in.
final class EarHostTests: XCTestCase {
    private let clock = VirtualClock()

    private func host(ear: SlowEar, loads: Loads) -> (EarHost, DraftModel) {
        let host = EarHost(clock: clock.clock)
        let model = DraftModel(model: .qwen36, loader: { _ in loads.note(); return Quiet() }, clearCache: {})
        host.hasCleanup = { _ in true }
        host.install(ear: ear, tier: .max, model: model)
        return (host, model)
    }

    private func pump(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { Stage.pump() }
        XCTAssertTrue(condition(), "still waiting after 5 s")
    }

    // MARK: - How long it stays

    func testTheEarStaysThirtyMinutesAndTheModelFive() async {
        XCTAssertEqual(EarHost.idleSeconds, 30 * 60)
        XCTAssertEqual(EarHost.modelIdleSeconds, 5 * 60)
        let ear = SlowEar(loaded: true)
        let loads = Loads()
        let (host, model) = host(ear: ear, loads: loads)
        host.warm()
        pump(until: { loads.count == 1 })
        await model.load()
        host.rest()
        clock.advance(by: 4 * 60)
        let early = await model.isLoaded
        XCTAssertTrue(early, "the model is held through its five minutes")
        clock.advance(by: 90)
        pump(until: { true })
        try? await Task.sleep(nanoseconds: 50_000_000)
        let later = await model.isLoaded
        XCTAssertFalse(later, "and let go after them")
        XCTAssertTrue(ear.isLoaded, "the ear is still warm at six minutes")
        clock.advance(by: 20 * 60)
        XCTAssertTrue(ear.isLoaded, "and at twenty-six")
        clock.advance(by: 5 * 60)
        XCTAssertFalse(ear.isLoaded, "gone after thirty")
        XCTAssertEqual(ear.unloads, 1)
    }

    func testADraftOpeningAgainKeepsTheEar() {
        let ear = SlowEar(loaded: true)
        let (host, _) = host(ear: ear, loads: Loads())
        host.warm()
        host.rest()
        clock.advance(by: 29 * 60)
        host.warm()
        host.rest()
        clock.advance(by: 29 * 60)
        XCTAssertTrue(ear.isLoaded, "the clock starts again at each close")
        clock.advance(by: 2 * 60)
        XCTAssertFalse(ear.isLoaded)
    }

    // MARK: - The ear behind

    /// The quick ear loads first and the ear behind it after, each heard
    /// with the moment it is in; the language model waits for both.
    func testTheEarBehindLoadsAfterTheQuickOne() {
        let quick = SlowEar()
        let behind = SlowEar()
        let loads = Loads()
        let host = EarHost(clock: clock.clock)
        host.hasCleanup = { _ in true }
        host.install(ear: quick, behind: behind, tier: .max,
                     model: DraftModel(model: .qwen36, loader: { _ in loads.note(); return Quiet() }, clearCache: {}))
        var told = 0
        host.loaded = { told += 1 }
        host.warm()
        behind.finishLoading()
        pump(until: { true })
        XCTAssertFalse(behind.isLoaded, "not before the quick ear")
        quick.finishLoading()
        pump(until: { behind.isLoaded && loads.count == 1 })
        XCTAssertEqual(told, 2, "each ear says when it is in")
    }

    /// A warning lets the ear behind go with the language model; the quick
    /// ear, which ⏎ waits for, stays.
    func testAWarningLetsTheEarBehindGoAndKeepsTheQuickOne() {
        let quick = SlowEar(loaded: true)
        let behind = SlowEar(loaded: true)
        let host = EarHost(clock: clock.clock)
        host.install(ear: quick, behind: behind, tier: .full)
        host.warm()
        host.rest()
        host.memoryWarning()
        XCTAssertFalse(behind.isLoaded)
        XCTAssertTrue(quick.isLoaded)
        clock.advance(by: 31 * 60)
        XCTAssertFalse(quick.isLoaded, "and both go after thirty minutes")
    }

    // MARK: - Memory pressure

    func testMemoryPressureLetsAGoneRestingEarGoAtOnce() {
        let ear = SlowEar(loaded: true)
        let (host, _) = host(ear: ear, loads: Loads())
        host.warm()
        host.rest()
        clock.advance(by: 60)
        host.memoryPressure()
        XCTAssertFalse(ear.isLoaded)
        clock.advance(by: 40 * 60)
        XCTAssertEqual(ear.unloads, 1, "and the idle release finds nothing more to do")
    }

    func testMemoryPressureWhileDictatingWaitsForTheDraftToClose() {
        let ear = SlowEar(loaded: true)
        let (host, _) = host(ear: ear, loads: Loads())
        host.warm()
        host.memoryPressure()
        XCTAssertTrue(ear.isLoaded, "not mid-sentence")
        host.rest()
        XCTAssertFalse(ear.isLoaded, "the moment the draft closes")
    }

    // MARK: - Memory and the language model

    /// Is the model let go? The release runs on the model's actor, so a
    /// moment after the signal rather than inside it.
    private func settleReleased(_ model: DraftModel, file: StaticString = #filePath, line: UInt = #line) async {
        let until = Date().addingTimeInterval(EditorRig.patience)
        while await model.isLoaded {
            guard Date() < until else { XCTFail("the model stayed", file: file, line: line); return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// `warm` starts the model's load on a task of its own, and on a slow
    /// machine that task may not have run yet. Its load is the one waited
    /// for: a second load here could finish first and leave it to arrive
    /// after the release.
    private func settleLoaded(_ model: DraftModel, file: StaticString = #filePath, line: UInt = #line) async {
        let until = Date().addingTimeInterval(EditorRig.patience)
        while await !model.isLoaded {
            guard Date() < until else { XCTFail("the model never loaded", file: file, line: line); return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func testAWarningLetsTheRestingModelGoAndKeepsTheEar() async {
        let ear = SlowEar(loaded: true)
        let (host, model) = host(ear: ear, loads: Loads())
        await model.load()
        host.rest()
        host.memoryWarning()
        await settleReleased(model)
        XCTAssertTrue(ear.isLoaded, "the ear waits for critical")
        XCTAssertEqual(ear.unloads, 0)
    }

    func testAWarningWhileDictatingWaitsForTheDraftToClose() async {
        let ear = SlowEar(loaded: true)
        let (host, model) = host(ear: ear, loads: Loads())
        host.warm()
        await settleLoaded(model)
        host.memoryWarning()
        let during = await model.isLoaded
        XCTAssertTrue(during, "not mid-sentence")
        host.rest()
        await settleReleased(model)
        XCTAssertTrue(ear.isLoaded)
    }

    func testAWarningWithNothingLoadedAsksNothing() async {
        let ear = SlowEar(loaded: true)
        let loads = Loads()
        let (host, model) = host(ear: ear, loads: loads)
        host.rest()
        host.memoryWarning()
        let loaded = await model.isLoaded
        XCTAssertFalse(loaded)
        XCTAssertEqual(loads.count, 0)
    }

    func testCriticalLetsTheRestingModelGoToo() async {
        let ear = SlowEar(loaded: true)
        let (host, model) = host(ear: ear, loads: Loads())
        await model.load()
        host.rest()
        host.memoryPressure()
        await settleReleased(model)
        XCTAssertFalse(ear.isLoaded)
    }

    func testCriticalWhileDictatingLetsTheModelGoWhenTheDraftCloses() async {
        let ear = SlowEar(loaded: true)
        let (host, model) = host(ear: ear, loads: Loads())
        host.warm()
        await settleLoaded(model)
        host.memoryPressure()
        let during = await model.isLoaded
        XCTAssertTrue(during, "not mid-sentence")
        host.rest()
        await settleReleased(model)
    }

    /// The next draft is not left to find a stale signal: nothing was
    /// pressed once the last draft's close answered it.
    func testTheSignalIsAnsweredOnce() async {
        let ear = SlowEar(loaded: true)
        let (host, model) = host(ear: ear, loads: Loads())
        host.warm()
        await settleLoaded(model)
        host.memoryWarning()
        host.rest()
        await settleReleased(model)
        host.warm()
        await settleLoaded(model)
        host.rest()
        let after = await model.isLoaded
        XCTAssertTrue(after, "this draft's close is not the warning's")
    }

    // MARK: - The order of loading

    func testTheModelLoadsOnlyAfterTheEar() {
        let ear = SlowEar()
        let loads = Loads()
        let (host, _) = host(ear: ear, loads: loads)
        var announced = 0
        host.loaded = { announced += 1 }
        host.warm()
        host.warm()
        for _ in 0..<50 { Stage.pump() }
        XCTAssertEqual(loads.count, 0, "the 1.7B ear has the disk to itself")
        ear.finishLoading()
        pump(until: { loads.count == 1 })
        XCTAssertTrue(ear.isLoaded)
        XCTAssertEqual(announced, 1, "a second start while it loaded did not load it twice")
    }

    func testTheModelLoadsEvenIfTheEarFailed() {
        let ear = SlowEar()
        ear.failTheLoad()
        let loads = Loads()
        let (host, _) = host(ear: ear, loads: loads)
        var announced = 0
        host.loaded = { announced += 1 }
        host.warm()
        ear.finishLoading()
        pump(until: { loads.count == 1 })
        XCTAssertEqual(announced, 0, "nothing to hear with")
    }

    func testAWarmEarLetsTheModelStartAtOnce() {
        let loads = Loads()
        let (host, _) = host(ear: SlowEar(loaded: true), loads: loads)
        host.warm()
        pump(until: { loads.count == 1 })
    }

    // MARK: - In the order they were asked

    /// A model whose loads wait at the door, and its host with a warm ear.
    private func doored(_ door: Door, weights: Weights) -> EarHost {
        let host = EarHost(clock: clock.clock)
        let model = DraftModel(model: .qwen36, loader: { _ in
            await door.wait()
            return weights.make()
        }, clearCache: {})
        host.hasCleanup = { _ in true }
        host.install(ear: SlowEar(loaded: true), tier: .max, model: model)
        return host
    }

    /// The load brought its weights in, and they were let go. Counted in the
    /// weights themselves, so a release that came too soon to find any, and
    /// left them, cannot pass for one that let them go.
    private func settleLetGo(_ weights: Weights, file: StaticString = #filePath, line: UInt = #line) async {
        let until = Date().addingTimeInterval(EditorRig.patience)
        while weights.made == 0 || weights.alive > 0 {
            guard Date() < until else {
                XCTFail("made \(weights.made), still in memory \(weights.alive)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// A release asked while the model loads used to find nothing loaded and
    /// let nothing go, and the load then brought the weights in after the
    /// warning that asked for them back.
    func testAReleaseAskedDuringTheLoadLetsGoWhatItBrings() async {
        let door = Door()
        let weights = Weights()
        let host = doored(door, weights: weights)
        host.warm()
        pump(until: { door.held == 1 })
        host.rest()
        host.memoryWarning()
        door.open()
        await settleLetGo(weights)
    }

    /// The five minutes run out as a load is still on its way, and the same.
    func testTheIdleReleaseAskedDuringTheLoadLetsGoWhatItBrings() async {
        let door = Door()
        let weights = Weights()
        let host = doored(door, weights: weights)
        host.warm()
        pump(until: { door.held == 1 })
        host.rest()
        clock.advance(by: 5 * 60 + 1)
        door.open()
        await settleLetGo(weights)
    }

    /// The next draft's load comes after the release asked before it, however
    /// the tasks are scheduled.
    func testTheNextDraftsLoadFollowsTheReleaseBeforeIt() async {
        let weights = Weights()
        let host = doored(Door(opened: true), weights: weights)
        for draft in 1...50 {
            host.warm()
            await host.settled()
            host.rest()
            host.memoryWarning()
            host.warm()
            await host.settled()
            let loaded = await host.draftModel?.isLoaded
            XCTAssertEqual(loaded, true, "draft \(draft) lost its model to the last one's release")
            host.rest()
            host.memoryWarning()
            await host.settled()
        }
    }

    /// The tier's model is replaced while it loads: what the load brings is
    /// let go, not left in memory with nothing holding it.
    func testAModelReplacedDuringItsLoadIsLetGo() async {
        let door = Door()
        let weights = Weights()
        let host = doored(door, weights: weights)
        // Held here too, so it is the release that lets the weights go and
        // not the model's own end.
        let model = host.draftModel
        host.warm()
        pump(until: { door.held == 1 })
        host.sharesEditor = { _ in true }
        host.editorChanged()
        XCTAssertNil(host.draftModel, "the editor holds the same weights now")
        door.open()
        await settleLetGo(weights)
        withExtendedLifetime(model) {}
    }

    /// The pieces of a lane never overlap and never change places.
    func testALanesPiecesRunOneAtATimeInTheOrderAsked() async {
        let lane = ResidencyLane()
        let ran = Ledger()
        for piece in 0..<200 {
            lane.run(priority: piece.isMultiple(of: 2) ? .utility : .high) {
                ran.enter()
                await Task.yield()
                ran.leave(piece)
            }
        }
        await lane.settled()
        XCTAssertEqual(ran.order, Array(0..<200))
        XCTAssertEqual(ran.mostInside, 1)
    }

    // MARK: - The context the work starts in

    private func record(_ name: EventName) -> @Sendable () -> Void {
        { Ambient.current.instrumentation.record(Event(name, level: .info)) }
    }

    /// The ear loads off the main thread, in a task, and what Stoic says from
    /// there goes where the context that started it sends it: a detached task
    /// starts with none, and its events reached the unified log and not the
    /// app's own.
    func testTheEarLoadsInTheAmbientContextThatWarmedIt() {
        let ear = SlowEar()
        ear.whenLoading(record("test.ear_loading"))
        let (host, _) = host(ear: ear, loads: Loads())
        let events = RecordingInstrumentation()
        withAmbient({ $0.instrumentation = events }) { host.warm() }
        ear.finishLoading()
        pump(until: { events.names.contains("test.ear_loading") })
        XCTAssertEqual(events.names.filter { $0 == "test.ear_loading" }.count, 1)
    }

    /// The language model's load is the same: started by the ear being whole,
    /// from a task the ear's load started, it is in the same context.
    func testTheLanguageModelLoadsInTheAmbientContextThatWarmedTheEar() {
        let events = RecordingInstrumentation()
        let host = EarHost(clock: clock.clock)
        let loaded = Loads()
        let model = DraftModel(model: .qwen36, loader: { _ in
            loaded.note()
            Ambient.current.instrumentation.record(Event("test.model_loading", level: .info))
            return Quiet()
        }, clearCache: {})
        host.hasCleanup = { _ in true }
        host.install(ear: SlowEar(loaded: true), tier: .max, model: model)
        withAmbient({ $0.instrumentation = events }) { host.warm() }
        pump(until: { events.names.contains("test.model_loading") })
        XCTAssertEqual(loaded.count, 1)
    }

    // MARK: - Heard outside the draft (lodestar transcribe)

    private func heard(_ host: EarHost, context: [String] = []) -> (text: String, ear: String)? {
        var answer: (text: String, ear: String)?
        var finished = false
        host.hear([Float](repeating: 0, count: 16_000), context: context) { result in
            if case .success(let heard) = result { answer = (heard.heard.text, heard.ear) }
            finished = true
        }
        pump(until: { finished })
        return answer
    }

    /// The words dictation keeps come from the ear behind when the setup
    /// has one: so do a file's.
    func testAFileIsHeardByTheEarDictationKeeps() {
        let quick = WordsEar("parakeet", hears: "private link")
        let behind = WordsEar("qwen", hears: "PrivateLink")
        let host = EarHost(clock: clock.clock)
        host.install(ear: quick, behind: behind, tier: .full)
        let answer = heard(host, context: ["PrivateLink"])
        XCTAssertEqual(answer?.text, "PrivateLink")
        XCTAssertEqual(answer?.ear, "qwen")
        XCTAssertEqual(behind.context, ["PrivateLink"], "the names reach the ear")

        let alone = EarHost(clock: clock.clock)
        alone.install(ear: quick, tier: .small)
        XCTAssertEqual(heard(alone)?.ear, "parakeet", "the quick ear, on a setup without one behind")
    }

    /// A cold ear loads once, then rests on the draft's thirty minutes.
    func testAColdEarLoadsAndRestsAsForADraft() {
        let ear = WordsEar("parakeet", hears: "hello", loaded: false)
        let host = EarHost(clock: clock.clock)
        host.install(ear: ear, tier: .small)
        XCTAssertEqual(heard(host)?.text, "hello")
        XCTAssertEqual(ear.loads, 1)
        XCTAssertEqual(heard(host)?.text, "hello")
        XCTAssertEqual(ear.loads, 1, "warm the second time")
        clock.advance(by: 29 * 60)
        XCTAssertTrue(ear.isLoaded)
        clock.advance(by: 2 * 60)
        XCTAssertFalse(ear.isLoaded, "let go after thirty minutes")
    }

    /// A file heard during a draft leaves the draft's ear alone.
    func testAFileHeardDuringADraftDoesNotRestItsEar() {
        let ear = WordsEar("parakeet", hears: "hello")
        let host = EarHost(clock: clock.clock)
        host.install(ear: ear, tier: .small)
        host.warm()
        _ = heard(host)
        clock.advance(by: 40 * 60)
        XCTAssertTrue(ear.isLoaded, "the draft is still open")
    }

    /// A draft's load on its way is waited for, never doubled.
    func testAFileWaitsForTheDraftsLoad() {
        let ear = SlowEar()
        let host = EarHost(clock: clock.clock)
        host.install(ear: ear, tier: .small)
        host.warm()
        var finished = false
        host.hear([0], context: []) { _ in finished = true }
        pump(until: { true })
        XCTAssertFalse(finished, "waits for the load")
        ear.finishLoading()
        pump(until: { finished })
        XCTAssertTrue(ear.isLoaded)
    }

    func testWithNoEarItSaysSo() {
        let host = EarHost(clock: clock.clock)
        host.install(ear: nil, tier: .apple)
        var problem: String?
        host.hear([0], context: []) { result in
            if case .failure(let error) = result { problem = "\(error)" }
        }
        XCTAssertEqual(problem, "dictation has no ear on this Mac yet (Settings › Dictation)")
    }
}
