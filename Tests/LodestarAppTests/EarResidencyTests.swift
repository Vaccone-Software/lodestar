import Stoic
import StoicTesting
import XCTest
@testable import lodestar

/// The ears' residency as a specification: every state it can reach, and
/// what each event owes there. Nothing is loaded and nothing waits.
final class EarResidencyTests: XCTestCase {
    private typealias Ears = EarResidency

    /// A step's state and what it owes; nil when the event means nothing.
    private func step(_ state: Ears.State, _ event: Ears.Event) -> (next: Ears.State, effects: [Ears.Effect])? {
        switch Ears.transition(from: state, on: event) {
        case .to(let next, let effects): return (next, effects)
        case .stay(let effects): return (state, effects)
        case .refuse, .ignore: return nil
        case .invalid(let why):
            XCTFail("\(state) on \(event): \(why)")
            return nil
        }
    }

    /// The events that can happen in `state`: a load ends only if one is on
    /// its way, and a phrase only if one is heard (at most two at once).
    private func possible(in state: Ears.State) -> [Ears.Event] {
        var events: [Ears.Event] = [.opened, .closed, .warning, .critical]
        if state.phrases < 2 { events += [.phraseBegan(cold: true), .phraseBegan(cold: false)] }
        if state.phrases > 0 { events.append(.phraseEnded) }
        if state.loading != nil { events += [.loadEnded(loaded: true), .loadEnded(loaded: false)] }
        return events
    }

    /// Every step from every state reachable from the first.
    private func everyStep(_ check: (Ears.State, Ears.Event, Ears.State, [Ears.Effect]) -> Void) {
        var seen: Set<Ears.State> = [Ears.State()]
        var queue = [Ears.State()]
        while let state = queue.popLast() {
            for event in possible(in: state) {
                guard let (next, effects) = step(state, event) else { continue }
                check(state, event, next, effects)
                if seen.insert(next).inserted { queue.append(next) }
            }
        }
        XCTAssertGreaterThan(seen.count, 20, "the walk reached only \(seen.count) states")
    }

    private func loads(_ effects: [Ears.Effect]) -> Bool {
        effects.contains(.load(.draft)) || effects.contains(.load(.phrase))
    }

    private func unloads(_ effects: [Ears.Effect]) -> Bool {
        effects.contains(.unloadEars) || effects.contains(.unloadBehind) || effects.contains(.unloadLive)
    }

    func testALoadIsNeverAskedForWhileOneIsOnItsWay() {
        everyStep { state, event, next, effects in
            guard loads(effects) else { return }
            XCTAssertNil(state.loading, "\(state) on \(event)")
            XCTAssertNotNil(next.loading, "\(state) on \(event): asked for and not on its way")
        }
    }

    func testNothingIsUnloadedUnderALoad() {
        everyStep { state, event, next, effects in
            guard unloads(effects) else { return }
            XCTAssertNil(next.loading, "\(state) on \(event)")
        }
    }

    /// Not mid-sentence: whatever macOS says and whatever ends, an open
    /// draft keeps what it hears with.
    func testAnOpenDraftLosesNothing() {
        everyStep { state, event, next, effects in
            guard next.draft else { return }
            XCTAssertFalse(unloads(effects) || effects.contains(.releaseModel), "\(state) on \(event)")
            XCTAssertFalse(effects.contains(.restEars) || effects.contains(.restModel), "\(state) on \(event)")
        }
    }

    func testAnOpeningDraftStopsBothSpansAndAClosingOneStartsThem() {
        everyStep { state, event, _, effects in
            if event == .opened {
                XCTAssertTrue(effects.contains(.keepEars) && effects.contains(.keepModel), "\(state)")
            }
            if event == .closed {
                XCTAssertTrue(effects.contains(.restModel), "\(state)")
                XCTAssertNotEqual(effects.contains(.restEars), state.pressed, "\(state)")
            }
        }
    }

    /// The language model is asked for after the ears, loaded or failed, and
    /// never in the same step that asks for them.
    func testTheLanguageModelFollowsTheEars() {
        everyStep { state, event, _, effects in
            guard effects.contains(.loadModel) else { return }
            XCTAssertFalse(loads(effects), "\(state) on \(event)")
            switch event {
            case .loadEnded: break
            default: XCTFail("\(state) on \(event) asked for the model")
            }
        }
    }

    /// A warning takes the language model and the ear behind, never the
    /// quick ear or the live recognizer.
    func testAWarningNeverTakesTheQuickEar() {
        everyStep { state, event, _, effects in
            guard event == .warning else { return }
            XCTAssertFalse(effects.contains(.unloadEars) || effects.contains(.unloadLive), "\(state)")
        }
    }

    /// A phrase outside the draft counts down the ears alone.
    func testAPhraseNeverTouchesTheModelsSpan() {
        everyStep { state, event, _, effects in
            switch event {
            case .phraseBegan, .phraseEnded:
                XCTAssertFalse(effects.contains(.keepModel) || effects.contains(.restModel), "\(state) on \(event)")
            default: break
            }
        }
    }

    func testWhatCannotHappenIsReported() {
        for event: Ears.Event in [.phraseEnded, .loadEnded(loaded: true)] {
            guard case .invalid = Ears.transition(from: Ears.State(), on: event) else {
                return XCTFail("\(event) was taken with nothing begun")
            }
        }
    }

    // MARK: - The idle span

    private func span(_ clock: TestClock) -> (StateMachine<IdleSpan.State, IdleSpan.Event>, Letting) {
        let letting = Letting()
        let machine = StateMachine(IdleSpan.self, initial: .kept, clock: clock.erased) { _ in letting.note() }
        return (machine, letting)
    }

    func testASpanLetsGoOnceWhenItRunsOut() async {
        let clock = TestClock()
        let (span, letting) = span(clock)
        span.send(.count(.seconds(300)))
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(299))
        XCTAssertEqual(letting.count, 0)
        await clock.advance(by: .seconds(1))
        await eventually("it ran out") { letting.count == 1 }
        XCTAssertEqual(span.state, .over)
        XCTAssertEqual(clock.sleeperCount, 0, "nothing more to wait for")
    }

    func testASpanIsCountedAgainFromEachStartAndStoppedByUse() async {
        let clock = TestClock()
        let (span, letting) = span(clock)
        span.send(.count(.seconds(300)))
        await clock.waitForSleepers(count: 1)
        await clock.advance(by: .seconds(200))
        var mark = clock.totalSleeps
        span.send(.count(.seconds(300)))
        await clock.waitForSleepers(newerThan: mark)
        await clock.advance(by: .seconds(200))
        XCTAssertEqual(span.state, .counting(.seconds(300)), "counted again")
        span.send(.keep)
        await clock.advance(by: .seconds(3_600))
        XCTAssertEqual(letting.count, 0, "in use")
        mark = clock.totalSleeps
        span.send(.count(.seconds(300)))
        await clock.waitForSleepers(newerThan: mark)
        await clock.advance(by: .seconds(300))
        await eventually("it ran out") { letting.count == 1 }
    }

    private final class Letting: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int { lock.withLock { _count } }
        func note() { lock.withLock { _count += 1 } }
    }

    private func eventually(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () -> Bool) async {
        let until = Date().addingTimeInterval(EditorRig.patience)
        while !condition(), Date() < until { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition(), what, file: file, line: line)
    }
}
