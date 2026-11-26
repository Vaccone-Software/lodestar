import Stoic
import XCTest
@testable import lodestar

/// Whether meetings run, as a specification: what each thing seen owes, over
/// every road to it. No calendar is asked anything.
final class MeetingAccessTests: XCTestCase {
    private typealias Access = MeetingAccess

    private func step(_ state: Access.State, _ event: Access.Event) -> (next: Access.State, effects: [Access.Effect]) {
        switch Access.transition(from: state, on: event) {
        case .to(let next, let effects): return (next, effects)
        case .stay(let effects): return (state, effects)
        case .refuse, .ignore, .invalid:
            XCTFail("\(state) refused \(event)")
            return (state, [])
        }
    }

    /// What a run of things seen owed, in order.
    private func owed(_ events: [Access.Event]) -> [Access.Effect] {
        var state = Access.State()
        return events.flatMap { event -> [Access.Effect] in
            let (next, effects) = step(state, event)
            state = next
            return effects
        }
    }

    func testTheFirstSwitchingOnAsksThenTheGrantStarts() {
        XCTAssertEqual(owed([.undecided]), [.watch, .prime])
        XCTAssertEqual(owed([.undecided, .granted]), [.watch, .prime, .start])
        XCTAssertEqual(owed([.granted]), [.start], "access was had already")
    }

    func testSeeingTheSameAgainStartsStopsAsksAndSaysNothing() {
        for event in Access.Event.allCases {
            let once = owed([event])
            let again = owed([event, event, event]).dropFirst(once.count)
            XCTAssertTrue(again.allSatisfy { $0 == .watch }, "\(event) again owed \(Array(again))")
        }
        XCTAssertEqual(owed([.switchedOff, .switchedOff]), [], "off is where it begins")
    }

    func testTheCardIsShownOncePerSwitchingOn() {
        let primes: ([Access.Event]) -> Int = { self.owed($0).filter { $0 == .prime }.count }
        XCTAssertEqual(primes([.undecided, .undecided, .refused, .undecided, .granted, .undecided]), 1)
        XCTAssertEqual(primes([.undecided, .switchedOff, .undecided]), 2, "asked again")
    }

    func testADenialIsSaidOnceUntilAccessIsHadAgain() {
        let tells: ([Access.Event]) -> Int = { self.owed($0).filter { $0 == .tell }.count }
        XCTAssertEqual(tells([.refused, .refused, .undecided, .refused]), 1)
        XCTAssertEqual(tells([.refused, .switchedOff, .refused]), 1, "switching it off and on is not news")
        XCTAssertEqual(tells([.refused, .granted, .refused]), 2)
    }

    /// Over every road of six things seen: meetings run when they were last
    /// seen switched on and allowed, and stop when switched off or denied.
    func testMeetingsRunExactlyWhileOnAndAllowed() {
        func walk(_ state: Access.State, running: Bool, seen: [Access.Event]) {
            guard seen.count < 6 else { return }
            for event in Access.Event.allCases {
                let (next, effects) = step(state, event)
                var running = running
                for effect in effects {
                    if effect == .start { running = true }
                    if effect == .stop { running = false }
                }
                switch event {
                case .granted: XCTAssertTrue(running, "\(seen + [event])")
                case .switchedOff, .refused: XCTAssertFalse(running, "\(seen + [event])")
                case .undecided: break
                }
                XCTAssertEqual(effects.contains(.watch), event == .undecided || event == .refused, "\(seen + [event])")
                walk(next, running: running, seen: seen + [event])
            }
        }
        walk(Access.State(), running: false, seen: [])
    }
}
