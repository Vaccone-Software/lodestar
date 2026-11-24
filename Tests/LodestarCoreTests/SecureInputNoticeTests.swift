import XCTest
@testable import LodestarCore

/// Secure input left on: said only when the app that turned it on has gone
/// to the back and kept it, after two seconds, and taken down the moment it
/// is not. The samples are what the Mac reports: while secure input is on,
/// the session names the app in front, whoever turned it on.
final class SecureInputNoticeTests: XCTestCase {
    typealias Holder = SecureInputNotice.Holder
    let brave = Holder(pid: 2154, name: "Brave Browser", bundleID: "com.brave.Browser")
    let ghostty = Holder(pid: 1377, name: "Ghostty", bundleID: "com.mitchellh.ghostty")
    let mail = Holder(pid: 4410, name: "Mail", bundleID: "com.apple.mail")
    let ownPID: Int32 = 852

    /// Secure input on with `front` in front, named by the session as the
    /// holder, the way macOS names it.
    func on(_ front: Holder, locked: Bool = false) -> SecureInputNotice.Sample {
        .init(on: true, holder: front, frontPID: front.pid, screenLocked: locked)
    }

    func off(_ front: Holder) -> SecureInputNotice.Sample {
        .init(on: false, holder: nil, frontPID: front.pid, screenLocked: false)
    }

    /// The samples before the notice comes, each saying nothing.
    func waits(_ notice: inout SecureInputNotice, _ sample: SecureInputNotice.Sample,
               file: StaticString = #filePath, line: UInt = #line) {
        for _ in 1..<SecureInputNotice.samplesToShow {
            XCTAssertEqual(notice.sample(sample), .none, file: file, line: line)
        }
    }

    /// Brave turns it on in front and goes to the back. The session now
    /// names Ghostty, but Brave is the one remembered and named.
    func testTheAppThatTurnedItOnIsNamedAfterItGoesToTheBack() {
        var notice = SecureInputNotice(ownPID: ownPID)
        XCTAssertEqual(notice.sample(off(brave)), .none)
        XCTAssertEqual(notice.sample(on(brave)), .none, "Brave in front is someone typing a password")
        XCTAssertEqual(notice.enabler, brave)
        waits(&notice, on(ghostty))
        XCTAssertEqual(notice.sample(on(ghostty)), .show(brave))
        XCTAssertEqual(notice.sample(on(mail)), .none, "already on the glass, wherever the hand goes")
        XCTAssertEqual(notice.showing, brave)
    }

    func testSecureInputEndingTakesItDownAndSaysTheKeysAreBack() {
        var notice = SecureInputNotice(ownPID: ownPID)
        _ = notice.sample(off(brave))
        _ = notice.sample(on(brave))
        waits(&notice, on(ghostty))
        _ = notice.sample(on(ghostty))
        XCTAssertEqual(notice.sample(off(ghostty)), .hide(keysBack: true))
        XCTAssertNil(notice.showing)
        XCTAssertNil(notice.enabler)
        XCTAssertEqual(notice.sample(off(ghostty)), .none, "nothing standing, nothing to take down")
    }

    func testTheHolderBroughtForwardGoesQuietAndWaitsAgainWhenLeft() {
        var notice = SecureInputNotice(ownPID: ownPID)
        _ = notice.sample(off(brave))
        _ = notice.sample(on(brave))
        waits(&notice, on(ghostty))
        _ = notice.sample(on(ghostty))
        XCTAssertEqual(notice.sample(on(brave)), .hide(keysBack: false),
                       "brought forward, it goes quiet, but the keys are not back yet")
        waits(&notice, on(ghostty))
        XCTAssertEqual(notice.sample(on(ghostty)), .show(brave), "left again, it is named again")
    }

    /// A switch away that lets go within two seconds says nothing.
    func testAFieldThatLetsGoSoonSaysNothing() {
        var notice = SecureInputNotice(ownPID: ownPID)
        _ = notice.sample(off(brave))
        _ = notice.sample(on(brave))
        waits(&notice, on(ghostty))
        XCTAssertEqual(notice.sample(off(ghostty)), .none)
    }

    /// Already on when Lodestar starts: whoever is in front did not
    /// necessarily turn it on, so nobody is named until it has been off.
    func testSecureInputAlreadyOnAtLaunchNamesNobody() {
        var notice = SecureInputNotice(ownPID: ownPID)
        for front in [ghostty, mail, ghostty, mail, ghostty] {
            XCTAssertEqual(notice.sample(on(front)), .none)
        }
        XCTAssertNil(notice.enabler)
        _ = notice.sample(off(ghostty))
        _ = notice.sample(on(brave))
        waits(&notice, on(ghostty))
        XCTAssertEqual(notice.sample(on(ghostty)), .show(brave), "once seen beginning, it is named")
    }

    /// The login window holds it while the screen is locked; it is never
    /// put on the app in front once the screen unlocks.
    func testALockedScreenIsTheLoginWindowsAndNamesNobody() {
        var notice = SecureInputNotice(ownPID: ownPID)
        _ = notice.sample(off(ghostty))
        XCTAssertEqual(notice.sample(on(ghostty, locked: true)), .none)
        XCTAssertNil(notice.enabler)
        for _ in 0..<SecureInputNotice.samplesToShow * 2 {
            XCTAssertEqual(notice.sample(on(mail)), .none)
        }
    }

    /// Stuck behind a lock and still stuck after: Brave stays the holder.
    func testALockWhileStuckKeepsTheHolder() {
        var notice = SecureInputNotice(ownPID: ownPID)
        _ = notice.sample(off(brave))
        _ = notice.sample(on(brave))
        waits(&notice, on(ghostty))
        _ = notice.sample(on(ghostty))
        XCTAssertEqual(notice.sample(on(ghostty, locked: true)), .hide(keysBack: false))
        waits(&notice, on(ghostty))
        XCTAssertEqual(notice.sample(on(ghostty)), .show(brave))
    }

    func testAnUnknownHolderOrLodestarItselfIsNotNamed() {
        var notice = SecureInputNotice(ownPID: ownPID)
        _ = notice.sample(off(ghostty))
        let unknown = SecureInputNotice.Sample(on: true, holder: nil, frontPID: ghostty.pid, screenLocked: false)
        for _ in 0..<SecureInputNotice.samplesToShow * 2 {
            XCTAssertEqual(notice.sample(unknown), .none)
        }
        _ = notice.sample(off(ghostty))
        let own = Holder(pid: ownPID, name: "Lodestar", bundleID: nil)
        _ = notice.sample(on(own))
        for _ in 0..<SecureInputNotice.samplesToShow * 2 {
            XCTAssertEqual(notice.sample(on(ghostty)), .none)
        }
    }

    /// The line names the app from the hand's side; the way out, read aloud,
    /// fits its kind. No dashes, semicolons or closing period.
    func testTheWordsNameTheAppAndTheWayOutForItsKind() {
        XCTAssertEqual(SecureInputNotice.sentence(brave), "Brave Browser is holding your keys")
        XCTAssertEqual(SecureInputNotice.keysBack, "Your keys are back")
        XCTAssertEqual(SecureInputNotice.way(brave),
                       "Lodestar hears no keys until you leave its password field or quit it")
        XCTAssertEqual(SecureInputNotice.way(ghostty),
                       "Lodestar hears no keys until you finish or cancel its password prompt",
                       "quitting a terminal takes its sessions with it")
        for line in [SecureInputNotice.sentence(brave), SecureInputNotice.way(brave), SecureInputNotice.way(ghostty),
                     SecureInputNotice.keysBack] {
            XCTAssertFalse(line.contains("—") || line.contains(";") || line.hasSuffix("."), line)
        }
    }
}
