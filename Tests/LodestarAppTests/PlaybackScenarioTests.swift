import XCTest
@testable import lodestar
@testable import LodestarCore

/// Music steps aside while the draft listens — but only on a shared
/// Bluetooth radio, only players that said "playing", and only what
/// was paused is ever owed a resume. The players are asked directly,
/// so there is no toggle to distrust: the fake ones obey a pause and
/// a play the way Music does.
final class PlaybackScenarioTests: XCTestCase {
    /// A shared radio with music playing: paused the moment listening
    /// starts, resumed after the draft when the profile is musical.
    func testMusicPausesForTheDraftAndResumesAtItsEnd() {
        let stage = Stage()
        stage.sharedRoute = true
        stage.playing = ["com.apple.Music"]
        stage.lode(".")
        XCTAssertEqual(stage.pausedPlayers, ["com.apple.Music"], "paused as listening starts")
        _ = stage.press("return")
        XCTAssertEqual(stage.playedPlayers, ["com.apple.Music"], "the profile is musical, so resume at once")
    }

    /// The output is still on the hands-free profile when the draft
    /// closes: the resume waits for the rate to rise, not for a timer.
    func testResumeWaitsForTheMusicProfile() {
        let stage = Stage()
        stage.sharedRoute = true
        stage.playing = ["com.apple.Music"]
        stage.lode(".")
        stage.setOutputRate(16_000)
        _ = stage.press("return")
        XCTAssertTrue(stage.playedPlayers.isEmpty, "resuming into the telephone band helps no one")
        stage.setOutputRate(44_100)
        XCTAssertEqual(stage.playedPlayers, ["com.apple.Music"], "the profile returned, and so did the music")
        stage.clock.advance(by: 5)
        XCTAssertEqual(stage.playedPlayers.count, 1, "the backstop was cancelled by the real resume")
    }

    /// A profile that never comes back cannot hold the music forever.
    func testResumeBackstopFiresWhenTheProfileNeverReturns() {
        let stage = Stage()
        stage.sharedRoute = true
        stage.playing = ["com.apple.Music"]
        stage.lode(".")
        stage.setOutputRate(16_000)
        _ = stage.press("return")
        stage.clock.advance(by: 3)
        XCTAssertEqual(stage.playedPlayers, ["com.apple.Music"], "three seconds is as long as the music waits")
    }

    /// Wired headphones, a desk microphone: no shared radio, no flip,
    /// and the players are never even asked.
    func testNoPauseWithoutASharedBluetoothRoute() {
        let stage = Stage()
        stage.sharedRoute = false
        stage.playing = ["com.apple.Music"]
        stage.lode(".")
        stage.clock.advance(by: 5)
        XCTAssertTrue(stage.pausedPlayers.isEmpty)
    }

    /// No player says "playing": nothing is paused, nothing is owed.
    func testNothingPlayingMeansNothingHappens() {
        let stage = Stage()
        stage.sharedRoute = true
        stage.lode(".")
        _ = stage.press("return")
        stage.clock.advance(by: 5)
        XCTAssertTrue(stage.pausedPlayers.isEmpty)
        XCTAssertTrue(stage.playedPlayers.isEmpty)
    }

    /// The user pressed play themselves while the resume was owed: the
    /// debt is settled, and a play on top would not be theirs.
    func testAHandRestartOwesNoResume() {
        let stage = Stage()
        stage.sharedRoute = true
        stage.playing = ["com.apple.Music"]
        stage.lode(".")
        stage.setOutputRate(16_000)
        _ = stage.press("return")
        stage.playing = ["com.apple.Music"]
        stage.setOutputRate(44_100)
        XCTAssertTrue(stage.playedPlayers.isEmpty, "audible again means resumed by hand, not by us")
        stage.clock.advance(by: 5)
        XCTAssertTrue(stage.playedPlayers.isEmpty, "and the backstop owes nothing either")
    }

    /// Two players playing: both paused, both resumed.
    func testEveryPlayingPlayerIsPausedAndResumed() {
        let stage = Stage()
        stage.sharedRoute = true
        stage.playing = ["com.apple.Music", "com.spotify.client"]
        stage.lode(".")
        XCTAssertEqual(stage.pausedPlayers.sorted(), ["com.apple.Music", "com.spotify.client"])
        _ = stage.press("return")
        XCTAssertEqual(stage.playedPlayers.sorted(), ["com.apple.Music", "com.spotify.client"])
    }

    /// A new draft before the owed resume: the quiet carries over, and
    /// one resume follows the last draft's end.
    func testTheNextDraftInheritsThePause() {
        let stage = Stage()
        stage.sharedRoute = true
        stage.playing = ["com.apple.Music"]
        stage.lode(".")
        stage.setOutputRate(16_000)
        _ = stage.press("return")
        XCTAssertTrue(stage.playedPlayers.isEmpty, "the resume is pending, not sent")
        stage.lode(".")
        stage.clock.advance(by: 5)
        XCTAssertTrue(stage.playedPlayers.isEmpty, "the pause stands through the second draft")
        _ = stage.press("return")
        stage.setOutputRate(44_100)
        XCTAssertEqual(stage.playedPlayers, ["com.apple.Music"], "one resume, after the last draft")
    }
}

/// The draft begins twice when the Mac's microphone stands in for a
/// waking headset: on the Mac's microphone, then on the headset. The
/// second arrives while the first question is still out.
final class PlaybackHandoverTests: XCTestCase {
    func testAHeadsetThatTakesOverWhileTheRouteIsAskedIsStillAsked() {
        var asks: [(String?, (Bool) -> Void)] = []
        var paused = 0
        let world = PlaybackPause.World(
            sharedRoute: { input, done in asks.append((input, done)) },
            pausePlaying: { done in paused += 1; done(["com.apple.Music"]) },
            resumePlayers: { owed, done in done(owed) },
            audibleTabs: { done in done(0) }, pressPlayPause: {},
            outputRate: { done in done(44_100) },
            watchRate: { _ in {} })
        let pause = PlaybackPause(world: world, clock: VirtualClock().clock)
        pause.dictationBegan(input: "MacBook Pro Microphone")
        pause.dictationBegan(input: "Cypress")          // the headset, while the first ask is out
        XCTAssertEqual(asks.map(\.0), ["MacBook Pro Microphone"])
        asks[0].1(false)                                // the Mac's microphone shares no radio
        XCTAssertEqual(asks.map(\.0), ["MacBook Pro Microphone", "Cypress"], "the headset is asked about too")
        asks[1].1(true)
        XCTAssertEqual(paused, 1, "and the music steps aside")
    }

    func testTheSameInputTwiceIsAskedOnce() {
        var asks: [String?] = []
        let world = PlaybackPause.World(
            sharedRoute: { input, done in asks.append(input); DispatchQueue.main.async { done(false) } },
            pausePlaying: { done in done([]) }, resumePlayers: { owed, done in done(owed) },
            audibleTabs: { done in done(0) }, pressPlayPause: {},
            outputRate: { done in done(44_100) }, watchRate: { _ in {} })
        let pause = PlaybackPause(world: world, clock: VirtualClock().clock)
        pause.dictationBegan(input: "Cypress")
        pause.dictationBegan(input: "Cypress")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(asks, ["Cypress"])
    }
}

/// A browser tab cannot be asked, but its label says it is making sound.
/// The ⏯ that answers it is a blind toggle, so every press is checked
/// once the label can be believed, about three seconds after the sound.
final class BrowserPauseScenarioTests: XCTestCase {
    private func makeStage(tabs: Int = 1) -> Stage {
        let stage = Stage()
        stage.sharedRoute = true
        stage.audibleTabs = tabs
        return stage
    }

    /// A video playing: pressed as listening starts, pressed again at the
    /// draft's end.
    func testAVideoPausesForTheDraftAndResumesAtItsEnd() {
        let stage = makeStage()
        stage.lode(".")
        XCTAssertEqual(stage.playPausePresses, 1, "pressed as listening starts")
        stage.clock.advance(by: PlaybackPause.tabCheck)
        XCTAssertEqual(stage.playPausePresses, 1, "the label fell, so the press stands")
        _ = stage.press("return")
        XCTAssertEqual(stage.playPausePresses, 2, "and the video is given back")
        XCTAssertEqual(stage.audibleTabs, 1)
    }

    /// No tab labelled, no press: the ⏯ never fires into silence.
    func testNoLabelMeansNoPress() {
        let stage = makeStage(tabs: 0)
        stage.lode(".")
        stage.clock.advance(by: 10)
        _ = stage.press("return")
        stage.clock.advance(by: 10)
        XCTAssertEqual(stage.playPausePresses, 0)
    }

    /// Wired headphones: the tabs are not even a question.
    func testNoPressWithoutASharedBluetoothRoute() {
        let stage = makeStage()
        stage.sharedRoute = false
        stage.lode(".")
        stage.clock.advance(by: 10)
        XCTAssertEqual(stage.playPausePresses, 0)
    }

    /// A player that answers is paused exactly, and the toggle stays out
    /// of it: with Music paused, the ⏯ could have resumed it.
    func testAPlayerThatAnswersKeepsTheToggleOut() {
        let stage = makeStage()
        stage.playing = ["com.apple.Music"]
        stage.lode(".")
        stage.clock.advance(by: 10)
        XCTAssertEqual(stage.pausedPlayers, ["com.apple.Music"])
        XCTAssertEqual(stage.playPausePresses, 0)
    }

    /// The hand paused the video just before the draft: the label is still
    /// up, and the press starts the video. The count did not fall, so one
    /// more press undoes it, and nothing is owed.
    func testAPressThatStartedAVideoIsUndone() {
        let stage = makeStage()
        var videoPlaying = false
        stage.onPlayPause = { videoPlaying.toggle() } // the label is up either way
        stage.lode(".")
        XCTAssertTrue(videoPlaying, "the blind toggle started it")
        stage.clock.advance(by: PlaybackPause.tabCheck)
        XCTAssertFalse(videoPlaying, "and the check stopped it")
        XCTAssertEqual(stage.playPausePresses, 2)
        _ = stage.press("return")
        stage.clock.advance(by: 10)
        XCTAssertEqual(stage.playPausePresses, 2, "the undone press owes no resume")
    }

    /// Music owned Now Playing, so the press started it. It answers, so it
    /// is paused exactly and the video is left as it was.
    func testAPressThatReachedAPlayerIsPausedExactly() {
        let stage = makeStage()
        stage.onPlayPause = { [unowned stage] in stage.playing.insert("com.apple.Music") }
        stage.lode(".")
        stage.clock.advance(by: PlaybackPause.tabCheck)
        XCTAssertEqual(stage.pausedPlayers, ["com.apple.Music"])
        XCTAssertTrue(stage.playing.isEmpty)
        XCTAssertEqual(stage.playPausePresses, 1, "no second toggle")
        _ = stage.press("return")
        stage.clock.advance(by: 10)
        XCTAssertEqual(stage.playPausePresses, 1, "nothing is owed")
        XCTAssertTrue(stage.playedPlayers.isEmpty, "and Music was never playing to begin with")
    }

    /// A draft shorter than the check: the resume waits for the verdict.
    func testADraftShorterThanTheCheckResumesAfterIt() {
        let stage = makeStage()
        stage.lode(".")
        _ = stage.press("return")
        XCTAssertEqual(stage.playPausePresses, 1, "the press is not believed yet")
        stage.clock.advance(by: PlaybackPause.tabCheck)
        XCTAssertEqual(stage.playPausePresses, 2, "the verdict came and the video went back")
        XCTAssertEqual(stage.audibleTabs, 1)
    }

    /// The resume waits for the music profile, as a player's does.
    func testTheVideoResumeWaitsForTheMusicProfile() {
        let stage = makeStage()
        stage.lode(".")
        stage.clock.advance(by: PlaybackPause.tabCheck)
        stage.setOutputRate(16_000)
        _ = stage.press("return")
        XCTAssertEqual(stage.playPausePresses, 1, "resuming into the telephone band helps no one")
        stage.setOutputRate(44_100)
        XCTAssertEqual(stage.playPausePresses, 2)
    }

    /// The hand pressed play during the draft: a press on top would pause
    /// what they just started.
    func testAHandRestartOwesNoPress() {
        let stage = makeStage()
        stage.lode(".")
        stage.clock.advance(by: PlaybackPause.tabCheck)
        stage.audibleTabs = 1
        _ = stage.press("return")
        stage.clock.advance(by: 10)
        XCTAssertEqual(stage.playPausePresses, 1)
    }

    /// Two tabs sounding, and the press silenced one: the other is no sign
    /// of a hand, so the paused one still goes back.
    func testAnotherAudibleTabIsNoSignOfAHand() {
        let stage = makeStage(tabs: 2)
        stage.lode(".")
        stage.clock.advance(by: PlaybackPause.tabCheck)
        XCTAssertEqual(stage.audibleTabs, 1)
        _ = stage.press("return")
        XCTAssertEqual(stage.playPausePresses, 2)
        XCTAssertEqual(stage.audibleTabs, 0, "the fake toggles one tab; the real ⏯ gives back the paused one")
    }

    /// A new draft before the owed resume keeps the quiet, and one press
    /// follows the last draft's end.
    func testTheNextDraftInheritsTheVideoPause() {
        let stage = makeStage()
        stage.lode(".")
        stage.clock.advance(by: PlaybackPause.tabCheck)
        stage.setOutputRate(16_000)
        _ = stage.press("return")
        stage.lode(".")
        stage.clock.advance(by: 10)
        XCTAssertEqual(stage.playPausePresses, 1, "the pause stands through the second draft")
        _ = stage.press("return")
        stage.setOutputRate(44_100)
        XCTAssertEqual(stage.playPausePresses, 2, "one press, after the last draft")
    }

    /// A session restart mid-draft begins again, and must not press again
    /// the toggle it just undid.
    func testARestartAfterAnUndoDoesNotPressAgain() {
        var presses = 0
        let clock = VirtualClock()
        let world = PlaybackPause.World(
            sharedRoute: { _, done in done(true) },
            pausePlaying: { done in done([]) }, resumePlayers: { owed, done in done(owed) },
            audibleTabs: { done in done(1) }, pressPlayPause: { presses += 1 },
            outputRate: { done in done(44_100) }, watchRate: { _ in {} })
        let pause = PlaybackPause(world: world, clock: clock.clock)
        pause.dictationBegan(input: "Cypress")
        clock.advance(by: PlaybackPause.tabCheck)
        XCTAssertEqual(presses, 2, "pressed, then undone")
        pause.dictationBegan(input: "Cypress")
        clock.advance(by: PlaybackPause.tabCheck)
        XCTAssertEqual(presses, 2, "once a draft")
        pause.dictationEnded()
        pause.dictationBegan(input: "Cypress")
        XCTAssertEqual(presses, 3, "a new draft may ask again")
    }

    /// The label as Brave 156 names a tab, and where it stops being one.
    func testTheLabel() {
        XCTAssertTrue(BrowserTabs.isAudible("A video - YouTube - Audio playing"))
        XCTAssertTrue(BrowserTabs.isAudible("A video - YouTube - Audio playing - Memory usage - 1.0 GB"))
        XCTAssertFalse(BrowserTabs.isAudible("A video - YouTube - Memory usage - 1.0 GB"))
        XCTAssertFalse(BrowserTabs.isAudible("Audio playing tips"))
    }
}
