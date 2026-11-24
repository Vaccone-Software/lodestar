import AVFoundation
import CoreAudio
import XCTest
@testable import lodestar

/// The engine's keeper, driven the way `AudioInput` drives it: a session
/// starts, a scripted device delivers buffers on a clock the test owns,
/// the silence watch's window closes, the session stops. Nothing here
/// touches audio hardware or asks for the microphone.
final class AudioKeeperTests: XCTestCase {
    private static let builtIn: AudioDeviceID = 1
    private static let headset: AudioDeviceID = 2
    private static let dock: AudioDeviceID = 3
    private static let usb: AudioDeviceID = 4

    /// A buffer the way a device delivers one: exact zeros (a deaf engine,
    /// a lid-closed microphone, a dock with nothing behind it) or the
    /// quietest live room, -80 dBFS.
    static func buffer(live: Bool) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024
        if live { for i in 0..<1024 { buffer.floatChannelData![0][i] = (i % 2 == 0 ? 1 : -1) * 0.0001 } }
        return buffer
    }

    /// One `AudioInput`, its engine replaced by a script: what it asks the
    /// keeper at each event is what `AudioInput` asks, in the same order.
    private final class Ears {
        var keeper = AudioKeeper()
        let clock = VirtualClock()
        var machine = AudioKeeper.Machine(devices: [builtIn, headset, dock], systemDefault: dock,
                                          builtIn: builtIn, lidClosed: false, isBluetooth: { $0 == headset })
        /// The device the engine was built for, as `engineDevice` is.
        private(set) var reading: AudioDeviceID?
        private(set) var rebuilt = 0
        private(set) var gaveUp = false
        private(set) var charges: [AudioKeeper.Charge] = []
        /// What reached the session's sink, by device: a rebuild keeps the sink.
        private(set) var heard: [AudioDeviceID] = []
        private var signalled = false
        private var generation = 0
        private var inFlight: AudioDeviceID??
        private var running = false

        var window: TimeInterval { AudioInput.deafnessWindow(bluetooth: reading.map(machine.isBluetooth) ?? false) }

        /// `start`: a new session, its rebuilds from none.
        @discardableResult
        func start(named: AudioDeviceID? = nil) -> AudioInput.Choice {
            keeper.sessionBegan()
            return startNow(named: named)
        }

        @discardableResult
        private func startNow(named: AudioDeviceID?) -> AudioInput.Choice {
            stop()
            inFlight = .some(named)
            signalled = false
            let choice = keeper.choose(wanted: named, on: machine).choice
            guard case .device(let device) = choice else { return choice }
            reading = device
            running = true
            generation += 1
            keeper.started(running: true, at: clock.now)
            watch(generation: generation)
            return choice
        }

        private func watch(generation: Int) {
            let window = self.window
            clock.clock.after(window, DispatchWorkItem { [weak self] in
                guard let self else { return }
                let watching = self.generation == generation && self.inFlight != nil && self.running
                guard case .rebuild(let charge) = self.keeper.windowClosed(
                    watching: watching, signalled: watching && self.signalled, device: self.reading,
                    roster: { Set(self.machine.devices) }) else { return }
                if let charge { self.charges.append(charge) }
                self.rebuild()
            })
        }

        private func rebuild() {
            guard let named = inFlight else { return }
            guard keeper.mayRebuild() else { gaveUp = true; return }
            rebuilt += 1
            startNow(named: named)
        }

        /// The tap: a buffer from the device the engine reads.
        func deliver(live: Bool) {
            guard running, let reading else { return }
            if !signalled, AudioInput.hasSignal(AudioKeeperTests.buffer(live: live)) { signalled = true }
            heard.append(reading)
        }

        /// Devices with a microphone behind them; every other delivers zeros.
        var live: Set<AudioDeviceID> = []

        /// The device read delivers every sixty-four milliseconds for
        /// `seconds`: signal if it has a microphone, zeros if not.
        func run(_ seconds: TimeInterval) {
            let end = clock.now.addingTimeInterval(seconds)
            while clock.now < end {
                deliver(live: reading.map(live.contains) ?? false)
                clock.advance(by: min(0.064, end.timeIntervalSince(clock.now)))
            }
        }

        /// The device delivers nothing for `seconds`.
        func wait(_ seconds: TimeInterval) { clock.advance(by: seconds) }

        func stop() {
            if let charge = keeper.stopped(at: clock.now, inFlight: inFlight != nil, hasEngine: reading != nil,
                                           signalled: { self.signalled }, window: { self.window },
                                           device: reading, roster: { Set(self.machine.devices) }) {
                charges.append(charge)
            }
            inFlight = nil
            running = false
        }
    }

    // MARK: - The engine that hears nothing

    /// A second and a half of exact zeros from an engine claiming to run is
    /// a deaf engine: rebuilt on the spot, mid-session, on the session's
    /// own sink, and the device that ran it charged.
    func testZerosThroughTheWindowRebuildTheEngineMidSession() {
        let ears = Ears()
        ears.live = [Self.builtIn]
        ears.start()
        ears.run(1.4)
        XCTAssertEqual(ears.rebuilt, 0, "inside the window, silence is a pause")
        ears.run(0.2)
        XCTAssertEqual(ears.rebuilt, 1, "past it, the engine is rebuilt")
        XCTAssertEqual(Set(ears.charges.map(\.device)), [Self.dock], "the device that ran it is charged")
        XCTAssertFalse(ears.keeper.deaf, "the rebuilt engine started clean, and is believed")
        let before = ears.heard.count
        ears.run(1.0)
        XCTAssertGreaterThan(ears.heard.count, before, "the session's sink still hears")
    }

    /// Once is an engine that may have been born deaf; twice is the device.
    /// One silent window charges the device once, so the rebuild gives the
    /// same device a fresh engine. The rebuild stops the deaf engine first,
    /// and that stop must not judge the window the watch already judged:
    /// it once did, and one silent window wrote a device off.
    func testOneSilentWindowIsChargedOnce() {
        let ears = Ears()
        ears.start()
        ears.run(1.6)
        XCTAssertEqual(ears.charges.map(\.windows), [1], "one window, one charge")
        XCTAssertEqual(ears.reading, Self.dock, "the rebuild gives the device another engine")
    }

    /// Buffers are not the fact: no buffers at all is deafness too.
    func testAnEngineThatDeliversNothingIsDeafToo() {
        let ears = Ears()
        ears.start()
        ears.wait(AudioInput.deafnessSeconds)
        XCTAssertEqual(ears.rebuilt, 1)
    }

    /// One buffer carrying the quietest room is enough to keep the engine.
    func testOneLiveBufferKeepsTheEngine() {
        let ears = Ears()
        ears.start()
        ears.run(0.5)
        ears.deliver(live: true)
        ears.run(3)
        ears.stop()
        XCTAssertEqual(ears.rebuilt, 0)
        XCTAssertTrue(ears.charges.isEmpty)
    }

    /// A Bluetooth radio's telephone link comes up cold and silent: four
    /// seconds before it is called deaf, not one and a half.
    func testARadioIsGivenFourSecondsBeforeItIsCalledDeaf() {
        let ears = Ears()
        ears.machine.systemDefault = Self.headset
        ears.start()
        XCTAssertEqual(ears.reading, Self.headset)
        ears.run(2)
        XCTAssertEqual(ears.rebuilt, 0, "the link is still coming up")
        ears.run(2.1)
        XCTAssertEqual(ears.rebuilt, 1, "silent past four seconds is the radio")
    }

    /// A watch about an engine that has gone (the session stopped, or a
    /// newer engine took over) never acts.
    func testAWatchForAnEngineGoneByNeverActs() {
        let ears = Ears()
        ears.start()
        ears.run(1)
        ears.stop()
        ears.wait(5)
        XCTAssertEqual(ears.rebuilt, 0)
        XCTAssertTrue(ears.charges.isEmpty, "stopped inside the window: nothing charged either")
    }

    /// A machine whose microphone is genuinely gone does not rebuild
    /// forever: six rebuilds a session, and a new session has six again.
    func testTheRebuildsASessionMaySpendAreBounded() {
        let ears = Ears()
        ears.machine.devices = [Self.builtIn, Self.dock]
        ears.machine.builtIn = nil // nowhere else to go: the dock is read every time
        ears.start()
        ears.wait(20)
        XCTAssertEqual(ears.rebuilt, AudioInput.rebuildCap)
        XCTAssertTrue(ears.gaveUp, "and then it stops trying")
        ears.stop()
        ears.start()
        ears.wait(AudioInput.deafnessSeconds)
        XCTAssertEqual(ears.rebuilt, AudioInput.rebuildCap + 1, "a new session's budget is whole again")
    }

    // MARK: - The device that hears nothing

    /// A default with no microphone behind it is written off, the session
    /// goes on on the Mac's own, and so does the next draft: it does not
    /// open the same silence again.
    func testASilentDefaultIsWrittenOffAndTheMacsMicrophoneHeard() {
        let ears = Ears()
        ears.live = [Self.builtIn]
        ears.start()
        ears.run(3.2)
        XCTAssertEqual(ears.charges.last?.device, Self.dock)
        XCTAssertEqual(ears.charges.last?.writtenOff, true)
        XCTAssertEqual(ears.reading, Self.builtIn, "the rebuild reads the default elsewhere")
        ears.run(1)
        ears.stop()
        XCTAssertEqual(ears.charges.map(\.device).filter { $0 == Self.builtIn }, [], "a heard device is never charged")
        XCTAssertEqual(ears.start(), .device(Self.builtIn), "and so does the next draft")
    }

    /// Twice is the device: the first silent window gives the default a
    /// fresh engine, the second writes it off.
    func testTwoSilentWindowsWriteTheDefaultOff() {
        let ears = Ears()
        ears.live = [Self.builtIn]
        ears.start()
        ears.run(1.6)
        XCTAssertEqual(ears.reading, Self.dock, "the first rebuild gives the device another engine")
        ears.run(1.6)
        XCTAssertEqual(ears.charges.map(\.windows), [1, 2])
    }

    /// A write-off lasts only while the inputs it was charged under are
    /// the machine's: a device arriving or leaving forgives everything.
    func testANewSetOfInputsForgetsTheSilence() {
        let ears = Ears()
        ears.live = [Self.builtIn]
        ears.start()
        ears.run(3.2)
        ears.stop()
        XCTAssertEqual(ears.start(), .device(Self.builtIn), "written off")
        ears.stop()
        ears.machine.devices.append(Self.usb)
        let (choice, forgotten) = ears.keeper.choose(wanted: nil, on: ears.machine)
        XCTAssertEqual(choice, .device(Self.dock), "a device arrived: the default is the default again")
        XCTAssertEqual(forgotten, 1, "one device's silence forgotten, and said so")
        XCTAssertNil(ears.keeper.choose(wanted: nil, on: ears.machine).forgotten, "said once")
    }

    /// A device a hand named is read as named, written off or not.
    func testANamedInputIsReadEvenWrittenOff() {
        let ears = Ears()
        ears.start()
        ears.run(3.2)
        ears.stop()
        XCTAssertEqual(ears.start(named: Self.dock), .device(Self.dock))
    }

    /// With the lid closed the Mac's microphone is never the fallback: a
    /// written-off default with no headset is refused with the reason.
    func testAClosedLidNeverFallsBackToTheMacsMicrophone() {
        let ears = Ears()
        ears.machine.devices = [Self.builtIn, Self.dock]
        ears.start()
        ears.run(3.2)
        ears.stop()
        ears.machine.lidClosed = true
        XCTAssertEqual(ears.start(), .off(AudioInput.lidClosedWhy))
    }

    // MARK: - A session that stops

    /// A session that ran a whole window and heard nothing indicts the
    /// engine and the device, so the next start does not inherit either.
    /// The watch is what usually catches it; this is the stop that does
    /// when the watch did not (a resume that reset it, an engine replaced).
    func testAWholeSilentSessionIndictsTheEngineAndTheDevice() throws {
        var keeper = AudioKeeper()
        let start = Date()
        keeper.started(running: true, at: start)
        let charge = try XCTUnwrap(keeper.stopped(
            at: start.addingTimeInterval(1.6), inFlight: true, hasEngine: true, signalled: { false },
            window: { AudioInput.deafnessSeconds }, device: Self.dock, roster: { [Self.dock] }))
        XCTAssertEqual(charge.windows, 1)
        XCTAssertTrue(keeper.deaf)
        XCTAssertTrue(AudioInput.engineIsStale(hasEngine: true, builtFor: Self.dock, target: Self.dock,
                                               attempt: 0, deaf: keeper.deaf, nowReading: (16_000, 1),
                                               builtReading: (16_000, 1)),
                      "the next start builds a new engine")
        keeper.started(running: true, at: start.addingTimeInterval(2))
        XCTAssertFalse(keeper.deaf, "which, started clean, is believed")
    }

    /// A timed-out start's retry stops a session before its first buffer:
    /// a run shorter than the window says nothing about anything.
    func testAStopInsideTheWindowIndictsNothing() {
        var keeper = AudioKeeper()
        let start = Date()
        keeper.started(running: true, at: start)
        XCTAssertNil(keeper.stopped(at: start.addingTimeInterval(0.8), inFlight: true, hasEngine: true,
                                    signalled: { false }, window: { AudioInput.deafnessSeconds },
                                    device: Self.dock, roster: { [Self.dock] }))
        XCTAssertFalse(keeper.deaf)
        XCTAssertTrue(keeper.silentWindows.isEmpty)
    }

    /// Anything heard clears the device, however long it ran; and an
    /// engine that never ran is judged by nothing.
    func testAHeardOrNeverRunSessionIndictsNothing() {
        var keeper = AudioKeeper()
        let start = Date()
        keeper.started(running: true, at: start)
        XCTAssertNil(keeper.stopped(at: start.addingTimeInterval(60), inFlight: true, hasEngine: true,
                                    signalled: { true }, window: { AudioInput.deafnessSeconds },
                                    device: Self.dock, roster: { [Self.dock] }))
        keeper.started(running: false, at: start)
        XCTAssertNil(keeper.stopped(at: start.addingTimeInterval(60), inFlight: true, hasEngine: true,
                                    signalled: { false }, window: { AudioInput.deafnessSeconds },
                                    device: Self.dock, roster: { [Self.dock] }))
        XCTAssertFalse(keeper.deaf)
    }

    /// The machine is asked for its devices only when a charge is made:
    /// the stop of an ordinary session costs no CoreAudio query.
    func testAnOrdinaryStopAsksTheMachineNothing() {
        var keeper = AudioKeeper()
        let start = Date()
        keeper.started(running: true, at: start)
        var asked = 0
        _ = keeper.stopped(at: start.addingTimeInterval(5), inFlight: true, hasEngine: true,
                           signalled: { true }, window: { asked += 1; return 1.5 }, device: Self.dock,
                           roster: { asked += 1; return [] })
        XCTAssertEqual(asked, 1, "the window, to judge the run; never the roster")
    }

    /// Only a clean start believes the engine again: a restart in place or
    /// a resume measures the run from there, and a deaf verdict stands.
    func testOnlyACleanStartLiftsTheDeafVerdict() {
        var keeper = AudioKeeper()
        let start = Date()
        keeper.started(running: true, at: start)
        _ = keeper.windowClosed(watching: true, signalled: false, device: Self.dock, roster: { [Self.dock] })
        XCTAssertTrue(keeper.deaf)
        keeper.ran(running: true, at: start.addingTimeInterval(2))
        XCTAssertTrue(keeper.deaf)
        XCTAssertEqual(keeper.runningSince, start.addingTimeInterval(2))
        keeper.started(running: true, at: start.addingTimeInterval(3))
        XCTAssertFalse(keeper.deaf)
    }
}
