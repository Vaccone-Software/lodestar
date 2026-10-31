import XCTest
import LodestarCore
@testable import lodestar

/// The held key: up when secure input is stuck, a click brings the holder
/// forward, nothing the hand does takes it down, and when secure input
/// ends the key is lit and the row leaves once that has been read.
final class SecureInputControllerTests: XCTestCase {
    let brave = SecureInputNotice.Holder(pid: 2154, name: "Brave Browser", bundleID: "com.brave.Browser")
    let ghostty = SecureInputNotice.Holder(pid: 1377, name: "Ghostty", bundleID: "com.mitchellh.ghostty")

    func testStuckSecureInputHoldsTheKeyUntilItEndsAndThenLightsIt() {
        var pending: [DispatchWorkItem] = []
        let notice = HeldKeyNotice(clock: Clock(now: { Date() }, after: { _, work in pending.append(work) }))
        let controller = SecureInputController()
        var sample = SecureInputNotice.Sample(on: false, holder: nil, frontPID: brave.pid, screenLocked: false)
        var brought: [Int32] = []
        controller.read = { sample }
        controller.bringForward = { brought.append($0) }
        controller.show = { holder, onClick in notice.show(holder, onClick: onClick) }
        controller.hide = { keysBack in keysBack ? notice.keysBack() : notice.hide() }

        controller.tick()
        // Brave turns it on in front, then Ghostty comes forward and the
        // session names Ghostty, as macOS does.
        sample = .init(on: true, holder: brave, frontPID: brave.pid, screenLocked: false)
        controller.tick()
        sample = .init(on: true, holder: ghostty, frontPID: ghostty.pid, screenLocked: false)
        for _ in 1..<SecureInputNotice.samplesToShow { controller.tick() }
        XCTAssertFalse(notice.isUp, "not stuck long enough yet")
        controller.tick()
        XCTAssertTrue(notice.standing)
        XCTAssertEqual(notice.words, "Brave Browser is holding your keys")
        XCTAssertEqual(notice.key?.legend, "lode")
        XCTAssertEqual(notice.key?.state, .quiet, "the key no press can reach is drawn quiet")

        notice.click()
        XCTAssertEqual(brought, [2154], "a click brings the holder forward")

        sample = .init(on: false, holder: nil, frontPID: ghostty.pid, screenLocked: false)
        controller.tick()
        XCTAssertTrue(notice.isUp)
        XCTAssertFalse(notice.standing, "no longer asking")
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
        var sample = SecureInputNotice.Sample(on: false, holder: nil, frontPID: brave.pid, screenLocked: false)
        controller.read = { sample }
        controller.show = { holder, onClick in notice.show(holder, onClick: onClick) }
        controller.hide = { keysBack in keysBack ? notice.keysBack() : notice.hide() }
        controller.tick()
        sample = .init(on: true, holder: brave, frontPID: brave.pid, screenLocked: false)
        controller.tick()
        sample = .init(on: true, holder: ghostty, frontPID: ghostty.pid, screenLocked: false)
        for _ in 0..<SecureInputNotice.samplesToShow { controller.tick() }
        XCTAssertTrue(notice.standing)
        sample = .init(on: true, holder: brave, frontPID: brave.pid, screenLocked: false)
        controller.tick()
        XCTAssertFalse(notice.isUp, "the keys are not back, so the key does not light")
    }
}
