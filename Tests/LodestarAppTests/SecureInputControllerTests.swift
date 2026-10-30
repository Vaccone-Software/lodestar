import XCTest
import LodestarCore
@testable import lodestar

/// The notice on the glass: drawn when secure input is stuck, drawn again
/// when another surface let the glass go, taken down when it ends, and a
/// click brings the holder forward.
final class SecureInputControllerTests: XCTestCase {
    let brave = SecureInputNotice.Holder(pid: 2154, name: "Brave Browser", bundleID: "com.brave.Browser")

    func testStuckSecureInputStandsOnTheGlassUntilItEnds() {
        let hud = HUD()
        let controller = SecureInputController()
        var sample = SecureInputNotice.Sample(on: true, holder: brave, frontPID: 1377, screenLocked: false)
        var brought: [Int32] = []
        controller.read = { sample }
        controller.icon = { _ in nil }
        controller.bringForward = { brought.append($0) }
        controller.showNotice = { text, icon, onClick in hud.showNotice(text, icon: icon, onClick: onClick) }
        controller.hideNotice = { hud.hide() }
        controller.flash = { hud.flash($0) }
        controller.noticeStanding = { hud.owner == .notice }
        controller.glassFree = { hud.owner == SurfaceOwner.none }

        controller.tick()
        XCTAssertEqual(hud.owner, SurfaceOwner.none, "one sample is not stuck yet")
        controller.tick()
        XCTAssertEqual(hud.owner, .notice)
        XCTAssertEqual(hud.titleSymbol, "exclamationmark.triangle")
        XCTAssertEqual(hud.titleText, "Brave Browser is holding Secure Input")
        XCTAssertEqual(hud.titleWay, "Lodestar hears no keys until you leave its password field or quit it")

        hud.clickNotice()
        XCTAssertEqual(brought, [2154], "a click brings the holder forward")

        // Another surface takes the glass and lets it go: the next sample
        // draws the notice again.
        hud.flash("⟲ Layout redone")
        XCTAssertEqual(hud.owner, .flash)
        hud.hide()
        controller.tick()
        XCTAssertEqual(hud.owner, .notice)

        sample = .init(on: false, holder: nil, frontPID: 1377, screenLocked: false)
        controller.tick()
        XCTAssertEqual(hud.owner, .flash, "the notice goes and the keys-back flash takes its place")
        XCTAssertEqual(hud.titleText, "Lodestar hears your keys again")
        hud.hide()
    }

    func testANoticeIsNotKeptUpByAKey() {
        let hud = HUD()
        hud.showNotice("⚠ Brave Browser is holding Secure Input\nLodestar hears no keys", onClick: {})
        hud.keyStruck()
        XCTAssertEqual(hud.owner, .notice, "it goes when secure input does, not at a key")
        hud.hide()
        XCTAssertEqual(hud.owner, SurfaceOwner.none)
    }
}
