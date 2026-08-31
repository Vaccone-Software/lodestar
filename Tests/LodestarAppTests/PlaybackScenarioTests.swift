import XCTest
@testable import lodestar
@testable import LodestarCore

/// Music steps aside while the draft listens — but only on a shared
/// Bluetooth radio, only when something was verifiably playing, and it
/// resumes only what it watched stop. The stage's system never reacts
/// on its own: each test scripts what the ⏯ key did, the way the real
/// Now Playing app would or would not obey it.
final class PlaybackScenarioTests: XCTestCase {
    /// A shared radio with music standing through both roll calls: the
    /// key goes out, the app obeys, and the resume follows the closed
    /// draft as soon as the output is a music profile again.
    func testMusicPausesForTheDraftAndResumesAtItsEnd() {
        let stage = Stage()
        stage.sharedRoute = true
        stage.playing = [500]
        stage.lode(".")
        XCTAssertEqual(stage.mediaKeys, 0, "one roll call is not proof of music")
        stage.clock.advance(by: 0.25)
        XCTAssertEqual(stage.mediaKeys, 1, "standing in both roll calls, it is paused")
        stage.playing = []
        stage.clock.advance(by: 0.8)
        _ = stage.press("return")
        XCTAssertEqual(stage.mediaKeys, 2, "the profile is already musical, so resume at once")
    }

    /// The output is still on the hands-free profile when the draft
    /// closes: the resume waits for the rate to rise, not for a timer.
    func testResumeWaitsForTheMusicProfile() {
        let stage = Stage()
        stage.sharedRoute = true
        stage.playing = [500]
        stage.lode(".")
        stage.clock.advance(by: 0.25)
        stage.playing = []
        stage.clock.advance(by: 0.8)
        stage.setOutputRate(16_000)
        _ = stage.press("return")
        XCTAssertEqual(stage.mediaKeys, 1, "resuming into the telephone band helps no one")
        stage.setOutputRate(44_100)
        XCTAssertEqual(stage.mediaKeys, 2, "the profile returned, and so did the music")
        stage.clock.advance(by: 5)
        XCTAssertEqual(stage.mediaKeys, 2, "the backstop was cancelled by the real resume")
    }

    /// The user pressed play themselves while the resume was owed: the
    /// debt is settled, and a ⏯ on top would pause them again.
    func testAHandRestartOwesNoResume() {
        let stage = Stage()
        stage.sharedRoute = true
        stage.playing = [500]
        stage.lode(".")
        stage.clock.advance(by: 0.25)
        stage.playing = []
        stage.clock.advance(by: 0.8)
        stage.setOutputRate(16_000)
        _ = stage.press("return")
        stage.playing = [500]
        stage.setOutputRate(44_100)
        XCTAssertEqual(stage.mediaKeys, 1, "audible again means resumed by hand, not by us")
        stage.clock.advance(by: 5)
        XCTAssertEqual(stage.mediaKeys, 1, "and the backstop owes nothing either")
    }

    /// A profile that never comes back cannot hold the music forever.
    func testResumeBackstopFiresWhenTheProfileNeverReturns() {
        let stage = Stage()
        stage.sharedRoute = true
        stage.playing = [500]
        stage.lode(".")
        stage.clock.advance(by: 0.25)
        stage.playing = []
        stage.clock.advance(by: 0.8)
        stage.setOutputRate(16_000)
        _ = stage.press("return")
        stage.clock.advance(by: 3)
        XCTAssertEqual(stage.mediaKeys, 2, "three seconds is as long as the music waits")
    }

    /// A keyboard-click app is loud in one roll call and gone in the
    /// next; it never draws a key.
    func testABurstyOutputterIsNotMusic() {
        let stage = Stage()
        stage.sharedRoute = true
        stage.playing = [700]
        stage.lode(".")
        stage.playing = []
        stage.clock.advance(by: 2)
        XCTAssertEqual(stage.mediaKeys, 0, "a click is not a song")
    }

    /// Wired headphones, a desk microphone: no shared radio, no flip,
    /// and nothing to protect anyone from.
    func testNoKeyWithoutASharedBluetoothRoute() {
        let stage = Stage()
        stage.sharedRoute = false
        stage.playing = [500]
        stage.lode(".")
        stage.clock.advance(by: 2)
        XCTAssertEqual(stage.mediaKeys, 0)
    }

    /// A call keeps playing through the key, because a call is not a
    /// Now Playing app: nothing stopped, so nothing is owed a resume.
    func testNothingStoppedMeansNothingIsResumed() {
        let stage = Stage()
        stage.sharedRoute = true
        stage.playing = [600]
        stage.lode(".")
        stage.clock.advance(by: 0.25)
        XCTAssertEqual(stage.mediaKeys, 1)
        stage.clock.advance(by: 0.8)
        _ = stage.press("return")
        stage.clock.advance(by: 5)
        XCTAssertEqual(stage.mediaKeys, 1, "no resume for a pause that did nothing")
    }

    /// The toggle's one wrong action: nothing was pausable and the key
    /// started something instead. It is undone on the spot.
    func testAKeyThatStartedSomethingIsUndone() {
        let stage = Stage()
        stage.sharedRoute = true
        stage.playing = [500]
        stage.lode(".")
        stage.clock.advance(by: 0.25)
        XCTAssertEqual(stage.mediaKeys, 1)
        stage.playing = [500, 900]
        stage.clock.advance(by: 0.8)
        XCTAssertEqual(stage.mediaKeys, 2, "the misfire is undone at once")
        _ = stage.press("return")
        stage.clock.advance(by: 5)
        XCTAssertEqual(stage.mediaKeys, 2, "and nothing more is ever sent for it")
    }

    /// A draft closed before the second roll call never sent a key, so
    /// there is nothing to undo and nothing ever fires late.
    func testAShortDraftSendsNoKeyAtAll() {
        let stage = Stage()
        stage.sharedRoute = true
        stage.playing = [500]
        stage.lode(".")
        stage.clock.advance(by: 0.1)
        _ = stage.press("return")
        stage.clock.advance(by: 5)
        XCTAssertEqual(stage.mediaKeys, 0)
    }

    /// A new draft before the owed resume: the quiet carries over, and
    /// one resume follows the last draft's end.
    func testTheNextDraftInheritsThePause() {
        let stage = Stage()
        stage.sharedRoute = true
        stage.playing = [500]
        stage.lode(".")
        stage.clock.advance(by: 0.25)
        stage.playing = []
        stage.clock.advance(by: 0.8)
        stage.setOutputRate(16_000)
        _ = stage.press("return")
        XCTAssertEqual(stage.mediaKeys, 1, "the resume is pending, not sent")
        stage.lode(".")
        stage.clock.advance(by: 5)
        XCTAssertEqual(stage.mediaKeys, 1, "the pause stands through the second draft")
        _ = stage.press("return")
        stage.setOutputRate(44_100)
        XCTAssertEqual(stage.mediaKeys, 2, "one resume, after the last draft")
    }
}
