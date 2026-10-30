import XCTest
@testable import LodestarCore

/// Secure input left on: said only when it is stuck in an app at the back,
/// after two samples, and taken down the moment it is not.
final class SecureInputNoticeTests: XCTestCase {
    let brave = SecureInputNotice.Holder(pid: 2154, name: "Brave Browser", bundleID: "com.brave.Browser")
    let ghostty = SecureInputNotice.Holder(pid: 1377, name: "Ghostty", bundleID: "com.mitchellh.ghostty")
    let ownPID: Int32 = 852

    func stuck(_ holder: SecureInputNotice.Holder, front: Int32 = 1377) -> SecureInputNotice.Sample {
        .init(on: true, holder: holder, frontPID: front, screenLocked: false)
    }

    let off = SecureInputNotice.Sample(on: false, holder: nil, frontPID: 1377, screenLocked: false)

    func testTwoStuckSamplesInARowBringTheNoticeAndItIsShownOnce() {
        var notice = SecureInputNotice(ownPID: ownPID)
        XCTAssertEqual(notice.sample(stuck(brave)), .none, "one sample could be a field letting go")
        XCTAssertEqual(notice.sample(stuck(brave)), .show(brave))
        XCTAssertEqual(notice.sample(stuck(brave)), .none, "already on the glass")
        XCTAssertEqual(notice.showing, brave)
    }

    func testSecureInputEndingTakesItDownAndSaysTheKeysAreBack() {
        var notice = SecureInputNotice(ownPID: ownPID)
        _ = notice.sample(stuck(brave))
        _ = notice.sample(stuck(brave))
        XCTAssertEqual(notice.sample(off), .hide(keysBack: true))
        XCTAssertNil(notice.showing)
        XCTAssertEqual(notice.sample(off), .none, "nothing standing, nothing to take down")
    }

    func testTheHolderInFrontIsSomeoneTypingAPassword() {
        var notice = SecureInputNotice(ownPID: ownPID)
        XCTAssertEqual(notice.sample(stuck(brave, front: brave.pid)), .none)
        XCTAssertEqual(notice.sample(stuck(brave, front: brave.pid)), .none)
        _ = notice.sample(stuck(brave))
        _ = notice.sample(stuck(brave))
        XCTAssertEqual(notice.sample(stuck(brave, front: brave.pid)), .hide(keysBack: false),
                       "brought forward, it goes quiet, but the keys are not back yet")
        XCTAssertEqual(notice.sample(stuck(brave)), .none, "back again, it waits two samples again")
        XCTAssertEqual(notice.sample(stuck(brave)), .show(brave))
    }

    func testALockedScreenIsTheLoginWindowsAndSaysNothing() {
        var notice = SecureInputNotice(ownPID: ownPID)
        let locked = SecureInputNotice.Sample(on: true, holder: brave, frontPID: 1377, screenLocked: true)
        XCTAssertEqual(notice.sample(locked), .none)
        XCTAssertEqual(notice.sample(locked), .none)
    }

    func testAnUnknownHolderOrLodestarItselfIsNotNamed() {
        var notice = SecureInputNotice(ownPID: ownPID)
        let unknown = SecureInputNotice.Sample(on: true, holder: nil, frontPID: 1377, screenLocked: false)
        XCTAssertEqual(notice.sample(unknown), .none)
        XCTAssertEqual(notice.sample(unknown), .none)
        let own = SecureInputNotice.Holder(pid: ownPID, name: "Lodestar", bundleID: nil)
        XCTAssertEqual(notice.sample(stuck(own)), .none)
        XCTAssertEqual(notice.sample(stuck(own)), .none)
    }

    func testANewHolderStartsItsOwnCount() {
        var notice = SecureInputNotice(ownPID: ownPID)
        let zoom = SecureInputNotice.Holder(pid: 6849, name: "zoom.us", bundleID: "us.zoom.xos")
        _ = notice.sample(stuck(brave))
        XCTAssertEqual(notice.sample(stuck(zoom)), .none, "one sample of the new holder")
        XCTAssertEqual(notice.sample(stuck(zoom)), .show(zoom))
    }

    /// The flash grammar: a needs-you mark, the fact, the way on a second
    /// line; no dashes, semicolons or closing period.
    func testTheWordsNameTheAppAndTheWayOutForItsKind() {
        XCTAssertEqual(SecureInputNotice.fact(brave), "⚠ Brave Browser is holding Secure Input")
        XCTAssertEqual(SecureInputNotice.way(brave),
                       "Lodestar hears no keys until you leave its password field or quit it")
        XCTAssertEqual(SecureInputNotice.way(ghostty),
                       "Lodestar hears no keys until you finish or cancel its password prompt",
                       "quitting a terminal takes its sessions with it")
        for line in [SecureInputNotice.fact(brave), SecureInputNotice.way(brave), SecureInputNotice.way(ghostty),
                     SecureInputNotice.keysBack] {
            XCTAssertFalse(line.contains("—") || line.contains(";") || line.hasSuffix("."), line)
        }
    }
}
