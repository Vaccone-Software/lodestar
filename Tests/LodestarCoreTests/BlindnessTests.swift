import XCTest
@testable import LodestarCore

/// When the instrument could not see: spans recorded with their kind and
/// edges and nothing else, closed on the next start whatever the last run
/// left open, and never read by the pulse as the hands resting.
final class BlindnessTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func testASpanCarriesItsKindAndEdgesAndNothingElse() throws {
        var ledger = BlindLedger()
        XCTAssertTrue(ledger.begin(.secureInput, at: at(0), resolution: 2))
        XCTAssertFalse(ledger.begin(.secureInput, at: at(1)), "one span of a kind at a time")
        let event = try XCTUnwrap(ledger.end(.secureInput, at: at(42)))
        XCTAssertEqual(event.kind, .blind)
        XCTAssertEqual(event.t, at(0))
        XCTAssertEqual(event.blind?.end, at(42))
        XCTAssertEqual(event.blind?.blindKind, .secureInput)
        XCTAssertEqual(event.blind?.resolution, 2)
        // Nothing about where: no app, no title, no field.
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event.blind)) as! [String: Any]
        XCTAssertEqual(Set(json.keys), ["kind", "end", "resolution"])
        XCTAssertNil(event.app)
        XCTAssertNil(ledger.end(.secureInput, at: at(50)), "closed once")
    }

    /// A quit is noted at its moment; what it left open ends there, and the
    /// time away runs from it to the next start, every edge seen.
    func testACleanQuitIsClosedAtItsOwnMomentOnTheNextStart() {
        var ledger = BlindLedger()
        _ = ledger.start(at: at(0))
        ledger.begin(.asleep, at: at(100))
        ledger.stop(.notRunning, at: at(200))
        let events = ledger.start(at: at(5000))
        XCTAssertEqual(events.map { $0.blind?.blindKind }, [.asleep, .notRunning])
        XCTAssertEqual(events[0].t, at(100))
        XCTAssertEqual(events[0].blind?.end, at(200))
        XCTAssertNil(events[0].blind?.endBound)
        XCTAssertEqual(events[1].t, at(200))
        XCTAssertEqual(events[1].blind?.end, at(5000))
        XCTAssertNil(events[1].blind?.startBound)
        XCTAssertTrue(ledger.open.isEmpty)
        XCTAssertNil(ledger.stopped)
    }

    /// A crash writes no stop: what was open ends at the last heartbeat,
    /// marked as a bound, and the time away starts there, also a bound.
    /// Never open-ended, never stretched past what was seen.
    func testACrashIsBoundedByTheLastHeartbeat() {
        var ledger = BlindLedger()
        _ = ledger.start(at: at(0))
        ledger.begin(.secureInput, at: at(30), resolution: 2)
        ledger.heartbeat(at: at(60))
        ledger.heartbeat(at: at(120))
        // The process dies here; the next one starts much later.
        let events = ledger.start(at: at(4000))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].blind?.blindKind, .secureInput)
        XCTAssertEqual(events[0].blind?.end, at(120))
        XCTAssertEqual(events[0].blind?.endBound, true)
        XCTAssertEqual(events[1].blind?.blindKind, .notRunning)
        XCTAssertEqual(events[1].t, at(120))
        XCTAssertEqual(events[1].blind?.startBound, true)
        XCTAssertEqual(events[1].blind?.end, at(4000))
    }

    func testTheSwitchOffIsOneHealthOffSpan() {
        var ledger = BlindLedger()
        _ = ledger.start(at: at(0))
        ledger.stop(.healthOff, at: at(10))
        let events = ledger.start(at: at(910))
        XCTAssertEqual(events.map { $0.blind?.blindKind }, [.healthOff])
        XCTAssertEqual(events.first?.blind?.end, at(910))
    }

    func testAFirstStartInventsNothing() {
        var ledger = BlindLedger()
        XCTAssertEqual(ledger.start(at: at(0)), [])
    }

    func testTheLedgerSurvivesTheDisk() throws {
        var ledger = BlindLedger()
        _ = ledger.start(at: at(0))
        ledger.begin(.untrusted, at: at(5), startBound: true)
        ledger.heartbeat(at: at(60))
        let back = try JSONDecoder().decode(BlindLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(back, ledger)
    }

    // MARK: - The pulse

    /// A gap across a span nobody could see is not a typing gap.
    func testAGapAcrossABlindSpanIsNeitherRhythmNorPause() {
        var pulse = HealthPulse()
        _ = pulse.key(at: at(0), backspace: false)
        _ = pulse.key(at: at(0.2), backspace: false)
        XCTAssertEqual(pulse.ikN, 1)
        _ = pulse.blindEnded(from: at(1), to: at(30))
        _ = pulse.key(at: at(31), backspace: false)
        XCTAssertEqual(pulse.ikN, 1, "the 30 s across the span is not a gap")
        XCTAssertEqual(pulse.ikTailN, 0, "nor a pause")
        _ = pulse.key(at: at(31.15), backspace: false)
        XCTAssertEqual(pulse.ikN, 2, "the rhythm resumes after it")
    }

    /// Blind time is not quiet time: four minutes of typing, seven blind,
    /// five quiet. The quiet alone is under the bout gap, so the bout runs
    /// on; read as rest, sixteen minutes would have ended it.
    func testAShortBlindSpanDoesNotCountAsRest() {
        var pulse = HealthPulse()
        _ = pulse.key(at: at(0), backspace: false)
        let bout = pulse.boutStart
        _ = pulse.key(at: at(240), backspace: false)
        _ = pulse.blindEnded(from: at(240), to: at(660))
        _ = pulse.key(at: at(960), backspace: false)
        XCTAssertEqual(pulse.boutStart, bout, "the same bout")
    }

    /// A span at or past the bout gap ends the bout, censored: the window
    /// closes there and the next input opens a new bout.
    func testALongBlindSpanEndsTheBoutWithoutCallingItRest() {
        var pulse = HealthPulse()
        _ = pulse.key(at: at(0), backspace: false)
        _ = pulse.key(at: at(60), backspace: false)
        let closed = pulse.blindEnded(from: at(60), to: at(60 + HealthPulse.boutGap))
        XCTAssertNotNil(closed, "the window open at the span closes")
        XCTAssertNil(pulse.boutStart)
        _ = pulse.key(at: at(2000), backspace: false)
        XCTAssertEqual(pulse.boutStart, at(2000))
    }

    // MARK: - Archive and printout

    func testTheRollupKeepsSpansAndSecondsByKind() throws {
        let asleep = BlindSpan.event(.asleep, from: at(0), to: at(3600))
        let secure = BlindSpan.event(.secureInput, from: at(4000), to: at(4030), resolution: 2)
        let months = Rollup.build(events: [asleep, secure], now: at(60 * 86_400))
        let month = try XCTUnwrap(months[Rollup.monthKey(at(0))])
        XCTAssertEqual(month.blindSpans, ["asleep": 1, "secureInput": 1])
        XCTAssertEqual(month.blindSeconds["asleep"], 3600)
        XCTAssertEqual(month.blindSeconds["secureInput"], 30)
        // A month archived before the spans existed still reads.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(month)) as! [String: Any]
        json.removeValue(forKey: "blindSpans")
        json.removeValue(forKey: "blindSeconds")
        let old = try JSONDecoder().decode(Rollup.Month.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.blindSpans, [:])
    }

    func testThePrintoutSaysHowLongAndWhy() {
        let events = [
            BlindSpan.event(.asleep, from: at(0), to: at(7500)),
            BlindSpan.event(.secureInput, from: at(8000), to: at(8240)),
            BlindSpan.event(.secureInput, from: at(9000), to: at(9010)),
        ]
        let rows = BlindSummary.rows(events: events, days: 28, now: at(10_000))
        XCTAssertEqual(rows.map(\.kind), ["asleep", "secureInput"])
        XCTAssertEqual(rows.last?.spans, 2)
        XCTAssertEqual(BlindSummary.line(rows), "2h 09m unseen · asleep 2h 05m (1) · secure input 4m (2)")
        XCTAssertNil(BlindSummary.line([]))
    }
}
