import XCTest
@testable import LodestarCore

final class WalkTests: XCTestCase {
    private let drafted = [StarterGraph.Proposal(letter: "b", app: "Brave"),
                           StarterGraph.Proposal(letter: "s", app: "Slack")]

    // MARK: - The happy path, fresh install

    func testFreshWalkRunsTheFullSequence() {
        var walk = Walk(proposals: drafted, existingLetter: nil)
        XCTAssertEqual(walk.step, .lodeKey)

        XCTAssertEqual(walk.handle(.peeked), [.stepChanged])
        XCTAssertEqual(walk.step, .launcher)

        XCTAssertEqual(walk.handle(.launcherPick), [.stepChanged])
        XCTAssertEqual(walk.step, .graphOffer(drafted))

        XCTAssertEqual(walk.handle(.assent), [.acceptProposals(drafted), .stepChanged])
        XCTAssertEqual(walk.step, .graphGo(letter: "b"))

        XCTAssertEqual(walk.handle(.graphSummon), [.stepChanged])
        XCTAssertEqual(walk.step, .sheet)

        XCTAssertEqual(walk.handle(.cheatOpened), [.stepChanged, .completed])
        XCTAssertEqual(walk.step, .done)
        XCTAssertTrue(walk.isDone)
    }

    // MARK: - Existing users

    func testExistingGraphSkipsTheOfferAndUsesTheirLetter() {
        var walk = Walk(proposals: [], existingLetter: "g")
        _ = walk.handle(.peeked)
        XCTAssertEqual(walk.handle(.launcherPick), [.stepChanged])
        XCTAssertEqual(walk.step, .graphGo(letter: "g"),
                       "nothing to offer — the walk teaches on their own graph")
    }

    func testNoProposalsAndNoGraphFallsToTheSheet() {
        var walk = Walk(proposals: [], existingLetter: nil)
        _ = walk.handle(.peeked)
        _ = walk.handle(.launcherPick)
        XCTAssertEqual(walk.step, .sheet,
                       "a graph step nobody can perform is not offered")
    }

    // MARK: - Declining the offer

    func testPassOnTheOfferDeclinesWithoutWriting() {
        var walk = Walk(proposals: drafted, existingLetter: "g")
        _ = walk.handle(.peeked)
        _ = walk.handle(.launcherPick)
        let effects = walk.handle(.pass)
        XCTAssertFalse(effects.contains(.acceptProposals(drafted)),
                       "declined letters are never written")
        XCTAssertEqual(walk.step, .graphGo(letter: "g"),
                       "declined, the graph step falls back to a letter they own")
    }

    func testPassOnTheOfferWithNoGraphSkipsTheGraphStep() {
        var walk = Walk(proposals: drafted, existingLetter: nil)
        _ = walk.handle(.peeked)
        _ = walk.handle(.launcherPick)
        _ = walk.handle(.pass)
        XCTAssertEqual(walk.step, .sheet,
                       "declined proposals must not be taught as if accepted")
    }

    // MARK: - Skipping

    func testEveryStepCanBePassed() {
        var walk = Walk(proposals: drafted, existingLetter: nil)
        var effects: [Walk.Effect] = []
        for _ in 0..<10 where !walk.isDone {
            effects = walk.handle(.pass)
        }
        XCTAssertTrue(walk.isDone, "pass alone must reach the end — nobody is trapped")
        XCTAssertEqual(effects, [.stepChanged, .completed])
    }

    func testDoneIgnoresEverything() {
        var walk = Walk(proposals: [], existingLetter: nil, resumeAt: 5)
        XCTAssertTrue(walk.isDone)
        for signal: Walk.Signal in [.peeked, .launcherPick, .assent, .pass,
                                    .graphSummon, .cheatOpened] {
            XCTAssertEqual(walk.handle(signal), [])
        }
    }

    // MARK: - Signals the step is not waiting for

    func testUnexpectedSignalsAreIgnored() {
        var walk = Walk(proposals: drafted, existingLetter: nil)
        XCTAssertEqual(walk.handle(.graphSummon), [])
        XCTAssertEqual(walk.handle(.cheatOpened), [])
        XCTAssertEqual(walk.handle(.assent), [],
                       "assent means nothing when no offer stands")
        XCTAssertEqual(walk.step, .lodeKey)
    }

    // MARK: - Resume

    func testResumeLandsOnThePersistedStep() {
        let walk = Walk(proposals: drafted, existingLetter: nil, resumeAt: 2)
        XCTAssertEqual(walk.step, .graphOffer(drafted))
        XCTAssertEqual(walk.stepIndex, 2)
    }

    func testResumeToAnOfferThatNoLongerExistsResolvesForward() {
        let walk = Walk(proposals: [], existingLetter: "g", resumeAt: 2)
        XCTAssertEqual(walk.step, .graphGo(letter: "g"))
    }

    func testResumeToAGraphStepWithNothingToPressResolvesToTheSheet() {
        let walk = Walk(proposals: [], existingLetter: nil, resumeAt: 3)
        XCTAssertEqual(walk.step, .sheet)
    }

    func testStepIndexRoundTrips() {
        var walk = Walk(proposals: drafted, existingLetter: nil)
        _ = walk.handle(.peeked)
        let resumed = Walk(proposals: drafted, existingLetter: nil,
                           resumeAt: walk.stepIndex)
        XCTAssertEqual(resumed.step, walk.step)
    }
}
