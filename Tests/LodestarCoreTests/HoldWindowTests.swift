import XCTest
@testable import LodestarCore

/// Ninety seconds of presses, described exactly: the windows fall where
/// the clock says, the published features come out as arithmetic says
/// they should, and the pairs are split by hand and direction.
final class HoldWindowTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func press(_ seconds: Double, hold: Double? = 0.1, hand: Keys.Hand = .left,
                       kind: Keys.Kind = .letter, chord: Bool = false, gesture: Bool = false,
                       repeated: Bool = false) -> KeyPress {
        KeyPress(down: start.addingTimeInterval(seconds), hold: hold, hand: hand, kind: kind,
                 chord: chord, gesture: gesture, repeated: repeated)
    }

    // MARK: - The new columns

    func testModifierPressesAreCountedWithTheirHoldAndChordSize() {
        var presses = (0..<30).map { press(Double($0) * 0.2) }
        for i in presses.indices { presses[i].finger = i % 2 == 0 ? .index : .pinky }
        var control = press(0.05, hold: 1.5, kind: .modifier)
        control.modifiers = .control
        control.struck = 6
        var shift = press(3.0, hold: 0.4, kind: .modifier)
        shift.modifiers = .shift
        shift.struck = 1
        let stats = HoldWindow.stats(start: start, presses: presses + [control, shift])
        XCTAssertEqual(stats.modifiers, 2)
        XCTAssertEqual(stats.struck, 7)
        XCTAssertEqual(stats.modifierHold?.n, 2)
        XCTAssertEqual(stats.modifierHold?.sum ?? 0, 1.9, accuracy: 1e-9)
        XCTAssertEqual(stats.typing, 30, "a modifier is never typing")
        XCTAssertEqual(stats.fingers?[Int(Keys.Finger.index.rawValue)], 15)
        XCTAssertEqual(stats.fingers?[Int(Keys.Finger.pinky.rawValue)], 15)
        XCTAssertEqual(stats.fingers?[Int(Keys.Finger.unknown.rawValue)], 2)
        XCTAssertEqual(stats.kinds[Int(Keys.Kind.modifier.rawValue)], 2)
    }

    func testAWindowWrittenBeforeTheColumnsDecodes() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let json = """
        {"start":1700000000,"seconds":10,"presses":3,"typing":3,"valid":false,
         "hold":{"n":3,"sum":0.3,"sumSq":0.03,"sumCube":0.003,"sumQuad":0.0003},
         "holdQ":[],"holdCDF":[],"outliers":0,
         "fluct":{"n":0,"sum":0,"sumSq":0,"sumCube":0,"sumQuad":0},"fluctQ":[],
         "flight":{"n":0,"sum":0,"sumSq":0,"sumCube":0,"sumQuad":0},
         "overlap":{"n":0,"sum":0,"sumSq":0,"sumCube":0,"sumQuad":0},"overlapN":0,
         "latency":{"n":0,"sum":0,"sumSq":0,"sumCube":0,"sumQuad":0},
         "left":{"hold":{"n":0,"sum":0,"sumSq":0,"sumCube":0,"sumQuad":0},"q":[]},
         "right":{"hold":{"n":0,"sum":0,"sumSq":0,"sumCube":0,"sumQuad":0},"q":[]},
         "ll":{"n":0,"latency":{"n":0,"sum":0,"sumSq":0,"sumCube":0,"sumQuad":0},"flight":{"n":0,"sum":0,"sumSq":0,"sumCube":0,"sumQuad":0}},
         "lr":{"n":0,"latency":{"n":0,"sum":0,"sumSq":0,"sumCube":0,"sumQuad":0},"flight":{"n":0,"sum":0,"sumSq":0,"sumCube":0,"sumQuad":0}},
         "rl":{"n":0,"latency":{"n":0,"sum":0,"sumSq":0,"sumCube":0,"sumQuad":0},"flight":{"n":0,"sum":0,"sumSq":0,"sumCube":0,"sumQuad":0}},
         "rr":{"n":0,"latency":{"n":0,"sum":0,"sumSq":0,"sumCube":0,"sumQuad":0},"flight":{"n":0,"sum":0,"sumSq":0,"sumCube":0,"sumQuad":0}},
         "kinds":[0,3,0,0,0,0,0,0,0,0,0,0],"shift":0,"chord":0,"gesture":0,"lens":0,"repeated":0,
         "unseen":0,"keyboardTypes":{"40":3}}
        """
        let stats = try decoder.decode(WindowStats.self, from: Data(json.utf8))
        XCTAssertEqual(stats.presses, 3)
        XCTAssertNil(stats.fingers)
        XCTAssertNil(stats.modifierHold)
        XCTAssertNil(stats.lid)
        XCTAssertEqual(stats.kinds.count, 12, "an older window's kinds are read as written")
    }

    // MARK: - Windowing

    func testAPressPastNinetySecondsClosesTheWindowAndOpensTheNext() {
        var window = HoldWindow()
        XCTAssertNil(window.add(press(0)))
        XCTAssertNil(window.add(press(89.9)))
        let closed = window.add(press(90))
        XCTAssertNotNil(closed)
        XCTAssertEqual(closed?.presses, 2)
        XCTAssertEqual(closed?.start, start)
        XCTAssertEqual(window.count, 1)
        XCTAssertEqual(window.openedAt, start.addingTimeInterval(90))
    }

    func testAStaleWindowClosesOnTheClock() {
        var window = HoldWindow()
        _ = window.add(press(0))
        XCTAssertNil(window.closeIfStale(now: start.addingTimeInterval(60)))
        XCTAssertNotNil(window.closeIfStale(now: start.addingTimeInterval(90)))
        XCTAssertFalse(window.isOpen)
    }

    func testValidityIsThePublishedFloor() {
        var window = HoldWindow()
        for i in 0..<29 { _ = window.add(press(Double(i) * 0.2)) }
        XCTAssertEqual(window.close()?.valid, false)
        for i in 0..<30 { _ = window.add(press(Double(i) * 0.2)) }
        XCTAssertEqual(window.close()?.valid, true)
    }

    // MARK: - The description

    func testOnlyTheTypingHabitEntersTheMoments() {
        var window = HoldWindow()
        _ = window.add(press(0, hold: 0.1))
        _ = window.add(press(0.2, hold: 0.5, chord: true))
        _ = window.add(press(0.4, hold: 0.5, gesture: true))
        _ = window.add(press(0.6, hold: 0.5, repeated: true))
        _ = window.add(press(0.8, hold: 0.5, kind: .backspace))
        _ = window.add(press(1.0, hold: nil))
        _ = window.add(press(1.2, hold: 2.0)) // past the ceiling: a held key
        _ = window.add(press(1.4, hold: 0.1))
        let stats = window.close()!
        XCTAssertEqual(stats.presses, 8)
        XCTAssertEqual(stats.typing, 2)
        XCTAssertEqual(stats.hold.n, 2)
        XCTAssertEqual(stats.hold.mean!, 0.1, accuracy: 1e-9)
        XCTAssertEqual(stats.chord, 1)
        XCTAssertEqual(stats.gesture, 1)
        XCTAssertEqual(stats.repeated, 1)
        XCTAssertEqual(stats.unseen, 1)
        XCTAssertEqual(stats.kinds[Int(Keys.Kind.backspace.rawValue)], 1)
        XCTAssertEqual(stats.kinds[Int(Keys.Kind.letter.rawValue)], 7)
    }

    func testQuantilesAndTheDistributionFunctionAreExact() {
        var window = HoldWindow()
        // Holds 0.05, 0.10, …, 0.50: a known ladder.
        for i in 1...10 { _ = window.add(press(Double(i) * 0.3, hold: Double(i) * 0.05)) }
        let stats = window.close()!
        XCTAssertEqual(stats.holdQ.count, 7)
        XCTAssertEqual(stats.holdQ[3], 0.275, accuracy: 1e-9) // median of 0.05…0.50
        XCTAssertEqual(stats.holdQ[2], 0.1625, accuracy: 1e-9) // p25
        XCTAssertEqual(stats.holdQ[4], 0.3875, accuracy: 1e-9) // p75
        XCTAssertEqual(stats.holdCDF, [2, 4, 7, 9]) // < .125, < .25, < .375, < .5
        XCTAssertEqual(stats.vIQR!, (0.275 - 0.1625) / (0.3875 - 0.1625), accuracy: 1e-9)
        XCTAssertEqual(stats.vHist!.reduce(0, +), 0.9, accuracy: 1e-9) // one hold sits at 0.5 exactly
        XCTAssertEqual(stats.outliers, 0)
    }

    func testAnOutlierIsCountedByTheInterquartileRule() {
        var window = HoldWindow()
        for i in 0..<20 { _ = window.add(press(Double(i) * 0.3, hold: 0.1)) }
        _ = window.add(press(6.3, hold: 0.9))
        let stats = window.close()!
        XCTAssertEqual(stats.outliers, 1)
        XCTAssertEqual(stats.vOut!, 1.0 / 21.0, accuracy: 1e-9)
    }

    func testPairsCarryFlightOverlapLatencyAndTheLogFluctuation() {
        var window = HoldWindow()
        _ = window.add(press(0, hold: 0.10))
        _ = window.add(press(0.15, hold: 0.20)) // flight 0.05, no overlap
        _ = window.add(press(0.25, hold: 0.10)) // flight 0.25 − 0.35 = −0.10: a rollover
        _ = window.add(press(5.0, hold: 0.10)) // past the pair gap: no pair
        let stats = window.close()!
        XCTAssertEqual(stats.latency.n, 2)
        XCTAssertEqual(stats.flight.n, 2)
        // Dates near 1.7e9 carry about a quarter microsecond of float.
        XCTAssertEqual(stats.flight.sum, 0.05 - 0.10, accuracy: 1e-6)
        XCTAssertEqual(stats.overlap.sum, 0.10, accuracy: 1e-6)
        XCTAssertEqual(stats.overlapN, 1)
        XCTAssertEqual(stats.fluct.n, 2)
        XCTAssertEqual(stats.fluct.sum, log(0.2 / 0.1) + log(0.1 / 0.2), accuracy: 1e-6)
        XCTAssertEqual(stats.fluctQ.count, 3)
    }

    func testPairsAreSplitByHandAndDirection() {
        var window = HoldWindow()
        _ = window.add(press(0.0, hand: .left))
        _ = window.add(press(0.2, hand: .left)) // LL
        _ = window.add(press(0.4, hand: .right)) // LR
        _ = window.add(press(0.6, hand: .right)) // RR
        _ = window.add(press(0.8, hand: .left)) // RL
        _ = window.add(press(1.0, hand: .thumb, kind: .space)) // thumb: no direction
        _ = window.add(press(1.2, hand: .left))
        let stats = window.close()!
        XCTAssertEqual(stats.ll.n, 1)
        XCTAssertEqual(stats.lr.n, 1)
        XCTAssertEqual(stats.rr.n, 1)
        XCTAssertEqual(stats.rl.n, 1)
        XCTAssertEqual(stats.latency.n, 6)
        XCTAssertEqual(stats.left.hold.n, 4)
        XCTAssertEqual(stats.right.hold.n, 2)
        XCTAssertEqual(stats.left.q.count, 3)
        XCTAssertEqual(stats.asymmetry!, 0, accuracy: 1e-9)
    }

    func testMomentsReadBackSkewAndKurtosis() {
        var m = Moments()
        for x in [1.0, 2.0, 3.0, 4.0, 5.0] { m.add(x) }
        XCTAssertEqual(m.mean!, 3, accuracy: 1e-12)
        XCTAssertEqual(m.sd!, 2.5.squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(m.skewness!, 0, accuracy: 1e-12)
        XCTAssertEqual(m.kurtosis!, -1.3, accuracy: 1e-12)
        var skewed = Moments()
        for x in [1.0, 1.0, 1.0, 1.0, 10.0] { skewed.add(x) }
        XCTAssertGreaterThan(skewed.skewness!, 1)
    }

    func testAWindowSurvivesTheRingAsJSON() throws {
        var window = HoldWindow()
        for i in 0..<40 { _ = window.add(press(Double(i) * 0.2, hand: i % 2 == 0 ? .left : .right)) }
        var stats = window.close()!
        stats.app = "Ghostty"
        stats.keyboards = ["13364:2064:abcd1234"]
        var event = ObservationEvent(t: start, kind: .window)
        event.window = stats
        let data = try JSONEncoder().encode(event)
        let back = try JSONDecoder().decode(ObservationEvent.self, from: data)
        XCTAssertEqual(back.kind, .window)
        XCTAssertEqual(back.window, stats)
    }

    func testTheRollupKeepsTheSpreadOfTheSpread() {
        var events: [ObservationEvent] = []
        for w in 0..<3 {
            var window = HoldWindow()
            let base = Double(w) * 100
            for i in 0..<40 {
                let hold = w == 1 ? (i % 2 == 0 ? 0.05 : 0.25) : 0.1 // one uneven window between two even ones
                _ = window.add(press(base + Double(i) * 0.2, hold: hold))
            }
            var event = ObservationEvent(t: start.addingTimeInterval(base), kind: .window)
            event.window = window.close()
            events.append(event)
        }
        let months = Rollup.build(events: events, now: start.addingTimeInterval(40 * 86_400))
        let month = months.values.first!
        let folded = month.health.windows!
        XCTAssertEqual(folded.windows, 3)
        XCTAssertEqual(folded.valid, 3)
        XCTAssertEqual(folded.holdSD.n, 3)
        // Two windows at zero spread, one wide: the spread across windows is not zero.
        XCTAssertGreaterThan(folded.holdSD.sd ?? 0, 0.05)
        XCTAssertEqual(month.weeks.values.first?.windows?.valid, 3)
    }
}
