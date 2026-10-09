import AVFoundation
import Foundation
import LodestarCore
import Speech

/// What the recognizer is doing, for the register line to say.
/// How long one attempt at opening the microphone is given, and what a
/// spent attempt throws. Outside the recognizer's availability gate,
/// because the budget is a fact about the audio stack and the tests that
/// hold it against the watchdog's wait run on any macOS.
enum SpeechStart {
    /// One attempt's budget. The engine lands in half a second when it
    /// lands at all; a Bluetooth radio bringing its telephone link up
    /// cold takes longer, and the evening it took 2.8 to 4.1 seconds the
    /// old 1.5 second budget failed every start on the headset, retried,
    /// and the retry's stop wrote the headset off as deaf before its
    /// first buffer could arrive. Two and a half covers the cold link
    /// measured on this machine; the attempts and the settle between
    /// them must still come in under `DraftController.listenWatchdogSeconds`,
    /// or the watchdog would kill a start that was going to land.
    static let deadline: TimeInterval = 2.5
    static let attempts = 2
    static let settleSeconds: TimeInterval = 0.65
    /// The whole wait for the microphone, however it is spent: the two
    /// attempts' deadlines and the settle between them, so the arithmetic
    /// `SpeechStartBudgetTests` holds against the draft's watchdog is the
    /// same. A start that is only slow is waited for inside it rather than
    /// abandoned at the first deadline — abandoning it threw its success
    /// away, and the retry that followed stopped the engine it had just
    /// started. Only a start that fails is tried again.
    static var startBudget: TimeInterval {
        Double(attempts) * deadline + Double(attempts - 1) * settleSeconds
    }

    /// What the recognizer's own preparation is given before it is
    /// treated as wedged. `prepareToAnalyze` and `start(inputSequence:)`
    /// are awaits with no timeout of their own, and when the speech
    /// stack is stuck — which it is for minutes after an update — they
    /// never return at all. The session then reports no state whatever,
    /// and the draft says the microphone did not start while the task
    /// that would have started it is parked for the life of the process.
    static let prepareDeadline: TimeInterval = 3
    /// The Mac's own microphone opens in about 150 ms; a bridge that has
    /// not opened in a second is not saving the wait it was for.
    static let bridgeDeadline: TimeInterval = 1

    struct TimedOut: Error, CustomStringConvertible {
        var description: String { "the microphone did not answer" }
    }

    /// Run `work`, or give up on it. Whatever is still waiting is left to
    /// the runtime: the point is that the caller stops waiting, so it can
    /// say what happened instead of never speaking again.
    ///
    /// Two unstructured tasks and whichever answers first. It was a task
    /// group, and a task group does not return until every child has — so
    /// a start stuck in a continuation held the "deadline" until the start
    /// itself came back (measured: a one-second deadline on a four-second
    /// wait returned after 4.3 s). Every microphone start past its
    /// deadline was then thrown away when it finally landed, and retried.
    static func withDeadline<T: Sendable>(
        _ seconds: TimeInterval,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let once = FirstAnswer()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let worker = Task {
                do {
                    let value = try await work()
                    if once.claim() { continuation.resume(returning: value) }
                } catch {
                    if once.claim() { continuation.resume(throwing: error) }
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() {
                    worker.cancel()
                    continuation.resume(throwing: TimedOut())
                }
            }
        }
    }

    /// The one answer a race gives, whoever is first.
    final class FirstAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var answered = false
        func claim() -> Bool {
            lock.withLock {
                guard !answered else { return false }
                answered = true
                return true
            }
        }
    }
}

enum SpeechState: Equatable {
    /// The model is being fetched or loaded; `progress` when known.
    case preparing(progress: Double?)
    /// Audio is flowing from `input` (the device's name) to the recognizer.
    case listening(input: String?)
    case paused
    /// The microphone grant was refused; the draft types only.
    case denied
    /// No recognizer on this machine (macOS before 26, or no locale model).
    case unavailable
    case failed(String)
}

/// The recognizer behind the draft's speak door: one session per draft,
/// results on the main thread, and a pause that keeps the audio engine
/// warm (creating one costs a second; starting a kept one costs 70ms —
/// `probe speech --cycle` measured both). The engine itself lives on its
/// own queue: the main thread hosts the event tap, and a start that
/// waits out a Bluetooth profile flip held it long enough for macOS to
/// disable the tap — three times in one day's log.
protocol SpeechSession: AnyObject {
    var isAvailable: Bool { get }
    /// Load the model and build the audio engine without touching the
    /// microphone, so a first `lode .` after boot does not pay for either.
    /// Called only once the grant exists.
    func warm(input: String?)
    /// Begin a session. A settled result comes with when each word was
    /// said and how sure the recognizer was of it, which is what the
    /// draft joins results and puts names back by.
    func listen(input: String?,
                onState: @escaping (SpeechState) -> Void,
                onLevel: @escaping (Float, Double) -> Void,
                onAlive: @escaping () -> Void,
                onVolatile: @escaping (String) -> Void,
                onSettled: @escaping (Heard) -> Void)
    /// The session's audio so far, on the recognizer's timeline, for a
    /// settling ear to hear a phrase again.
    var held: HeldAudio { get }
    /// The mic goes quiet, the session stays. Normal mode.
    func pause()
    func resume()
    /// End the session; `completion` runs once the last words have settled
    /// (or the recognizer gave up on them).
    func stop(completion: @escaping () -> Void)
    /// Stream an audio file into the live session at real-time pace, as
    /// if the microphone heard it. False when there is no session.
    func feed(file: URL) -> Bool
}

/// The Speech framework's on-device analyzer. macOS 26 only; every entry
/// point is availability-gated so the binary still links on 13.
final class AnalyzerSpeechSession: SpeechSession {
    fileprivate var box: Any?
    /// One microphone for the process: creating an engine costs a second,
    /// starting a kept one costs 70ms. Every call on it lands on its one
    /// serial queue, in the order it was made — two sessions overlapping
    /// on one bus was a crash inside `installTapOnBus`.
    private let microphone = AudioInput()
    /// The Mac's own microphone, standing in while a headset wakes.
    private let bridge = BridgeMic()
    let held = HeldAudio()

    var isAvailable: Bool {
        if #available(macOS 26, *) { return SpeechTranscriber.isAvailable }
        return false
    }

    func warm(input: String?) {
        guard #available(macOS 26, *) else { return }
        microphone.prepare(device: input)
        Task { await AnalyzerBox.warm() }
    }

    func listen(input: String?,
                onState: @escaping (SpeechState) -> Void,
                onLevel: @escaping (Float, Double) -> Void,
                onAlive: @escaping () -> Void,
                onVolatile: @escaping (String) -> Void,
                onSettled: @escaping (Heard) -> Void) {
        guard #available(macOS 26, *) else { onState(.unavailable); return }
        // A session still winding down must let go of the bus first, and
        // one still preparing must be told it lost, or two would race for
        // the microphone and the loser would leak.
        microphone.stop()
        bridge.stop()
        if let old = box as? AnalyzerBox { Task { await old.stop() } }
        held.clear()
        let box = AnalyzerBox(microphone: microphone, bridge: bridge, held: held)
        self.box = box
        Task { await box.listen(input: input,
                                stillWanted: { [weak self] in (self?.box as AnyObject?) === box },
                                onState: onState, onLevel: onLevel, onAlive: onAlive,
                                onVolatile: onVolatile, onSettled: onSettled) }
    }

    func pause() {
        microphone.pause()
        bridge.pause()
    }

    func resume() {
        microphone.resume()
        bridge.resume()
    }

    func stop(completion: @escaping () -> Void) {
        guard #available(macOS 26, *), let box = box as? AnalyzerBox else { completion(); return }
        self.box = nil
        // The tap comes off first: queued now, ahead of anything the next
        // session queues, which may be before the recognizer has finished.
        microphone.stop()
        bridge.stop()
        Task {
            await box.stop()
            await MainActor.run { completion() }
        }
    }
}

extension AnalyzerSpeechSession {
    func feed(file: URL) -> Bool {
        guard #available(macOS 26, *), let box = box as? AnalyzerBox else { return false }
        Task { await box.feed(file: file) }
        return true
    }
}

/// The process's one audio engine and the tap on its input. Everything
/// here runs on one serial queue, never the main thread: building an
/// engine costs a second, and a start inside a Bluetooth profile flip
/// fails slowly (-10868 after 400–800ms, measured) before it succeeds.
/// The main thread hosts the event tap, and macOS disables a tap whose
/// thread stops answering — every keystroke on the machine went dead
/// until the watchdog brought it back. The actor that consumes the
/// buffers never touches the engine directly.
final class AudioInput: @unchecked Sendable {
    /// The engine's queue. Calls made from the main thread keep their
    /// order here, so a stop queued before a start still lands first.
    private let queue = DispatchQueue(label: "com.vaccone.lodestar.audio", qos: .userInitiated)
    private var engine: AVAudioEngine?
    /// The device the engine was built for, and the format it had then.
    /// An engine's input node fixes its formats to what it first saw;
    /// a different device, or the same device at a new sample rate (a
    /// capture box that renegotiates), leaves them stale — no buffers,
    /// or -10868 at start. Either way the engine is rebuilt; the same
    /// device at the same format keeps the warm one.
    private var engineDevice: AudioDeviceID?
    private var engineFormat: (rate: Double, channels: UInt32)?
    private var tapInstalled = false
    private var observer: NSObjectProtocol?
    /// The session in flight — the device asked for and the sink — kept
    /// so a configuration change can rebuild it. nil between sessions.
    private var inFlight: (device: String?, sink: (AVAudioPCMBuffer) -> Void)?
    private var rebuildPending = false
    /// Rebuilds a session may spend: a radio that keeps flipping must not
    /// rebuild forever.
    static let rebuildCap = 6
    /// Which engine a configuration-change notice was about: each build
    /// stamps the next number and observes its own engine by object, so
    /// a notice from an engine already discarded is dropped by number.
    private var engineGeneration = 0
    /// Buffers this start has delivered, whether any carried signal, and
    /// the lock the audio thread touches them under. Fifteen touches a
    /// second at the buffer size this installs, so the lock costs
    /// nothing and the counts are honest. Signal is the fact that
    /// matters: a microphone the lid has switched off delivers buffers
    /// at the full rate, every sample exactly zero, and counting them
    /// called it alive for an entire evening.
    private let deliveryLock = NSLock()
    private var delivered = 0
    private var signalled = false
    /// The silence watch, the write-offs and the rebuild budget: the
    /// decisions about this engine that are not the engine's (see
    /// `AudioKeeper`). Touched only on `queue`.
    private var keeper = AudioKeeper()
    /// Windows in silence before a device is read no more.
    static let windowsToWriteOff = 2
    /// How long a running engine may deliver no signal before it is not
    /// believed. Buffers arrive about fifteen times a second and a live
    /// room never reads below -97 dBFS; a second and a half of exact
    /// silence, with the engine claiming to run, is not a quiet room, it
    /// is a deaf engine or a device with no microphone behind it.
    static let deafnessSeconds: TimeInterval = 1.5
    /// The same watch on a Bluetooth radio, whose telephone link comes
    /// up cold in a second and a half from a fresh process and took
    /// three inside the app the evening this was measured. Silence
    /// inside that window is the link, not the device.
    static let radioDeafnessSeconds: TimeInterval = 4

    /// Whether a device that ran and stayed silent is to be written off.
    /// Nothing is held against a device the engine never ran on, or ran
    /// on for less than the window: a start that timed out and was
    /// retried proves nothing about the device, and one evening it wrote
    /// a headset off twice inside ten seconds.
    static func indicts(ranFor: TimeInterval?, signalled: Bool, window: TimeInterval) -> Bool {
        guard let ranFor, !signalled else { return false }
        return ranFor >= window
    }

    static func deafnessWindow(bluetooth: Bool) -> TimeInterval {
        bluetooth ? radioDeafnessSeconds : deafnessSeconds
    }

    /// What a start reads: a device, or the reason none can be.
    enum Choice: Equatable {
        case device(AudioDeviceID?)
        case off(String)
    }

    /// The line the draft shows for a Mac whose lid is closed.
    static let lidClosedWhy = "the lid is closed, so the Mac's microphone is off"

    /// A closed lid switches the built-in microphone off at the
    /// hardware: every process reads exact zeros from it, and the first
    /// evening's "the mic does not work" was this. An error, not a
    /// silence, so the register line can say it in one line instead of
    /// listening to nothing.
    struct InputOff: Error, CustomStringConvertible {
        let why: String
        var description: String { why }
    }

    /// Which device a start reads.
    ///
    /// A device named on the register line is read as named, always: a
    /// hand that chose it is telling the app what to read, and silently
    /// reading something else is the failure the name was there to
    /// prevent. The system default is followed unless it has been
    /// written off, and then the Mac's own microphone is read instead,
    /// being heard somewhere beating being silent faithfully; nil is
    /// the engine's own default. `writtenOff` never contains anything a
    /// hand named, and it never survives a change to the set of inputs.
    ///
    /// With the lid closed the Mac's microphone is off, so it is never
    /// fallen back to, and a default that is the Mac's microphone is
    /// read on a Bluetooth headset when one is connected, a headset
    /// being the one input that is a microphone by definition; a dock's
    /// line-in would be silence again. With no headset the start is
    /// refused with the reason, whoever named the device, because a
    /// closed lid is a fact about the hardware and not about the name.
    static func choose(wanted: AudioDeviceID?, systemDefault: AudioDeviceID?,
                       writtenOff: Set<AudioDeviceID>, builtIn: AudioDeviceID?,
                       lidClosed: Bool = false, headset: AudioDeviceID? = nil) -> Choice {
        let builtInOff = lidClosed && builtIn != nil
        if let wanted {
            if builtInOff, wanted == builtIn { return .off(lidClosedWhy) }
            return .device(wanted)
        }
        let candidates: [AudioDeviceID?]
        if let systemDefault, !writtenOff.contains(systemDefault) {
            candidates = [systemDefault, headset]
        } else {
            candidates = [builtIn, headset, systemDefault]
        }
        for case let candidate? in candidates where !writtenOff.contains(candidate) {
            if builtInOff, candidate == builtIn { continue }
            return .device(candidate)
        }
        if builtInOff { return .off(lidClosedWhy) }
        return .device(systemDefault ?? builtIn)
    }

    /// Whether the write-off still applies: only while the inputs it was
    /// charged under are the inputs the machine has.
    static func writeOffHolds(roster: Set<AudioDeviceID>, chargedUnder: Set<AudioDeviceID>) -> Bool {
        roster == chargedUnder
    }

    /// Whether a buffer carries anything but zeros: the feed's own alive
    /// test, -100 dBFS, applied here so the engine's keeper knows what
    /// the feed knows.
    static func hasSignal(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return false }
        let samples = UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot() > 1e-5
    }

    init() {}

    /// Whether a kept engine can serve this start, or has to be replaced.
    ///
    /// Creating an engine costs a second and starting a kept one costs
    /// seventy milliseconds, so the warm one is worth keeping — but only
    /// while it is the same engine in every way that matters. A deaf one
    /// is stale by the only test that counts and by none of the others:
    /// same device, same format, starts cleanly, reports running, hears
    /// nothing. Without that clause it was kept and restarted for every
    /// draft after it, which is why a silent microphone stayed silent
    /// for whole minutes rather than for one session.
    static func engineIsStale(hasEngine: Bool, builtFor: AudioDeviceID?, target: AudioDeviceID?,
                              attempt: Int, deaf: Bool,
                              nowReading: (rate: Double, channels: UInt32)?,
                              builtReading: (rate: Double, channels: UInt32)?) -> Bool {
        if !hasEngine || deaf || attempt > 0 { return true }
        if builtFor != target { return true }
        guard let nowReading, let builtReading else { return true }
        return nowReading != builtReading
    }

    private func deliveredCount() -> Int {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        return delivered
    }

    private func heardSignal() -> Bool {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        return signalled
    }

    private var deafnessWindow: TimeInterval {
        Self.deafnessWindow(bluetooth: engineDevice.map(Self.isBluetooth) ?? false)
    }

    /// Watch `fresh` for the hardware under it changing.
    ///
    /// Nothing happens inside the notification: the center posts it from
    /// the engine's own IO-unit queue and WAITS for the observer to
    /// return, and any engine call from inside — prepare, start, stop —
    /// dispatches synchronously onto that same waiting queue. v0.28.0 did
    /// exactly that from the audio queue and deadlocked: every later
    /// draft's start queued behind it and the microphone never opened
    /// again until relaunch. So the block only hops. And it never touches
    /// the notification's object: the center also posts while an engine
    /// is being torn down, and retaining that object crashed the first
    /// build of 0.28.1 on release. Observed by object, the center does the
    /// matching; `discard` unregisters before the engine goes.
    private func observe(_ fresh: AVAudioEngine) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engineGeneration += 1
        let generation = engineGeneration
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: fresh, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.configurationChanged(generation: generation) }
        }
    }

    /// The hardware under the engine moved. Mid-session the engine is
    /// restarted in place, tap and all — the path that delivered a
    /// thousand buffers a session on 0.27.0 — and a start caught inside
    /// the flip (-10868) is retried a beat later rather than abandoned,
    /// which is what left 0.27.0's failed restarts silent. Rebuilding on
    /// every change was tried first and cycled: each fresh engine drew a
    /// fresh change, and the tap came down every second. A rebuild is now
    /// the fallback when restarts keep failing. Idle, the engine is
    /// simply not trusted any more.
    private func configurationChanged(generation: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let engine, generation == engineGeneration else { return }
        guard inFlight != nil else {
            Log.info("draft", ["speech": "audio configuration changed", "idle": true])
            discard()
            return
        }
        if engine.isRunning {
            Log.info("draft", ["speech": "audio configuration changed", "running": true])
            return
        }
        guard !rebuildPending else { return }
        rebuildPending = true
        restart(attempt: 1)
    }

    private func restart(attempt: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard inFlight != nil, let engine else { rebuildPending = false; return }
        if engine.isRunning { rebuildPending = false; return }
        engine.prepare()
        do {
            try engine.start()
            rebuildPending = false
            keeper.ran(running: engine.isRunning, at: Date())
            Log.info("draft", ["speech": "audio configuration changed", "restarted": true, "attempt": attempt])
        } catch {
            Log.info("draft", ["speech": "audio configuration changed",
                               "restart failed": error.localizedDescription, "attempt": attempt])
            guard attempt < 4 else {
                rebuildPending = false
                rebuild(attempt: 1)
                return
            }
            queue.asyncAfter(deadline: .now() + 0.65) { [weak self] in self?.restart(attempt: attempt + 1) }
        }
    }

    /// The fallback: a fresh engine for the session in flight, on the
    /// same sink, when the kept one will not start again. Bounded twice:
    /// attempts per change, rebuilds per session.
    private func rebuild(attempt: Int) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let inFlight else { return } // the session ended while this waited
        guard keeper.mayRebuild() else {
            Log.info("draft", ["speech": "audio configuration changed", "rebuilds": keeper.rebuilds, "gaveUp": true])
            return
        }
        do {
            let started = try startNow(device: inFlight.device, sink: inFlight.sink, fresh: true)
            Log.info("draft", ["speech": "audio configuration changed", "rebuilt": true,
                               "attempt": attempt, "inHz": Int(started.format.sampleRate)])
        } catch {
            Log.info("draft", ["speech": "audio configuration changed",
                               "rebuild failed": error.localizedDescription, "attempt": attempt])
            guard attempt < 4 else { return }
            queue.asyncAfter(deadline: .now() + 0.65) { [weak self] in self?.rebuild(attempt: attempt + 1) }
        }
    }

    private func discard() {
        dispatchPrecondition(condition: .onQueue(queue))
        // Unregistered first: a teardown posts the same notice, and no
        // block of ours may run for an engine on its way out.
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        if let engine {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
            retire(engine)
        }
        engine = nil
        engineDevice = nil
        engineFormat = nil
        tapInstalled = false
    }

    /// An engine let go is kept a while before it is freed. Its input unit
    /// listens to the device, and a property change already on its way
    /// when the engine goes is delivered after: AVFAudio's listener then
    /// messaged a freed engine and the app died (0.39.3's first automated
    /// smoke, 2026-09-28: warmed at launch, discarded idle on a device
    /// change, a second change four seconds later — the installed app
    /// letting go of the microphone). 399 idle discards in three weeks,
    /// most right after the launch warm-up; five minutes outlasts any
    /// notice in flight by far, and at most a few engines wait at once.
    private func retire(_ engine: AVAudioEngine) {
        queue.asyncAfter(deadline: .now() + Self.retirement) { withExtendedLifetime(engine) {} }
    }
    static let retirement: TimeInterval = 300

    private func build(for target: AudioDeviceID?) -> AVAudioEngine {
        dispatchPrecondition(condition: .onQueue(queue))
        let fresh = AVAudioEngine()
        // The device goes in before the node reports a format, so the
        // formats it fixes are this device's.
        if let target, let unit = fresh.inputNode.audioUnit { _ = Self.use(target, on: unit) }
        let format = fresh.inputNode.inputFormat(forBus: 0)
        observe(fresh)
        engine = fresh
        engineDevice = target
        engineFormat = (format.sampleRate, format.channelCount)
        return fresh
    }

    /// Every device with an input stream, by CoreAudio id and name.
    static func inputDevices() -> [(id: AudioDeviceID, name: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var streamBytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamBytes) == noErr,
                  streamBytes > 0, let name = name(of: id) else { return nil }
            return (id, name)
        }
    }

    static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let name = value?.takeRetainedValue() else { return nil }
        return name as String
    }

    /// The system's default input right now.
    /// The Mac's own microphone, found by transport type rather than by
    /// name, because the name is localised and the transport is not.
    ///
    /// It is the fallback for a device that will not speak. A Mac's
    /// built-in microphone is the one input that is always present and
    /// always works, so when the chosen one delivers nothing it is
    /// better to be heard somewhere than to be silent faithfully.
    static func builtInInput() -> AudioDeviceID? {
        inputDevices().first { transport(of: $0.id) == kAudioDeviceTransportTypeBuiltIn }?.id
    }

    static func transport(of id: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr
        else { return nil }
        return transport
    }

    static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let transport = transport(of: id)
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    static func defaultInput() -> AudioDeviceID? {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// The system's default input, by name, for the settings pane.
    static var defaultInputName: String? { defaultInput().flatMap(name(of:)) }

    private static func device(of unit: AudioUnit) -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &id, &size)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func use(_ id: AudioDeviceID, on unit: AudioUnit) -> Bool {
        var device = id
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 0, &device,
                                    UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    }

    /// Install the tap and start the engine, reading from `device` by
    /// name when one is configured and found, the system default
    /// otherwise — set explicitly each time, so a kept engine follows a
    /// default that changed since. `sink` runs on the audio thread with
    /// each buffer in the input's native format. `completion` runs on
    /// the engine's queue with the format and the name of the device
    /// actually read, or the error: no usable format is what an
    /// unplugged or exclusively held device looks like.
    func start(device: String?, sink: @escaping (AVAudioPCMBuffer) -> Void,
               completion: @escaping (Result<(format: AVAudioFormat, name: String?), Error>) -> Void) {
        queue.async {
            self.keeper.sessionBegan()
            completion(Result { try self.startNow(device: device, sink: sink) })
        }
    }

    /// `fresh` discards the kept engine first: a rebuild after a
    /// configuration change must not trust the node's own report of its
    /// format, which is what the stale check below reads.
    private func startNow(device: String?, sink: @escaping (AVAudioPCMBuffer) -> Void,
                          fresh: Bool = false) throws
        -> (format: AVAudioFormat, name: String?) {
        dispatchPrecondition(condition: .onQueue(queue))
        stopNow()
        inFlight = (device, sink)
        deliveryLock.lock(); delivered = 0; signalled = false; deliveryLock.unlock()
        if fresh { discard() }
        let target = try resolveTarget(device: device, logs: true)
        return try startEngine(target: target, sink: sink)
    }

    /// The device a start for `device` will most likely read, asked ahead
    /// of it so the bridge can decide whether it is wanted: the same
    /// choice as `startNow`'s, without the write-offs, which live on the
    /// engine's queue and are not worth a wait on it. A write-off only
    /// moves a start off a headset, so at worst the bridge stands in for a
    /// start that did not need it. nil when the start would read nothing.
    static func plannedTarget(device: String?) -> AudioDeviceID? {
        let devices = inputDevices()
        let wanted = device.flatMap { name in devices.first { $0.name == name }?.id }
        let lidClosed = Lid.isClosed() == true
        let headset = devices.map(\.id).first { isBluetooth($0) }
        guard case .device(let chosen) = choose(wanted: wanted, systemDefault: defaultInput(), writtenOff: [],
                                                builtIn: builtInInput(), lidClosed: lidClosed, headset: headset)
        else { return nil }
        return chosen ?? defaultInput()
    }

    private func resolveTarget(device: String?, logs: Bool) throws -> AudioDeviceID? {
        dispatchPrecondition(condition: .onQueue(queue))
        let devices = Self.inputDevices()
        let wanted = device.flatMap { name in devices.first { $0.name == name }?.id }
        if logs, device != nil, wanted == nil {
            Log.info("draft", ["speech": "input not found", "wanted": device ?? ""])
        }
        let systemDefault = Self.defaultInput()
        let lidClosed = Lid.isClosed() == true
        let machine = AudioKeeper.Machine(devices: devices.map(\.id), systemDefault: systemDefault,
                                          builtIn: Self.builtInInput(), lidClosed: lidClosed,
                                          isBluetooth: Self.isBluetooth)
        let (choice, forgotten) = keeper.choose(wanted: wanted, on: machine)
        if logs, let forgotten {
            Log.info("draft", ["speech": "inputs changed", "silence forgotten": forgotten])
        }
        let target: AudioDeviceID?
        switch choice {
        case .off(let why):
            if logs { Log.info("draft", ["speech": "input is off", "why": why]) }
            throw InputOff(why: why)
        case .device(let chosen):
            target = chosen
        }
        if logs, let target, wanted == nil, target != systemDefault {
            Log.info("draft", ["speech": "default not read",
                               "was": systemDefault.flatMap(Self.name(of:)) ?? "none",
                               "reading": Self.name(of: target) ?? "unknown",
                               "lidClosed": lidClosed])
        }
        return target
    }

    private func startEngine(target: AudioDeviceID?, sink: @escaping (AVAudioPCMBuffer) -> Void) throws
        -> (format: AVAudioFormat, name: String?) {
        dispatchPrecondition(condition: .onQueue(queue))
        var attempt = 0
        var format = AVAudioFormat()
        while true {
            // A kept engine serves only the device and format it was built
            // for; anything else, and any failed start, gets a fresh one.
            let current = engine?.inputNode.inputFormat(forBus: 0)
            let stale = Self.engineIsStale(
                hasEngine: engine != nil, builtFor: engineDevice, target: target,
                attempt: attempt, deaf: keeper.deaf,
                nowReading: current.map { ($0.sampleRate, $0.channelCount) },
                builtReading: engineFormat)
            if stale { discard(); _ = build(for: target) }
            guard let engine else { throw NSError(domain: "draft", code: 3) }
            let input = engine.inputNode
            // The hardware's format, not the node's output format; a nil
            // tap format takes whatever the node delivers, and the feed
            // converts per buffer, whatever arrives.
            format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(domain: "draft", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "the input has no usable format"])
            }
            // Small buffers: at 16 kHz, 4096 frames was a quarter second of
            // audio held back from the recognizer on every callback.
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
                if let self {
                    self.deliveryLock.lock()
                    self.delivered += 1
                    // Read until one carries signal, never after: the
                    // sum is a few thousand multiplies on the audio thread.
                    if !self.signalled, Self.hasSignal(buffer) { self.signalled = true }
                    self.deliveryLock.unlock()
                }
                sink(buffer)
            }
            tapInstalled = true
            engine.prepare()
            do {
                try engine.start()
                break
            } catch {
                discard()
                attempt += 1
                Log.info("draft", ["speech": "engine start failed", "attempt": attempt,
                                   "error": error.localizedDescription])
                if attempt > 1 { throw error }
            }
        }
        guard let engine else { throw NSError(domain: "draft", code: 3) }
        let input = engine.inputNode
        let name = input.audioUnit.flatMap(Self.device(of:)).flatMap(Self.name(of:))
        Log.info("draft", ["speech": "engine", "running": engine.isRunning,
                           "inHz": Int(input.inputFormat(forBus: 0).sampleRate),
                           "inCh": Int(input.inputFormat(forBus: 0).channelCount),
                           "voiceProcessing": input.isVoiceProcessingEnabled])
        keeper.started(running: engine.isRunning, at: Date())
        watchForSilence(generation: engineGeneration)
        return (format, name)
    }

    /// An engine that starts, reports running, and delivers nothing.
    ///
    /// This is what an update leaves behind: the audio stack has not
    /// settled, the engine built inside that window is deaf, and it is
    /// stale by no test the start path had — same device, same format,
    /// no error — so every draft afterwards restarted the same deaf
    /// engine. The field log has runs of a dozen sessions at
    /// `buffers=0 peakDb=-140` after an update, going back a year of
    /// releases. Nothing recovered them but time or a relaunch.
    ///
    /// So the engine is watched instead. Deliver nothing for
    /// `deafnessSeconds` while claiming to run, and it is rebuilt on the
    /// spot, on the same sink, mid-session — the rebuild path the
    /// configuration-change handler already uses, and bounded by the
    /// same cap, so a machine whose microphone is genuinely gone does
    /// not rebuild forever.
    private func watchForSilence(generation: Int) {
        let window = deafnessWindow
        queue.asyncAfter(deadline: .now() + window) { [weak self] in
            guard let self else { return }
            let watching = self.engineGeneration == generation && self.inFlight != nil
                && self.engine?.isRunning == true
            // Rebuilding the same device is only worth doing once: an
            // engine can be born deaf, but a device silent through two
            // windows is a device with no microphone behind it, and the
            // rebuild's own start reads the default elsewhere.
            guard case .rebuild(let charge) = self.keeper.windowClosed(
                watching: watching, signalled: watching && self.heardSignal(), device: self.engineDevice,
                roster: { Set(Self.inputDevices().map(\.id)) }) else { return }
            self.logCharge(charge)
            Log.info("draft", ["speech": "engine heard nothing", "buffers": self.deliveredCount(),
                               "seconds": window, "rebuilds": self.keeper.rebuilds])
            self.rebuild(attempt: 1)
        }
    }

    /// One whole window of silence, against the device that ran it.
    private func logCharge(_ charge: AudioKeeper.Charge?) {
        guard let charge else { return }
        Log.info("draft", ["speech": "input heard nothing",
                           "input": Self.name(of: charge.device) ?? "unknown",
                           "windows": charge.windows,
                           "writtenOff": charge.writtenOff])
    }

    func pause() {
        queue.async { self.engine?.pause() }
    }

    func resume() {
        queue.async {
            guard self.tapInstalled, let engine = self.engine else { return }
            try? engine.start()
            self.keeper.ran(running: engine.isRunning, at: Date())
            // Coming back from a pause is a start like any other, and an
            // engine can be deaf on either side of one.
            self.watchForSilence(generation: self.engineGeneration)
        }
    }

    /// Build the engine for the device the next session will read, without
    /// starting it: creation is the second-long part, starting is 70ms.
    func prepare(device: String?) {
        queue.async {
            guard self.engine == nil else { return }
            let wanted = device.flatMap { name in Self.inputDevices().first { $0.name == name }?.id }
            _ = self.build(for: wanted ?? Self.defaultInput())
        }
    }

    /// Take the tap off and stop the engine fully, so the next start can
    /// change the device: a paused graph keeps the device it had.
    /// Idempotent. The engine object is kept; starting it again is the
    /// 70ms path, creating one is the second.
    func stop() {
        queue.async { self.stopNow() }
    }

    private func stopNow() {
        dispatchPrecondition(condition: .onQueue(queue))
        // A session that ran a whole window and heard no signal indicts
        // the engine it used, so the next one does not inherit it — and
        // indicts the device too, which is what stops the next draft
        // opening the same silence. A session stopped sooner, which is
        // what a timed-out start's retry is, says nothing about either.
        logCharge(keeper.stopped(at: Date(), inFlight: inFlight != nil, hasEngine: engine != nil,
                                 signalled: heardSignal, window: { self.deafnessWindow },
                                 device: engineDevice, roster: { Set(Self.inputDevices().map(\.id)) }))
        inFlight = nil
        guard let engine else { return }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
    }
}

/// One session's analyzer, transcriber, audio tap, and result loop.
@available(macOS 26, *)
private actor AnalyzerBox {
    private let microphone: AudioInput
    private let bridge: BridgeMic
    /// The ticket this session's bridge was asked for, if it asked.
    private var bridgeTicket: Int?
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var feed: AudioFeed?
    private var format: AVAudioFormat?
    private var stopped = false

    private let held: HeldAudio

    init(microphone: AudioInput, bridge: BridgeMic, held: HeldAudio) {
        self.microphone = microphone
        self.bridge = bridge
        self.held = held
    }

    /// A result's words, each with when it was said and how sure the
    /// recognizer was.
    static func heard(_ text: AttributedString) -> Heard {
        var words: [Heard.Word] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            var start: Double?, end: Double?
            if let range = run.audioTimeRange {
                if range.start.isNumeric { start = range.start.seconds }
                if range.end.isNumeric { end = range.end.seconds }
            }
            words.append(Heard.Word(piece, start: start, end: end, confidence: run.transcriptionConfidence))
        }
        return Heard(String(text.characters), words: words)
    }

    private static let options = SpeechAnalyzer.Options(priority: .userInitiated,
                                                        modelRetention: .processLifetime)

    /// Load the locale's model into the process (retained for its
    /// lifetime) so the first real session prepares in ~100ms.
    static func warm() async {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else { return }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [])
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else { return }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: options)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        try? await analyzer.prepareToAnalyze(in: format)
        await analyzer.cancelAndFinishNow()
        Log.info("draft", ["speech": "warm"])
    }

    func listen(input wanted: String?,
                stillWanted: @escaping @MainActor () -> Bool,
                onState: @escaping (SpeechState) -> Void,
                onLevel: @escaping (Float, Double) -> Void,
                onAlive: @escaping () -> Void,
                onVolatile: @escaping (String) -> Void,
                onSettled: @escaping (Heard) -> Void) async {
        let say: (SpeechState) -> Void = { state in
            Log.info("draft", ["speech": "\(state)"])
            Task { @MainActor in onState(state) }
        }
        Log.info("draft", ["speech": "start", "available": SpeechTranscriber.isAvailable,
                           "locale": Locale.current.identifier])
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            Log.info("draft", ["speech": "no supported locale"])
            say(.unavailable); return
        }
        // Word times and confidence cost nothing and never change the words
        // (measured on 175 recordings); they are what the draft joins
        // results and puts names back by.
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults],
                                            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        self.transcriber = transcriber

        // The model, fetched once. Lazy on purpose: nothing downloads until
        // someone opens the door.
        let status = await AssetInventory.status(forModules: [transcriber])
        Log.info("draft", ["speech": "assets", "status": "\(status)"])
        if status == .unsupported { say(.unavailable); return }
        if status != .installed {
            say(.preparing(progress: 0))
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    let progress = request.progress
                    let ticker = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .milliseconds(500))
                            say(.preparing(progress: progress.fractionCompleted))
                        }
                    }
                    defer { ticker.cancel() }
                    try await request.downloadAndInstall()
                    Log.info("draft", ["speech": "assets installed"])
                } else {
                    Log.info("draft", ["speech": "no installation request offered"])
                }
            } catch {
                Log.info("draft", ["speech": "asset install failed", "error": "\(error)"])
                say(.failed("the speech model could not be installed")); return
            }
        }

        // The grant, asked at the moment of use and never before.
        Log.info("draft", ["speech": "asking for the microphone",
                           "status": AVCaptureDevice.authorizationStatus(for: .audio).rawValue])
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        Log.info("draft", ["speech": "microphone", "granted": granted])
        guard granted else { say(.denied); return }
        guard !stopped else { return }

        let analyzer = SpeechAnalyzer(modules: [transcriber], options: Self.options)
        self.analyzer = analyzer
        var prepared: AVAudioFormat?
        do {
            prepared = try await SpeechStart.withDeadline(SpeechStart.prepareDeadline) {
                let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                try await analyzer.prepareToAnalyze(in: format)
                return format
            }
        } catch {
            Log.info("draft", ["speech": "prepare failed", "error": "\(error)"])
            say(.failed("the recognizer could not start")); return
        }
        let format = prepared
        self.format = format

        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        let heard = Self.heard(result.text)
                        await MainActor.run { onSettled(heard) }
                    } else {
                        await MainActor.run { onVolatile(text) }
                    }
                }
            } catch {
                await self?.noteResultsEnded(error)
            }
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        guard let outFormat = format else { say(.failed("the recognizer has no audio format")); return }
        do {
            try await SpeechStart.withDeadline(SpeechStart.prepareDeadline) {
                try await analyzer.start(inputSequence: stream)
            }
        } catch {
            Log.info("draft", ["speech": "analyzer start failed", "error": "\(error)"])
            say(.failed("the recognizer could not start")); return
        }
        guard !stopped else { return }
        let feed = AudioFeed(outFormat: outFormat, continuation: continuation, held: held,
                             onLevel: onLevel, onAlive: onAlive)
        self.feed = feed
        let gate = Handover(push: { feed.push($0) })
        await openBridge(for: wanted, gate: gate, say: say)
        // A Bluetooth radio resting on its music profile flips to the
        // hands-free profile when the input opens, and a start inside the
        // flip fails with -10868 — measured on the headset this was built
        // against: the first start from the music profile always fails,
        // and one ~750ms later succeeds (longer while music actively
        // streams). The engine's own immediate rebuild cannot outwait
        // that, so the settling happens here, off the main thread,
        // across a few attempts.
        var started: (format: AVAudioFormat, name: String?)?
        let began = Date()
        var attempt = 0
        while started == nil, attempt < SpeechStart.attempts {
            attempt += 1
            if attempt > 1 {
                // The headset's engine goes down and comes back: the bridge,
                // if one is open, covers the gap.
                gate.bridgeAgain()
                try? await Task.sleep(for: .seconds(SpeechStart.settleSeconds))
                guard !stopped else { stopOwnBridge(); return }
            }
            let remaining = SpeechStart.startBudget - Date().timeIntervalSince(began)
            guard remaining > 0.25 else { break }
            do {
                started = try await Self.startMicrophone(microphone, device: wanted, within: remaining,
                                                         stillWanted: stillWanted) { buffer in gate.fromHeadset(buffer) }
            } catch is CancellationError {
                stopOwnBridge()
                return
            } catch let off as AudioInput.InputOff {
                // Not a start that failed: a start there is no device for.
                // Another attempt would refuse the same way.
                stopOwnBridge()
                say(.failed(off.why)); return
            } catch is SpeechStart.TimedOut {
                // The start is still out on the engine's queue. Another one
                // would queue behind it and then stop whatever it started;
                // the whole budget is spent, so this is the end of it.
                Log.info("draft", ["speech": "audio start timed out", "attempt": attempt,
                                   "seconds": (Date().timeIntervalSince(began) * 10).rounded() / 10])
                break
            } catch {
                Log.info("draft", ["speech": "audio start failed", "attempt": attempt,
                                   "error": "\(error.localizedDescription)"])
            }
        }
        guard let started else {
            // The bridge was only ever standing in, and a start still out
            // there must not come alive after the draft has said it failed.
            stopOwnBridge()
            microphone.stop()
            say(.failed("the microphone could not start")); return
        }
        // The bridge is let go at the handover — the headset's first buffer
        // with a voice in it — never when its start returns: `start`
        // returns before a buffer has arrived, and the headset's link comes
        // up silent before it comes up live, so cutting here lost the words
        // in between. A headset that never hears keeps the bridge for the
        // session: the words are still heard, and the engine's own silence
        // watch rebuilds the headset and writes it off for the next draft.
        let input = started.name
        Log.info("draft", ["speech": "audio", "input": input ?? "unknown",
                           "hz": Int(started.format.sampleRate),
                           "channels": Int(started.format.channelCount)])
        guard !stopped else { microphone.stop(); return }
        say(.listening(input: input))
    }

    /// A Bluetooth headset read with the lid open starts slowly: it has
    /// to leave its music profile for its telephone one before it can
    /// hear anything, 1.2 to 2.5 s on every slow start since 0.36.1 (all
    /// seven over a second, of 99, were a headset at 16 kHz; the Mac's own
    /// microphone started in a median 178 ms). The Mac's microphone opens
    /// now and is fed to the recognizer until the headset's first buffer
    /// with signal, then let go. Only with the lid open, where it hears;
    /// closed, it reads zeros. The headset stays the input the session
    /// names and is judged by its own silence watch; the bridge is never
    /// charged and never charges it.
    private func openBridge(for wanted: String?, gate: Handover, say: (SpeechState) -> Void) async {
        guard let (builtIn, target) = BridgeMic.plan(
            disabled: ProcessInfo.processInfo.environment["LODESTAR_NO_BRIDGE"] != nil,
            builtIn: AudioInput.builtInInput, lidClosed: Lid.isClosed,
            target: { AudioInput.plannedTarget(device: wanted) }, isBluetooth: AudioInput.isBluetooth)
        else { return }
        let bridge = self.bridge
        let ticket = bridge.reserveTicket()
        bridgeTicket = ticket
        let opened = (try? await SpeechStart.withDeadline(SpeechStart.bridgeDeadline) {
            await withCheckedContinuation { continuation in
                bridge.start(device: builtIn, ticket: ticket, sink: { gate.fromBridge($0) }) {
                    continuation.resume(returning: $0)
                }
            }
        }) ?? false
        let headset = AudioInput.name(of: target) ?? "the headset"
        guard opened, !stopped else {
            stopOwnBridge()
            Log.info("draft", ["speech": "bridge did not open", "for": headset])
            return
        }
        gate.onHandover = { [bridge] ms in
            bridge.stop(ticket: ticket)
            Log.info("draft", ["speech": "bridge handed over", "to": headset, "ms": ms])
        }
        gate.openBridge()
        Log.info("draft", ["speech": "bridging", "on": AudioInput.name(of: builtIn) ?? "built-in", "for": headset])
        say(.listening(input: AudioInput.name(of: builtIn)))
    }

    /// This session's bridge, and no other session's.
    private func stopOwnBridge() {
        if let bridgeTicket { bridge.stop(ticket: bridgeTicket) }
    }

    /// The microphone starts on its own queue. The ask passes through
    /// the main thread only to check the session is still the wanted
    /// one — a draft closed during prepare must not start the mic — and
    /// because `stop` is queued from main too, a session superseded
    /// after that check still has its start queued ahead of the
    /// successor's stop, which then takes the tap off again.
    private static func startMicrophone(_ microphone: AudioInput, device: String?, within seconds: TimeInterval,
                                        stillWanted: @escaping @MainActor () -> Bool,
                                        sink: @escaping (AVAudioPCMBuffer) -> Void) async throws
        -> (format: AVAudioFormat, name: String?) {
        // Bounded, because the thing on the other side of this call is a
        // serial queue with CoreAudio on it, and CoreAudio blocks. Every
        // call here used to wait forever: `start` hands its completion to
        // that queue, and a queue wedged by a device transition — which
        // is what a cold audio stack after a restart is — never runs the
        // block, never resumes the continuation, and parks this whole
        // task for the life of the process. The draft then said "opening
        // the microphone" until it was closed and opened again. A
        // deadline turns that into an attempt that failed, which the
        // loop above can retry and the register line can report.
        try await SpeechStart.withDeadline(seconds) {
            try await withCheckedThrowingContinuation { continuation in
                Task { @MainActor in
                    guard stillWanted() else {
                        continuation.resume(throwing: CancellationError()); return
                    }
                    microphone.start(device: device, sink: sink) { continuation.resume(with: $0) }
                }
            }
        }
    }

    /// A file's audio, in 100ms slices at real-time pace, through the same
    /// feed the tap uses. The tap keeps running beside it; a quiet room
    /// adds nothing.
    func feed(file url: URL) async {
        guard let feed, !stopped else { return }
        guard let audio = try? AVAudioFile(forReading: url) else {
            Log.info("draft", ["speech": "audio file unreadable", "file": url.lastPathComponent])
            return
        }
        let sliceFrames = AVAudioFrameCount(audio.processingFormat.sampleRate / 10)
        let wall = Date()
        var streamed: AVAudioFramePosition = 0
        Log.info("draft", ["speech": "feeding file", "file": url.lastPathComponent,
                           "seconds": Int(Double(audio.length) / audio.processingFormat.sampleRate)])
        while streamed < audio.length, !stopped {
            guard let slice = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: sliceFrames),
                  (try? audio.read(into: slice, frameCount: sliceFrames)) != nil, slice.frameLength > 0 else { break }
            streamed += AVAudioFramePosition(slice.frameLength)
            feed.push(slice)
            let audioClock = Double(streamed) / audio.processingFormat.sampleRate
            let ahead = audioClock - Date().timeIntervalSince(wall)
            if ahead > 0 { try? await Task.sleep(for: .milliseconds(Int(ahead * 1000))) }
        }
        Log.info("draft", ["speech": "file fed"])
    }

    private func noteResultsEnded(_ error: Error) {
        if !stopped { Log.info("draft", ["speech": "results ended", "error": "\(error)"]) }
    }

    func stop() async {
        stopped = true
        stopOwnBridge()
        if let feed {
            Log.info("draft", ["speech": "audio summary", "buffers": feed.buffers,
                               "peakDb": Int(20 * log10(max(feed.peak, 1e-7)))])
        }
        continuation?.finish()
        continuation = nil
        // Let the last words settle; the probe measured ~100ms. Bounded, so
        // a wedged recognizer can never hold the paste.
        if let analyzer {
            // Let the last words settle; the probe measured ~100ms. Bounded,
            // so a wedged recognizer can never hold the paste: past the
            // deadline it is cut off, not waited for.
            let finish = Task { () -> Bool in
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
                return true
            }
            let timeout = Task { () -> Bool in
                try? await Task.sleep(for: .milliseconds(700))
                return false
            }
            let finished = await Task.select(finish, timeout)
            if !finished { await analyzer.cancelAndFinishNow() }
        }
        results?.cancel()
        results = nil
        analyzer = nil
        transcriber = nil
    }
}

/// The Mac's own microphone, run beside the headset's engine while the
/// headset wakes (see `AnalyzerBox.openBridge`).
///
/// An audio queue bound to the device by its UID, not an engine: an
/// `AVAudioEngine` pointed at the built-in microphone while a headset is
/// the default keeps the default's format on its input node (16 kHz, the
/// headset's telephone rate, against the microphone's 48) and either
/// refuses to start (-10868) or starts and delivers nothing — measured
/// four ways on 2026-09-28. The queue started in 70 ms with its first
/// buffer at 80. Let go the way `AudioInput` lets go of an engine, kept
/// a while before it is disposed.
final class BridgeMic: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.vaccone.lodestar.audio.bridge", qos: .userInitiated)
    /// One bridge, open: how to pause, resume and let it go.
    struct Opened {
        let pause: () -> Void
        let resume: () -> Void
        let stop: () -> Void
    }
    /// What opens the device on the bridge's queue, feeding `sink`: the
    /// audio queue below, or a stand-in under the tests. Nil when it would
    /// not open.
    typealias Opener = (_ device: AudioDeviceID, _ queue: DispatchQueue,
                        _ sink: @escaping (AVAudioPCMBuffer) -> Void) -> Opened?
    private let opener: Opener
    private var opened: Opened?

    init(opener: @escaping Opener = BridgeMic.audioQueue) {
        self.opener = opener
    }

    /// Whether a session gets a bridge: the Mac's own microphone, standing
    /// in for the device the session will read. Only with the lid known
    /// to be open (closed, it reads zeros), only for a Bluetooth target
    /// that is not the Mac's microphone itself, and never when switched
    /// off. The facts that cost a CoreAudio query are asked only as far
    /// as needed.
    static func plan(disabled: Bool, builtIn: () -> AudioDeviceID?, lidClosed: () -> Bool?,
                     target: () -> AudioDeviceID?, isBluetooth: (AudioDeviceID) -> Bool)
        -> (bridge: AudioDeviceID, target: AudioDeviceID)? {
        guard !disabled, let builtIn = builtIn(), lidClosed() == false,
              let target = target(), target != builtIn, isBluetooth(target) else { return nil }
        return (builtIn, target)
    }
    /// Whose bridge is open. One bridge serves every draft in turn, and a
    /// draft winding down after the next one opened used to stop the new
    /// draft's bridge along with its own. A ticket is taken before the
    /// start, so a start that lands after its draft gave up on it is
    /// stopped by that draft's ticket and nobody else's.
    private var openTicket: Int?
    private let ticketLock = NSLock()
    private var nextTicket = 0

    func reserveTicket() -> Int {
        ticketLock.withLock {
            nextTicket += 1
            return nextTicket
        }
    }
    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                              channels: 1, interleaved: false)!
    private static let framesPerBuffer: UInt32 = 1024

    func start(device: AudioDeviceID, ticket: Int, sink: @escaping (AVAudioPCMBuffer) -> Void,
               completion: @escaping (Bool) -> Void) {
        queue.async {
            self.stopNow()
            guard let opened = self.opener(device, self.queue, sink) else { completion(false); return }
            self.opened = opened
            self.openTicket = ticket
            completion(true)
        }
    }

    /// The bridge as the app runs it: an audio queue on the device's UID.
    static func audioQueue(device: AudioDeviceID, queue: DispatchQueue,
                           sink: @escaping (AVAudioPCMBuffer) -> Void) -> Opened? {
        guard var uid = Self.uid(of: device) else { return nil }
        var description = Self.format.streamDescription.pointee
        var made: AudioQueueRef?
        let status = AudioQueueNewInputWithDispatchQueue(&made, &description, 0, queue) { aq, raw, _, _, _ in
            let frames = raw.pointee.mAudioDataByteSize / UInt32(MemoryLayout<Float>.size)
            if frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: frames),
               let channel = buffer.floatChannelData?[0] {
                buffer.frameLength = frames
                channel.update(from: raw.pointee.mAudioData.assumingMemoryBound(to: Float.self), count: Int(frames))
                sink(buffer)
            }
            AudioQueueEnqueueBuffer(aq, raw, 0, nil)
        }
        guard status == noErr, let aq = made else { return nil }
        guard AudioQueueSetProperty(aq, kAudioQueueProperty_CurrentDevice, &uid,
                                    UInt32(MemoryLayout<CFString>.size)) == noErr else {
            AudioQueueDispose(aq, true); return nil
        }
        for _ in 0..<3 {
            var buffer: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(aq, Self.framesPerBuffer * UInt32(MemoryLayout<Float>.size), &buffer)
            if let buffer { AudioQueueEnqueueBuffer(aq, buffer, 0, nil) }
        }
        guard AudioQueueStart(aq, nil) == noErr else {
            AudioQueueDispose(aq, true); return nil
        }
        return Opened(pause: { AudioQueuePause(aq) }, resume: { AudioQueueStart(aq, nil) }, stop: {
            AudioQueueStop(aq, true)
            queue.asyncAfter(deadline: .now() + AudioInput.retirement) { AudioQueueDispose(aq, true) }
        })
    }

    func pause() { queue.async { self.opened?.pause() } }
    func resume() { queue.async { self.opened?.resume() } }
    /// Whatever is open: a new draft, or the session ending.
    func stop() { queue.async { self.stopNow() } }

    /// Only the bridge this ticket opened.
    func stop(ticket: Int) {
        queue.async {
            guard self.openTicket == ticket else { return }
            self.stopNow()
        }
    }

    private func stopNow() {
        guard let opened else { return }
        self.opened = nil
        openTicket = nil
        opened.stop()
    }

    #if DEBUG
    /// For the tests: everything asked of the bridge's queue so far, done.
    func drain() { queue.sync {} }
    #endif

    private static func uid(of device: AudioDeviceID) -> CFString? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue()
    }
}

/// Two microphones, one recognizer: whose buffers reach the feed.
///
/// Without a bridge the headset's go straight through, zeros and all, as
/// they always have. With one, the Mac's microphone is heard until the
/// headset's first buffer with signal — its telephone link comes up
/// silent before it comes up live, and switching on its first buffer
/// would trade a voice for silence — and from then on only the headset.
/// Both taps call in on their own audio threads, so the feed, which is
/// not thread-safe, is only ever pushed under the lock.
final class Handover: @unchecked Sendable {
    private let lock = NSLock()
    private let push: (AVAudioPCMBuffer) -> Void
    private var bridging = false
    private var bridgeOpen = false
    private var headsetLive = false
    private var openedAt = Date()
    /// Runs on the audio thread, once, with how long the bridge stood in.
    var onHandover: ((Int) -> Void)?

    init(push: @escaping (AVAudioPCMBuffer) -> Void) { self.push = push }

    func openBridge() {
        lock.withLock {
            bridgeOpen = true
            bridging = !headsetLive
            openedAt = Date()
        }
    }

    /// The headset's start is being retried: its engine restarts, and
    /// the bridge, still open, is heard again until it has a voice again.
    func bridgeAgain() {
        lock.withLock {
            guard bridgeOpen else { return }
            headsetLive = false
            bridging = true
        }
    }

    func fromBridge(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard bridging, !headsetLive else { return }
        push(buffer)
    }

    func fromHeadset(_ buffer: AVAudioPCMBuffer) {
        var handedAfter: Int?
        lock.lock()
        if !headsetLive, !bridging || AudioInput.hasSignal(buffer) {
            headsetLive = true
            if bridging { handedAfter = Int(Date().timeIntervalSince(openedAt) * 1000) }
            bridging = false
        }
        if headsetLive { push(buffer) }
        lock.unlock()
        if let handedAfter { onHandover?(handedAfter) }
    }
}

/// The audio tap's side: converts each buffer to the analyzer's format
/// and hands it over. Owned by the tap's thread; the actor only makes it.
@available(macOS 26, *)
private final class AudioFeed: @unchecked Sendable {
    private let outFormat: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let onLevel: (Float, Double) -> Void
    /// Fired once, on the first buffer with signal. A device the system
    /// names can deliver nothing but zeros (a dock, a monitor, a radio
    /// mid-flip), and the engine reports running on it all the same:
    /// this is the fact the engine's state cannot carry.
    private let onAlive: () -> Void
    private var alive = false
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    private var lastLevelAt = Date.distantPast
    /// What flowed, for the log at the end: proof the tap delivered, and
    /// how loud the loudest moment was.
    private(set) var buffers = 0
    private(set) var peak: Float = 0

    private let held: HeldAudio

    init(outFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation, held: HeldAudio,
         onLevel: @escaping (Float, Double) -> Void, onAlive: @escaping () -> Void) {
        self.outFormat = outFormat
        self.continuation = continuation
        self.held = held
        self.onLevel = onLevel
        self.onAlive = onAlive
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        buffers += 1
        meter(buffer)
        if converter == nil || inFormat != buffer.format {
            inFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
        }
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: out))
            hold(out)
        }
    }

    /// What the recognizer was fed, kept on its timeline for a settling ear.
    private func hold(_ buffer: AVAudioPCMBuffer) {
        let count = Int(buffer.frameLength)
        if let floats = buffer.floatChannelData {
            held.append(UnsafeBufferPointer(start: floats[0], count: count), rate: outFormat.sampleRate)
        } else if let ints = buffer.int16ChannelData {
            held.append(UnsafeBufferPointer(start: ints[0], count: count).map { Float($0) / 32_768 },
                        rate: outFormat.sampleRate)
        }
    }

    /// RMS of the first channel, as a 0…1 level, at most ten times a
    /// second: enough for a meter, nothing for a recognizer.
    private func meter(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        // Every buffer is read until one carries signal; after that, ten
        // a second.
        guard !alive || now.timeIntervalSince(lastLevelAt) > 0.1, let data = buffer.floatChannelData,
              buffer.frameLength > 0 else { return }
        let samples = UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()
        // -100 dBFS: measured, a live room never reads below -97 and a
        // deaf device reads exactly -140.
        if !alive, rms > 1e-5 {
            alive = true
            DispatchQueue.main.async { self.onAlive() }
        }
        guard now.timeIntervalSince(lastLevelAt) > 0.1 else { return }
        lastLevelAt = now
        // Speech at a normal distance sits around -30 dBFS; the meter's
        // top is a raised voice, its floor silence.
        let db = 20 * log10(max(rms, 1e-7))
        let level = max(0, min(1, (db + 55) / 45))
        peak = max(peak, rms)
        DispatchQueue.main.async { self.onLevel(level, Double(db)) }
    }
}

private extension Task where Failure == Never {
    /// Whichever finishes first; the other keeps running.
    static func select(_ a: Task<Success, Never>, _ b: Task<Success, Never>) async -> Success {
        await withTaskGroup(of: Success.self) { group in
            group.addTask { await a.value }
            group.addTask { await b.value }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }
}
