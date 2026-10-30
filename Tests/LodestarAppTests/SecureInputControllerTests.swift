import XCTest
import LodestarCore
@testable import lodestar

/// The held key: up when secure input is stuck, a click brings the holder
/// forward, nothing the hand does takes it down, and when secure input
/// ends the key is lit and the row leaves once that has been read.
final class SecureInputControllerTests: XCTestCase {
    let brave = SecureInputNotice.Holder(pid: 2154, name: "Brave Browser", bundleID: "com.brave.Browser")

    func testStuckSecureInputHoldsTheKeyUntilItEndsAndThenLightsIt() {
        var pending: [DispatchWorkItem] = []
        let notice = HeldKeyNotice(clock: Clock(now: { Date() }, after: { _, work in pending.append(work) }))
        let controller = SecureInputController()
        var sample = SecureInputNotice.Sample(on: true, holder: brave, frontPID: 1377, screenLocked: false)
        var brought: [Int32] = []
        controller.read = { sample }
        controller.icon = { _ in NSImage(size: NSSize(width: 36, height: 36)) }
        controller.bringForward = { brought.append($0) }
        controller.show = { holder, icon, onClick in notice.show(holder, icon: icon, onClick: onClick) }
        controller.hide = { keysBack in keysBack ? notice.keysBack() : notice.hide() }

        controller.tick()
        XCTAssertFalse(notice.isUp, "one sample is not stuck yet")
        controller.tick()
        XCTAssertTrue(notice.standing)
        XCTAssertTrue(notice.holderShown)
        XCTAssertEqual(notice.words, "Brave Browser is holding your keys")
        XCTAssertEqual(notice.key?.legend, "lode")
        XCTAssertEqual(notice.key?.state, .quiet, "the key no press can reach is drawn quiet")

        notice.click()
        XCTAssertEqual(brought, [2154], "a click brings the holder forward")

        sample = .init(on: false, holder: nil, frontPID: 1377, screenLocked: false)
        controller.tick()
        XCTAssertTrue(notice.isUp)
        XCTAssertFalse(notice.standing, "no longer asking")
        XCTAssertFalse(notice.holderShown, "the holder goes with the hold")
        XCTAssertEqual(notice.key?.state, .lit)
        XCTAssertEqual(notice.words, "Your keys are back")
        notice.click()
        XCTAssertEqual(brought, [2154], "a click on the lit key brings nothing forward")

        pending.forEach { $0.perform() }
        XCTAssertFalse(notice.isUp, "it leaves once read")
    }

    func testBringingTheHolderForwardTakesItDownWithoutLighting() {
        let notice = HeldKeyNotice()
        let controller = SecureInputController()
        var sample = SecureInputNotice.Sample(on: true, holder: brave, frontPID: 1377, screenLocked: false)
        controller.read = { sample }
        controller.icon = { _ in nil }
        controller.show = { holder, icon, onClick in notice.show(holder, icon: icon, onClick: onClick) }
        controller.hide = { keysBack in keysBack ? notice.keysBack() : notice.hide() }
        controller.tick()
        controller.tick()
        XCTAssertTrue(notice.standing)
        sample = .init(on: true, holder: brave, frontPID: brave.pid, screenLocked: false)
        controller.tick()
        XCTAssertFalse(notice.isUp, "the keys are not back, so the key does not light")
    }
}
