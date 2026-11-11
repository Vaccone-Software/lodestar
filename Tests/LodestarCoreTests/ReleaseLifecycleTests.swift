import Foundation
import Stoic
import StoicStore
import StoicTesting
import XCTest
@testable import LodestarCore

/// The release's lifecycle as a definition: what the graph says of it, what
/// no walk through it may do, and the rules each of its transitions carries.
final class ReleaseLifecycleTests: XCTestCase {
    typealias Release = ReleaseOnThisMac
    private typealias Graph = StateGraph<Release.State, Release.Event>

    private let events = Release.Event.allCases

    // MARK: - The graph

    /// Explored from where a record can be made: offered (the feed), applying (an earlier build's
    /// marker) and refused (a tombstone). Every wait is a written list.
    func testTheDefinitionHasNoWaitWithoutAnEndAndNoStateItCannotLeave() {
        let graph = Graph.explore(Release.self, from: [.offered, .applying, .refused], events: events)
        XCTAssertTrue(graph.isComplete)
        XCTAssertEqual(Set(graph.waitingForever), [.offered, .running],
                       "offered waits for the feed and running for the watchdog's verdict, and nothing else waits for ever")
        XCTAssertEqual(graph.undeclaredDeadEnds, [])
        XCTAssertEqual(graph.finalWithExits, [], "a rolled-back or refused release is never left")
        XCTAssertEqual(graph.timedCycles, [])
        XCTAssertEqual(graph.stuckTimeouts, [], "every timeout moves its state")
        XCTAssertEqual(Set(graph.states), Set(Release.State.allCases), "all seven states are reachable")
    }

    func testRunningIsNotFinalButARollbackAndARefusalAre() {
        XCTAssertFalse(Release.isFinal(.running), "the watchdog's verdict can still arrive")
        XCTAssertTrue(Release.isFinal(.rolledBack))
        XCTAssertTrue(Release.isFinal(.refused))
        for state in [Release.State.offered, .downloading, .staged, .applying] { XCTAssertFalse(Release.isFinal(state)) }
    }

    // MARK: - Timeouts are data

    func testEachWaitingStateHasItsTimeout() {
        XCTAssertEqual(Release.timeout(in: .downloading), .after(.seconds(30 * 60), send: .stall))
        XCTAssertEqual(Release.timeout(in: .staged), .after(.seconds(7 * 24 * 3_600), send: .stall))
        XCTAssertEqual(Release.timeout(in: .applying), .after(.seconds(30 * 60), send: .stall))
        for state in [Release.State.offered, .running, .rolledBack, .refused] {
            XCTAssertNil(Release.timeout(in: state), "\(state)")
        }
        XCTAssertEqual(UpdateDownload.deadline, .seconds(30 * 60), "the download's timeout is the download's own deadline")
    }

    // MARK: - Transitions, at rest

    private func record(in state: Release.State, at moment: Moment = Moment(sinceEpoch: .seconds(1_767_225_600)))
        -> Release.Record {
        .new(in: state, by: .updater, because: "a test", at: moment)
    }

    private func apply(_ event: Release.Event, to state: Release.State, at moment: Moment? = nil) -> Result<Release.Change, Release.Refusal> {
        let start = Moment(sinceEpoch: .seconds(1_767_225_600))
        do {
            return .success(try record(in: state, at: start).applying(event, by: .updater, because: "a test", at: moment ?? start))
        } catch {
            return .failure(error)
        }
    }

    func testTheWatchdogsVerdictAfterTheSuccessorsConfirmIsStillRecorded() throws {
        let change = try apply(.rollBack, to: .running).get()
        XCTAssertEqual(change.record.written.state, .rolledBack,
                       "a running record that refused the verdict would leave a rolled-back release on offer")
        XCTAssertEqual(change.effects.map(\.effect), [.announce(.rolledBack)])
    }

    func testAConfirmAnnouncesRunningOnce() throws {
        let change = try apply(.confirm, to: .applying).get()
        XCTAssertEqual(change.record.written.state, .running)
        XCTAssertEqual(change.effects.map(\.effect), [.announce(.running)])
    }

    func testTheRelayAndTheResidentReadingTheSameMarkerIsTheSecondOneIgnored() {
        guard case .failure(let refusal) = apply(.confirm, to: .running) else { return XCTFail("a second confirm must not move") }
        XCTAssertEqual(refusal, .ignored(state: .running, event: .confirm))
        guard case .failure(let again) = apply(.rollBack, to: .rolledBack) else { return XCTFail("a second rollback must not move") }
        XCTAssertEqual(again, .ignored(state: .rolledBack, event: .rollBack))
    }

    func testAReleaseThatFailedItsHandoverIsRefusedForEverything() {
        for state in [Release.State.rolledBack, .refused] {
            for event in [Release.Event.download, .confirm, .apply] {
                guard case .failure(let refusal) = apply(event, to: state) else { return XCTFail("\(state) took \(event)") }
                XCTAssertEqual(refusal, .refused(state: state, event: event, reason: Release.failedOnce))
            }
        }
    }

    func testTheBuildThatDidNotChangeTheBinaryIsRefusedAndSaysNothing() throws {
        let change = try apply(.unchanged, to: .applying).get()
        XCTAssertEqual(change.record.written.state, .refused)
        XCTAssertEqual(change.effects.count, 0, "the v0.32.4 guard only logs")
    }

    func testAnApplyingThatNobodyConfirmedBecomesRefusedOnItsOwnAfterThirtyMinutes() throws {
        let start = Moment(sinceEpoch: .seconds(1_767_225_600))
        let applying = record(in: .applying, at: start)
        XCTAssertEqual(applying.state(at: start + .seconds(30 * 60 - 1)), .applying)
        XCTAssertEqual(applying.state(at: start + .seconds(30 * 60)), .refused)
        XCTAssertEqual(applying.read(at: start + .seconds(31 * 60)).pending.first?.by, .timeout)
    }

    func testADownloadThatNeverEndedIsOfferedAgainAndAStagedOneAWeekLater() {
        let start = Moment(sinceEpoch: .seconds(1_767_225_600))
        XCTAssertEqual(record(in: .downloading, at: start).state(at: start + .seconds(30 * 60)), .offered)
        XCTAssertEqual(record(in: .staged, at: start).state(at: start + .seconds(7 * 24 * 3_600 - 1)), .staged)
        XCTAssertEqual(record(in: .staged, at: start).state(at: start + .seconds(7 * 24 * 3_600)), .offered)
    }

    func testAnIncompatibleBuildIsRefusedWhereItIsBeingDownloaded() throws {
        XCTAssertEqual(try apply(.incompatible, to: .downloading).get().record.written.state, .refused)
        XCTAssertEqual(try apply(.failed, to: .downloading).get().record.written.state, .offered)
        XCTAssertEqual(try apply(.abandon, to: .staged).get().record.written.state, .offered)
        XCTAssertEqual(try apply(.failed, to: .staged).get().record.written.state, .offered)
    }

    // MARK: - Walks

    /// Whatever happens, in whatever order: a rollback or a refusal is never left, an announcement is
    /// said only on entering running or rolled back (one each), and the guards that only log say nothing.
    func testNoWalkLeavesAFailedHandoverOrSaysAnythingItShouldNot() {
        for start in Release.State.allCases {
            let violation = randomWalks(Release.self, from: start, by: .updater, events: events, seed: 7) { _, entries in
                for entry in entries {
                    if entry.entered, entry.from == .rolledBack || entry.from == .refused {
                        return "left \(entry.from) by \(entry.event)"
                    }
                    let announced = entry.effects.count
                    let enters = entry.entered && (entry.to == .running || entry.to == .rolledBack)
                    if announced != (enters ? 1 : 0) {
                        return "\(announced) announcement(s) on \(entry.from) → \(entry.to) by \(entry.event)"
                    }
                    if announced > 0, !(entry.event == .confirm && entry.to == .running)
                        && !(entry.event == .rollBack && entry.to == .rolledBack) {
                        return "announced on \(entry.event)"
                    }
                    if [.unchanged, .stall, .incompatible].contains(entry.event), announced > 0 {
                        return "\(entry.event) announced"
                    }
                }
                return nil
            }
            XCTAssertNil(violation.map(String.init(describing:)), "walks from \(start)")
        }
    }

    // MARK: - The id

    func testAReleaseHasOneIdWhateverItIsCalled() {
        for text in ["v0.54.25", "0.54.25", "0.54.25.0", "v0.54.25.0.0"] {
            XCTAssertEqual(Release.id(for: text), "0.54.25", text)
        }
        XCTAssertEqual(Release.id(for: "0.10"), "0.10.0", "missing places read as zero, as the updater reads them")
        XCTAssertEqual(Release.id(for: "0.54.25.1"), "0.54.25.1", "a fourth place that is not zero is a release of its own")
        XCTAssertNotEqual(Release.id(for: "0.54.25"), Release.id(for: "0.54.2"))
        XCTAssertNil(Release.id(for: ""))
        XCTAssertNil(Release.id(for: "latest"))
        XCTAssertNil(Release.id(for: "0.54.x"))
    }

    func testTheIdAgreesWithTheUpdatersOwnRuleForSameVersion() {
        for (a, b) in [("0.18", "0.18.0"), ("v1.2.3", "1.2.3.0"), ("0.9.10", "0.9.9")] {
            let same = Updater.sameVersion(Updater.parseVersion(a)!, Updater.parseVersion(b)!)
            XCTAssertEqual(Release.id(for: a) == Release.id(for: b), same, "\(a) and \(b)")
        }
    }
}
