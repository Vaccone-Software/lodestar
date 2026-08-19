import XCTest
@testable import LodestarCore

/// Whether the coach may speak: is a person here, did a person cause this,
/// and has this suggestion had its turn. The origin cases below are not
/// invented — they are the four readings measured at a live event tap, kept
/// here so a later simplification cannot quietly reopen the hole.
final class CoachPresenceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Event origin

    /// Hardware: source id 1, and no posting process at all.
    func testHardwareInputIsHuman() {
        XCTAssertTrue(Coach.isHumanOrigin(sourceStateID: 1, postingPID: 0))
    }

    /// Ordinary automation announces itself twice over.
    func testPlainAutomationIsNotHuman() {
        XCTAssertFalse(Coach.isHumanOrigin(sourceStateID: 590_335_821, postingPID: 40_671))
    }

    /// An event built with no source at all — the laziest posting there is.
    func testSourcelessAutomationIsNotHuman() {
        XCTAssertFalse(Coach.isHumanOrigin(sourceStateID: 0, postingPID: 40_671))
    }

    /// The case that matters. Building the source as `.hidSystemState` costs
    /// one line and makes the source id read exactly like hardware — so a
    /// source-only check passes it. The pid is what still refuses, and this
    /// test is here to fail loudly if the pid ever stops being consulted.
    func testForgedSourceIdIsStillNotHuman() {
        XCTAssertFalse(Coach.isHumanOrigin(sourceStateID: Coach.hidSystemStateID,
                                           postingPID: 40_671))
    }

    /// Forging the pid too changes nothing: the system overwrites the field,
    /// so the poster's pid arrives at the tap regardless of what was set.
    func testForgedPidIsOverwrittenSoOriginStillReads() {
        XCTAssertFalse(Coach.isHumanOrigin(sourceStateID: Coach.hidSystemStateID,
                                           postingPID: 40_671))
        XCTAssertTrue(Coach.isHumanOrigin(sourceStateID: Coach.hidSystemStateID,
                                          postingPID: 0))
    }

    // MARK: - Presence

    func testPresentWhenSomeoneJustTyped() {
        XCTAssertTrue(Coach.isPresent(humanIdle: 0.05, screenLocked: false,
                                      displayAsleep: false, onConsole: true))
    }

    func testAbsentOnceTheHumanClockPassesTheCeiling() {
        XCTAssertTrue(Coach.isPresent(humanIdle: Coach.presenceCeiling - 1,
                                      screenLocked: false, displayAsleep: false,
                                      onConsole: true))
        XCTAssertFalse(Coach.isPresent(humanIdle: Coach.presenceCeiling,
                                       screenLocked: false, displayAsleep: false,
                                       onConsole: true))
    }

    func testEachWayAScreenStopsBeingWatched() {
        XCTAssertFalse(Coach.isPresent(humanIdle: 0, screenLocked: true,
                                       displayAsleep: false, onConsole: true))
        XCTAssertFalse(Coach.isPresent(humanIdle: 0, screenLocked: false,
                                       displayAsleep: true, onConsole: true))
        XCTAssertFalse(Coach.isPresent(humanIdle: 0, screenLocked: false,
                                       displayAsleep: false, onConsole: false))
    }

    // MARK: - The clock an agent cannot move

    /// The whole point of keeping our own clock. An agent posting all
    /// afternoon must never make the chair look occupied — the system's own
    /// idle clock fails exactly here, because posted events reset it.
    func testAgentActivityNeverRefreshesTheHumanClock() {
        var lastHumanInputAt = Date.distantPast
        for second in 0..<600 {
            let now = start.addingTimeInterval(Double(second))
            // The agent's stream: forged source, its own pid.
            if Coach.isHumanOrigin(sourceStateID: Coach.hidSystemStateID,
                                   postingPID: 40_671) {
                lastHumanInputAt = now
            }
        }
        let now = start.addingTimeInterval(600)
        XCTAssertEqual(lastHumanInputAt, .distantPast)
        XCTAssertFalse(Coach.isPresent(humanIdle: now.timeIntervalSince(lastHumanInputAt),
                                       screenLocked: false, displayAsleep: false,
                                       onConsole: true))
    }

    /// And the half that must not over-correct: a person at the keyboard is
    /// present whether or not an agent is also busy. The agent's events are
    /// simply not evidence either way.
    func testPersonIsPresentEvenWhileAnAgentIsBusy() {
        var lastHumanInputAt = Date.distantPast
        for second in 0..<600 {
            let now = start.addingTimeInterval(Double(second))
            let agent = Coach.isHumanOrigin(sourceStateID: Coach.hidSystemStateID,
                                            postingPID: 40_671)
            if agent { lastHumanInputAt = now }
            // The person types every tenth second, through the same tap.
            if second % 10 == 0,
               Coach.isHumanOrigin(sourceStateID: 1, postingPID: 0) {
                lastHumanInputAt = now
            }
        }
        let now = start.addingTimeInterval(600)
        XCTAssertEqual(lastHumanInputAt, start.addingTimeInterval(590))
        XCTAssertTrue(Coach.isPresent(humanIdle: now.timeIntervalSince(lastHumanInputAt),
                                      screenLocked: false, displayAsleep: false,
                                      onConsole: true))
    }

    /// Someone who walks away mid-session goes quiet on schedule, even if
    /// the machine keeps working.
    func testTheClockRunsOutAfterThePersonLeaves() {
        let lastHumanInputAt = start
        let stillWarm = start.addingTimeInterval(Coach.presenceCeiling - 1)
        let gone = start.addingTimeInterval(Coach.presenceCeiling + 1)
        XCTAssertTrue(Coach.isPresent(humanIdle: stillWarm.timeIntervalSince(lastHumanInputAt),
                                      screenLocked: false, displayAsleep: false,
                                      onConsole: true))
        XCTAssertFalse(Coach.isPresent(humanIdle: gone.timeIntervalSince(lastHumanInputAt),
                                       screenLocked: false, displayAsleep: false,
                                       onConsole: true))
    }

    // MARK: - The veto chain

    func testAQuietMomentWithAnOfferStandingSpeaks() {
        XCTAssertEqual(Coach.hold(Coach.Moment()), .speak)
    }

    func testEveryVetoNamesItself() {
        XCTAssertEqual(Coach.hold(Coach.Moment(enabled: false)), .disabled)
        XCTAssertEqual(Coach.hold(Coach.Moment(chipVisible: true)), .chipUp)
        XCTAssertEqual(Coach.hold(Coach.Moment(offerSpent: true)), .offerSpent)
        XCTAssertEqual(Coach.hold(Coach.Moment(sinceLastShown: 1)), .tooSoon)
        XCTAssertEqual(Coach.hold(Coach.Moment(engineQuiet: false)), .engineBusy)
        XCTAssertEqual(Coach.hold(Coach.Moment(cameraRunning: true)), .camera)
        XCTAssertEqual(Coach.hold(Coach.Moment(present: false)), .absent)
        XCTAssertEqual(Coach.hold(Coach.Moment(inputWasHuman: false)), .notHuman)
    }

    /// A meeting silences the coach whether or not anyone is judged present,
    /// and being switched off outranks every reading — the cheap, certain
    /// answers come first so an expensive one is never the reason.
    func testVetoesTakePrecedenceInOrder() {
        XCTAssertEqual(Coach.hold(Coach.Moment(enabled: false, chipVisible: true,
                                               present: false, inputWasHuman: false)),
                       .disabled)
        XCTAssertEqual(Coach.hold(Coach.Moment(cameraRunning: true, present: false)),
                       .camera)
        XCTAssertEqual(Coach.hold(Coach.Moment(present: false, inputWasHuman: false)),
                       .absent)
    }

    /// A showing that never counted may try again, but only once the floor
    /// has passed — the boundary itself is allowed.
    func testTheReshowFloorIsInclusiveAtItsEdge() {
        XCTAssertEqual(Coach.hold(Coach.Moment(sinceLastShown: Coach.reshowSeconds - 0.1)),
                       .tooSoon)
        XCTAssertEqual(Coach.hold(Coach.Moment(sinceLastShown: Coach.reshowSeconds)),
                       .speak)
    }

    /// An offer already spent stays spent until a pass puts something else in
    /// the slot; this is what keeps showings from outrunning `maxOffers`.
    func testASpentOfferStaysQuietEvenWhenEverythingElseIsPerfect() {
        XCTAssertEqual(Coach.hold(Coach.Moment(offerSpent: true, sinceLastShown: 86_400)),
                       .offerSpent)
    }

    // MARK: - Invariants between the timings

    /// The checkpoint has to land while the chip is still up, or an offer
    /// could never be spent at all.
    func testTheSeenCheckpointFallsInsideTheChipsLife() {
        XCTAssertLessThan(Coach.seenSeconds, Coach.chipSeconds)
        XCTAssertGreaterThan(Coach.seenSeconds, 0)
    }

    /// And the re-show floor has to outlive the chip, so a retry can never
    /// race a chip that is still on the glass.
    func testTheReshowFloorOutlivesTheChip() {
        XCTAssertGreaterThanOrEqual(Coach.reshowSeconds, Coach.chipSeconds)
    }
}
