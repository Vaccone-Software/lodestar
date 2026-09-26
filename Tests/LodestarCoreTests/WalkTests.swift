import XCTest
@testable import LodestarCore

final class WalkTests: XCTestCase {
    private let drafted = [StarterGraph.Proposal(letter: "b", app: "Brave"),
                           StarterGraph.Proposal(letter: "s", app: "Slack")]
    private let draftedChoices = [Walk.GraphChoice(path: "b", label: "Brave"),
                                  Walk.GraphChoice(path: "s", label: "Slack")]
    private let ownGraph = [Walk.GraphChoice(path: "g", label: "Ghostty"),
                            Walk.GraphChoice(path: "b p", label: "Brave Personal")]
    private let everySignal: [Walk.Signal] = [
        .launcherPick, .assent, .pass, .graphSummon, .editorMarked, .editorFixed, .clipCopied,
        .draftLanded, .hintsEnded, .webBarOpened, .clipboardOpened, .cheatOpened, .draftOpened,
        .selectEnded, .commandsOpened, .scrollEnded,
    ]

    // MARK: - The doors

    func testTheFourDoorsAreNamedAndAddressedAsTheSiteSaysThem() {
        XCTAssertEqual(Walk.Door.allCases.map(\.name), ["Write", "Switch", "Keep", "Speak"])
        XCTAssertEqual(Walk.Door.allCases.map(\.rawValue), ["write", "switch", "keep", "speak"])
    }

    // MARK: - Switch: the launcher, then letters

    func testSwitchRunsLauncherThenTheOfferedLetters() {
        var walk = Walk(door: .switcher, proposals: drafted)
        XCTAssertEqual(walk.step, .launcher, "the launcher first: on day one it already works")
        XCTAssertEqual(walk.progress.total, 3)
        XCTAssertEqual(walk.progress.position, 1)

        XCTAssertEqual(walk.handle(.launcherPick), [.stepChanged])
        XCTAssertEqual(walk.step, .graphOffer(drafted))
        XCTAssertEqual(walk.progress.position, 2)

        XCTAssertEqual(walk.handle(.assent), [.acceptProposals(drafted), .stepChanged])
        XCTAssertEqual(walk.step, .graphGo(options: draftedChoices),
                       "the freshly kept letters are the ones to prove")
        XCTAssertEqual(walk.progress.position, 3)

        XCTAssertEqual(walk.handle(.graphSummon), [.stepChanged, .completed])
        XCTAssertTrue(walk.isDone)
    }

    func testSwitchWithAGraphAndNothingToOfferTeachesTheirOwnLetters() {
        var walk = Walk(door: .switcher, existing: ownGraph)
        XCTAssertEqual(walk.progress.total, 2, "no offer step, and the counter must not promise one")
        _ = walk.handle(.launcherPick)
        XCTAssertEqual(walk.step, .graphGo(options: ownGraph))
    }

    func testSwitchWithNothingToOfferOrPressIsTheLauncherAlone() {
        var walk = Walk(door: .switcher)
        XCTAssertEqual(walk.progress.total, 1)
        XCTAssertEqual(walk.handle(.launcherPick), [.stepChanged, .completed])
    }

    func testPassingTheOfferWritesNothingAndFallsBackToTheirGraph() {
        var walk = Walk(door: .switcher, proposals: drafted, existing: ownGraph)
        _ = walk.handle(.launcherPick)
        let effects = walk.handle(.pass)
        XCTAssertFalse(effects.contains(.acceptProposals(drafted)), "declined letters are never written")
        XCTAssertEqual(walk.step, .graphGo(options: ownGraph))
    }

    func testPassingTheOfferWithNoGraphEndsTheWalk() {
        var walk = Walk(door: .switcher, proposals: drafted)
        _ = walk.handle(.launcherPick)
        XCTAssertEqual(walk.handle(.pass), [.stepChanged, .completed],
                       "declined suggestions must not be taught as if kept")
    }

    // MARK: - Write: a typo, a fix, then the closer reader

    func testWriteWaitsForAMarkThenAFixThenOffersTheEngine() {
        var walk = Walk(door: .write, grammar: "standard")
        XCTAssertEqual(walk.step, .typo)
        XCTAssertEqual(walk.progress.total, 3)
        XCTAssertEqual(walk.handle(.editorFixed), [], "no fix before there is a line to fix")
        XCTAssertEqual(walk.handle(.editorMarked), [.stepChanged])
        XCTAssertEqual(walk.step, .fix)
        XCTAssertEqual(walk.handle(.editorFixed), [.stepChanged])
        XCTAssertEqual(walk.step, .grammar(engine: "standard"))
        XCTAssertEqual(walk.handle(.assent), [.chooseEngine("standard"), .stepChanged, .completed])
        XCTAssertTrue(walk.isDone)
    }

    func testWriteDeclinedKeepsSpellingAndChoosesNothing() {
        var walk = Walk(door: .write, grammar: "standard", resumeAt: 2)
        let effects = walk.handle(.pass)
        XCTAssertFalse(effects.contains(.chooseEngine("standard")))
        XCTAssertTrue(walk.isDone)
    }

    func testWriteOnAMacThatCanOnlySpellHasNoOffer() {
        var walk = Walk(door: .write)
        XCTAssertEqual(walk.progress.total, 2)
        _ = walk.handle(.editorMarked)
        XCTAssertEqual(walk.handle(.editorFixed), [.stepChanged, .completed])
    }

    // MARK: - Keep and Speak

    func testKeepWaitsForACopyThenTheStrip() {
        var walk = Walk(door: .keep)
        XCTAssertEqual(walk.handle(.clipboardOpened), [], "the strip before a copy teaches nothing")
        XCTAssertEqual(walk.handle(.clipCopied), [.stepChanged])
        XCTAssertEqual(walk.step, .strip)
        XCTAssertEqual(walk.handle(.clipboardOpened), [.stepChanged, .completed])
    }

    func testSpeakWaitsForTheDraftThenTheWordsLanding() {
        var walk = Walk(door: .speak)
        XCTAssertEqual(walk.step, .draft)
        XCTAssertEqual(walk.handle(.draftOpened), [.stepChanged])
        XCTAssertEqual(walk.step, .land)
        XCTAssertEqual(walk.handle(.draftLanded), [.stepChanged, .completed])
    }

    // MARK: - Every door

    func testEveryDoorCanBePassedToTheEnd() {
        for door in Walk.Door.allCases {
            var walk = Walk(door: door, proposals: drafted, existing: ownGraph, grammar: "standard")
            var effects: [Walk.Effect] = []
            for _ in 0..<12 where !walk.isDone { effects = walk.handle(.pass) }
            XCTAssertTrue(walk.isDone, "\(door): pass alone must reach the end, nobody is trapped")
            XCTAssertEqual(effects, [.stepChanged, .completed])
        }
    }

    func testDoneIgnoresEverything() {
        for door in Walk.Door.allCases {
            var walk = Walk(door: door, resumeAt: 9)
            XCTAssertTrue(walk.isDone)
            for signal in everySignal { XCTAssertEqual(walk.handle(signal), [], "\(door) \(signal)") }
        }
    }

    func testSignalsAnotherDoorWaitsOnAreIgnored() {
        var walk = Walk(door: .keep)
        for signal: Walk.Signal in [.launcherPick, .graphSummon, .editorMarked, .draftLanded, .assent] {
            XCTAssertEqual(walk.handle(signal), [], "\(signal)")
        }
        XCTAssertEqual(walk.step, .copy)
    }

    // MARK: - Resume

    func testResumeLandsOnThePersistedStepOfItsDoor() {
        XCTAssertEqual(Walk(door: .switcher, proposals: drafted, resumeAt: 1).step, .graphOffer(drafted))
        XCTAssertEqual(Walk(door: .write, grammar: "minimal", resumeAt: 2).step, .grammar(engine: "minimal"))
        XCTAssertEqual(Walk(door: .speak, resumeAt: 1).step, .land)
    }

    func testResumePastAStepThatNoLongerExistsResolvesForward() {
        XCTAssertEqual(Walk(door: .switcher, existing: ownGraph, resumeAt: 1).step, .graphGo(options: ownGraph),
                       "an offer with nothing to offer is skipped")
        XCTAssertTrue(Walk(door: .write, resumeAt: 2).isDone, "no engine to offer, nothing after the fix")
    }

    func testStepIndexRoundTrips() {
        for door in Walk.Door.allCases {
            var walk = Walk(door: door, proposals: drafted, grammar: "standard")
            _ = walk.handle(.pass)
            let resumed = Walk(door: door, proposals: drafted, grammar: "standard", resumeAt: walk.stepIndex)
            XCTAssertEqual(resumed.step, walk.step, "\(door)")
        }
    }
}
