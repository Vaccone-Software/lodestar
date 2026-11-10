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

/// A language model backend that is loaded on the test's say-so, and
/// remembers that it was asked to.
private final class Loads: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func note() { lock.withLock { _count += 1 } }
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
}
