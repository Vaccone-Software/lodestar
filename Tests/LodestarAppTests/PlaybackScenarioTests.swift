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
