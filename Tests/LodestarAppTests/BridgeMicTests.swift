import AVFoundation
import CoreAudio
import XCTest
@testable import lodestar

/// The Mac's microphone standing in while a headset wakes: when a session
/// gets one, and whose it is. The bridge's device is a stand-in that
/// records what it was asked; no audio queue opens.
final class BridgeMicTests: XCTestCase {
    private static let builtIn: AudioDeviceID = 1
    private static let headset: AudioDeviceID = 2
    private static let usb: AudioDeviceID = 4

    // MARK: - Whether a session gets a bridge

    private func plan(disabled: Bool = false, builtIn: AudioDeviceID? = builtIn, lidClosed: Bool? = false,
                      target: AudioDeviceID? = headset) -> (bridge: AudioDeviceID, target: AudioDeviceID)? {
        BridgeMic.plan(disabled: disabled, builtIn: { builtIn }, lidClosed: { lidClosed },
                       target: { target }, isBluetooth: { $0 == Self.headset })
    }

    func testAWakingHeadsetIsBridgedOnTheMacsMicrophone() throws {
        let planned = try XCTUnwrap(plan())
        XCTAssertEqual(planned.bridge, Self.builtIn)
        XCTAssertEqual(planned.target, Self.headset, "the headset stays the input the session names")
    }

    /// Only with the lid open: closed, the Mac's microphone reads zeros. A
    /// Mac that cannot say (no lid to read) is not bridged either.
    func testOnlyWithTheLidKnownToBeOpen() {
        XCTAssertNil(plan(lidClosed: true), "closed: it would stand in with silence")
        XCTAssertNil(plan(lidClosed: nil), "unknown: not bridged")
    }

    /// The bridge is for a Bluetooth radio's slow start, nothing else: a
    /// wired input, or the Mac's own microphone, starts in milliseconds.
    func testOnlyABluetoothTargetIsBridged() {
        XCTAssertNil(plan(target: Self.usb), "a wired input")
        XCTAssertNil(plan(target: Self.builtIn), "the Mac's microphone cannot stand in for itself")
        XCTAssertNil(plan(target: nil), "nothing to read")
        XCTAssertNil(plan(builtIn: nil), "no microphone of the Mac's own")
        XCTAssertNil(plan(disabled: true), "switched off")
    }

    /// The facts that cost a CoreAudio query are asked only as far as
    /// needed: a closed lid never asks which device the start would read.
    func testAClosedLidAsksNothingFurther() {
        var asked = false
        _ = BridgeMic.plan(disabled: false, builtIn: { Self.builtIn }, lidClosed: { true },
                           target: { asked = true; return Self.headset }, isBluetooth: { _ in true })
        XCTAssertFalse(asked)
    }

    // MARK: - Whose bridge it is

    /// A stand-in device: every open and stop, in order, and each open's
    /// sink, so a test can speak into it.
    private final class Device: @unchecked Sendable {
        private let lock = NSLock()
        private var _log: [String] = []
        private var opens = 0
        var refuses = false
        var log: [String] { lock.withLock { _log } }
        private func note(_ line: String) { lock.withLock { _log.append(line) } }

        lazy var opener: BridgeMic.Opener = { [unowned self] device, _, _ in
            if self.refuses { self.note("refused \(device)"); return nil }
            let n = self.lock.withLock { () -> Int in self.opens += 1; return self.opens }
            self.note("open \(n)")
            return BridgeMic.Opened(pause: { self.note("pause \(n)") }, resume: { self.note("resume \(n)") },
                                    stop: { self.note("stop \(n)") })
        }
    }

    private func start(_ bridge: BridgeMic, ticket: Int) -> Bool {
        var opened: Bool?
        bridge.start(device: Self.builtIn, ticket: ticket, sink: { _ in }) { opened = $0 }
        bridge.drain()
        return opened ?? false
    }

    /// A draft winding down after the next one opened used to stop the new
    /// draft's bridge along with its own. A ticket stops only its bridge.
    func testALateStopNeverTakesTheNextDraftsBridge() {
        let device = Device()
        let bridge = BridgeMic(opener: device.opener)
        let first = bridge.reserveTicket(), second = bridge.reserveTicket()
        XCTAssertTrue(start(bridge, ticket: first))
        XCTAssertTrue(start(bridge, ticket: second))
        bridge.stop(ticket: first)
        bridge.drain()
        XCTAssertEqual(device.log, ["open 1", "stop 1", "open 2"],
                       "a new start lets go of what was open; the first draft's late stop does nothing")
        bridge.stop(ticket: second)
        bridge.drain()
        XCTAssertEqual(device.log.last, "stop 2", "its own ticket stops it")
    }

    /// A start that lands after its draft gave up on it (the deadline
    /// passed, the draft stopped) is stopped by that draft's ticket: the
    /// stop queues behind the start, so the bridge never outlives its draft.
    func testAStartThatLandsAfterItsDraftGaveUpIsStoppedByItsTicket() {
        let device = Device()
        let bridge = BridgeMic(opener: device.opener)
        let ticket = bridge.reserveTicket()
        bridge.start(device: Self.builtIn, ticket: ticket, sink: { _ in }) { _ in }
        bridge.stop(ticket: ticket)
        bridge.drain()
        XCTAssertEqual(device.log, ["open 1", "stop 1"])
        bridge.pause()
        bridge.drain()
        XCTAssertEqual(device.log, ["open 1", "stop 1"], "nothing is open to pause")
    }

    /// A bridge that would not open says so, holds nothing, and a stop for
    /// its ticket is harmless.
    func testABridgeThatWouldNotOpenHoldsNothing() {
        let device = Device()
        device.refuses = true
        let bridge = BridgeMic(opener: device.opener)
        let ticket = bridge.reserveTicket()
        XCTAssertFalse(start(bridge, ticket: ticket))
        bridge.stop(ticket: ticket)
        bridge.stop()
        bridge.drain()
        XCTAssertEqual(device.log, ["refused \(Self.builtIn)"])
    }

    func testPauseAndResumeReachTheOpenBridge() {
        let device = Device()
        let bridge = BridgeMic(opener: device.opener)
        XCTAssertTrue(start(bridge, ticket: bridge.reserveTicket()))
        bridge.pause()
        bridge.resume()
        bridge.stop()
        bridge.drain()
        XCTAssertEqual(device.log, ["open 1", "pause 1", "resume 1", "stop 1"])
    }

    /// Tickets are taken from any thread, before the start: none is ever
    /// handed out twice.
    func testTicketsAreNeverHandedOutTwice() {
        let bridge = BridgeMic(opener: { _, _, _ in nil })
        let lock = NSLock()
        var tickets: [Int] = []
        DispatchQueue.concurrentPerform(iterations: 500) { _ in
            let ticket = bridge.reserveTicket()
            lock.withLock { tickets.append(ticket) }
        }
        XCTAssertEqual(Set(tickets).count, 500)
    }

    // MARK: - The bridge and the headset's own judgement

    /// The bridge is never charged and never charges the headset: its
    /// voice reaches the recognizer, but the headset's silence watch reads
    /// only the headset's buffers. A deaf headset under a live bridge is
    /// still rebuilt, and the words were heard all the while.
    func testABridgesVoiceNeverHidesADeafHeadset() {
        var reachedRecognizer = 0
        let gate = Handover { _ in reachedRecognizer += 1 }
        gate.openBridge()
        var keeper = AudioKeeper()
        let start = Date()
        keeper.started(running: true, at: start)
        var headsetSignalled = false
        for _ in 0..<70 { // four and a half seconds at sixty-four milliseconds
            gate.fromBridge(AudioKeeperTests.buffer(live: true))
            let zeros = AudioKeeperTests.buffer(live: false)
            if AudioInput.hasSignal(zeros) { headsetSignalled = true }
            gate.fromHeadset(zeros)
        }
        XCTAssertEqual(reachedRecognizer, 70, "the bridge's words were heard")
        let verdict = keeper.windowClosed(watching: true, signalled: headsetSignalled, device: Self.headset,
                                          roster: { [Self.builtIn, Self.headset] })
        XCTAssertEqual(verdict, .rebuild(AudioKeeper.Charge(device: Self.headset, windows: 1, writtenOff: false)),
                       "the headset is judged by its own silence")
    }
}
