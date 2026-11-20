import AppKit
import CoreAudio
import LodestarCore
import Stoic
import Synchronization

/// Reduce loud audio's hands (`LoudAudio` holds the rules). While a level
/// is chosen and the default output says it is headphones, two things hold the
/// volume at the ceiling:
///
/// - A session tap on system-defined events alone, on a thread of its own,
///   swallows volume-up when the step would cross the ceiling, and sets the
///   volume to the ceiling itself (and unmutes), so a stopped press still
///   lands where the slider could. Letting the key through and putting the
///   volume back after is not enough: the keys step from the system's own
///   count, which a set volume does not move, so each press climbed from the
///   last (`probe listening clamp`).
/// - A listener on the volume puts back any other raise: the slider, an app,
///   the headset's own buttons. These cannot be stopped before they land, so
///   each plays for 15 to 45 ms before it is put back, and the keys then step
///   from the ceiling with no drift (`probe listening drift`).
///
/// Bluetooth headphones are held through one assumed curve
/// (`LoudAudio.bluetoothCurve`), since the curve each reports is a guess that
/// differs by maker and by mode. Wired ones are held through the device's own
/// curve, which can read wrongly while the device changes (a flat 0 dB, as
/// AirPods did on connecting). Such a curve holds nothing, and the guard reads
/// it again as the device settles (`settleDelays`) and whenever its range
/// changes.
///
/// With it off, or speakers out, there is no tap and no volume
/// listener: nothing runs but a listener on which output is the default.
///
/// CoreAudio is touched only on `queue`. The tap's callback reads the volume
/// the listener last saw, under a lock held for microseconds, and never asks
/// CoreAudio itself: every volume key waits on it.
final class LoudAudioGuard: Sendable {
    /// What is held now: the device, its volume elements, the ceiling in its
    /// own scale, and the volume last seen.
    private struct Held {
        var device: AudioObjectID
        var elements: [UInt32]
        var ceiling: Float
        var volume: Float
    }

    private struct Listener {
        var object: AudioObjectID
        var address: AudioObjectPropertyAddress
        var block: AudioObjectPropertyListenerBlock
    }

    private struct State {
        var level = LoudAudio.Level.off
        /// The default output being watched, and what is listened to on it.
        var device: AudioObjectID = 0
        var system: Listener?
        var deviceListeners: [Listener] = []
        var held: Held?
        /// Raises put back since the hold began, said in the log when it ends.
        var putBack = 0
        /// Whether this hold has said so yet: the first time it stops the
        /// volume, a note says why and where it is set, and then no more,
        /// until other headphones or another level.
        var noticed = false
        var tap: CFMachPort?
        var loop: CFRunLoop?
        var generation = 0
        /// Reads again since the curve last failed to place a ceiling.
        var settling = 0
        /// The one read to come, a settle or a confirm: a newer one, or
        /// turning the setting off, cancels it.
        var later: Task<Void, Never>?
    }

    private let state = Mutex(State())
    private let notice = Mutex<(@Sendable (LoudAudio.Level) -> Void)?>(nil)
    private let queue = DispatchQueue(label: "lodestar.loud-audio", qos: .userInteractive)

    /// When the curve is read again after it failed to place a ceiling, in
    /// seconds after each failure: a headset settles within a second or two
    /// of connecting or changing mode, and a device that never does is left
    /// alone after a minute, until it changes again.
    static let settleDelays: [Duration] = [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2),
                                           .seconds(4), .seconds(8), .seconds(15), .seconds(30)]
    /// When a new hold reads its curve once more, in case the device moved it
    /// without saying so.
    static let confirmDelay = Duration.seconds(2)

    /// Whether anything real may run. A test run never holds the volume of
    /// the person at the desk.
    private let live: Bool

    init(live: Bool = !TestRun.active) {
        self.live = live
    }

    /// What to do the first time a hold stops the volume: called on the
    /// tap's thread or the queue, so the receiver hops to main itself.
    func onHeld(_ action: @escaping @Sendable (LoudAudio.Level) -> Void) {
        notice.withLock { $0 = action }
    }

    /// Main. The level, from the config.
    func configure(level: LoudAudio.Level) {
        guard live else { return }
        queue.async { self.apply(level) }
    }

    // MARK: on the queue

    private func apply(_ level: LoudAudio.Level) {
        let was = state.withLock { s in
            defer {
                s.level = level
                s.noticed = false
            }
            return s.level
        }
        guard was != level else { return }
        Log.info("loud-audio", ["level": level.rawValue])
        if was != .off, level != .off {
            // Another level on the same hold: the ceiling moves, and refresh
            // moves the listeners with it.
            refresh()
        } else if level != .off {
            let address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
            if let listener = listen(Self.system, address, { [weak self] in self?.refresh() }) {
                state.withLock { $0.system = listener }
            }
            refresh()
        } else {
            if let listener = state.withLock({ s in defer { s.system = nil; s.later?.cancel(); s.later = nil }; return s.system }) {
                remove(listener)
            }
            release(reason: "off")
            watch(0)
        }
    }

    /// The default output, or what it is, changed: hold it if it is
    /// headphones, let it go if not.
    private func refresh() {
        let level = state.withLock { $0.level }
        guard level != .off else { return }
        let device = Self.read(Self.system, Self.address(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0)) ?? 0
        watch(device)
        guard device != 0, Self.isHeadphones(device) else {
            release(reason: "not headphones")
            return
        }
        // Wired headphones are driven by the Mac, which gets them louder
        // than Bluetooth ones drive themselves: their ceiling is lower.
        let transport = Self.read(device, Self.address(kAudioDevicePropertyTransportType), UInt32(0))
        let fullScale = LoudAudio.fullScaleDBA(transport: transport)
        guard let ceilingDecibels = level.ceilingDecibels(fullScaleDBA: fullScale) else { return }
        let elements = Self.volumeElements(device)
        // Bluetooth headphones are held through one curve, whatever they
        // report (`LoudAudio.bluetoothCurve`); wired ones through their own,
        // which is the Mac's own gain.
        let bluetooth = LoudAudio.isBluetooth(transport: transport)
        let decibels: (Float) -> Float? = { scalar in
            guard let first = elements.first else { return nil }
            return bluetooth ? LoudAudio.bluetoothDecibels(scalar) : Self.decibels(device, first, scalar: scalar)
        }
        guard let first = elements.first,
              let ceiling = LoudAudio.ceilingScalar(ceilingDecibels, decibels: decibels) else {
            release(reason: "no volume curve")
            settleLater(curve: elements.first.map { Self.curveText(device, $0) } ?? "none")
            return
        }
        state.withLock { $0.settling = 0 }
        let volume = elements.compactMap { Self.scalar(device, $0) }.max() ?? 0
        // The same headset changes its controls when it changes mode: in a
        // call (the microphone open, 16 kHz) a Bluetooth headset's two
        // channels become one main volume on another curve (−40…0 became
        // −32…0 on 2026-11-18). Listeners on controls that are gone hear
        // nothing, so the volume ones follow the controls there are now.
        let (unchanged, stale) = state.withLock { s -> (Bool, [Listener]) in
            let unchanged = s.held?.device == device && s.held?.elements == elements && s.held?.ceiling == ceiling
            if s.held?.device != device {
                s.putBack = 0
                s.noticed = false
            }
            s.held = Held(device: device, elements: elements, ceiling: ceiling, volume: volume)
            guard !unchanged else { return (true, []) }
            let stale = s.deviceListeners.filter { Self.isHoldListener($0) }
            s.deviceListeners.removeAll { Self.isHoldListener($0) }
            return (false, stale)
        }
        if !unchanged {
            stale.forEach(remove)
            for element in elements {
                let volume = Self.address(kAudioDevicePropertyVolumeScalar, Self.output, element)
                if let listener = listen(device, volume, { [weak self] in self?.volumeMoved() }) {
                    state.withLock { $0.deviceListeners.append(listener) }
                }
                // The curve moving under the same controls moves the ceiling.
                let range = Self.address(kAudioDevicePropertyVolumeRangeDecibels, Self.output, element)
                if let listener = listen(device, range, { [weak self] in self?.refresh() }) {
                    state.withLock { $0.deviceListeners.append(listener) }
                }
            }
            Log.info("loud-audio", ["held": "headphones", "elements": elements.map(String.init).joined(separator: ","),
                                    "full-scale-dba": Int(fullScale),
                                    "curve-db": bluetooth ? "bluetooth" : Self.curveText(device, first),
                                    "reported-curve-db": Self.curveText(device, first),
                                    "ceiling-db": String(format: "%.1f", ceilingDecibels),
                                    "ceiling": String(format: "%.3f", ceiling),
                                    "volume-db": String(format: "%.1f", decibels(volume) ?? 0)])
            refreshLater(after: Self.confirmDelay)
        }
        putBackIfOver()
        startTap()
    }

    /// The curve placed no ceiling: read it again once the device has had a
    /// moment, a little later each time, and give up after `settleDelays`.
    private func settleLater(curve: String) {
        let attempt = state.withLock { s -> Int? in
            guard s.settling < Self.settleDelays.count else { return nil }
            defer { s.settling += 1 }
            return s.settling
        }
        guard let attempt else {
            Log.info("loud-audio", ["unsettled": "gave up", "curve-db": curve])
            return
        }
        if attempt == 0 { Log.info("loud-audio", ["unsettled": "volume curve", "curve-db": curve]) }
        refreshLater(after: Self.settleDelays[attempt])
    }

    /// Read the device again after `delay`, on the queue, in place of any
    /// read already waiting. The ambient clock, so a test can advance it.
    private func refreshLater(after delay: Duration) {
        let task = Task { [weak self] in
            // The sleep throws only CancellationError: a newer read, or the setting off, took its place.
            do { try await Ambient.sleep(for: delay) } catch { return }
            self?.queue.async { self?.refresh() }
        }
        state.withLock { s in
            s.later?.cancel()
            s.later = task
        }
    }

    /// Listen to what changes when headphones go into the jack, or a device
    /// changes what it is or how its volume is controlled: its data source,
    /// its streams, its sample rate (a headset going into a call) and its
    /// controls. Moving to another device drops every listener on the last.
    private func watch(_ device: AudioObjectID) {
        let (old, listeners) = state.withLock { s -> (AudioObjectID, [Listener]) in
            guard s.device != device else { return (device, []) }
            defer { s.device = device; s.deviceListeners = [] }
            return (s.device, s.deviceListeners)
        }
        guard old != device else { return }
        state.withLock { $0.settling = 0 }
        listeners.forEach(remove)
        state.withLock { if $0.held?.device == old { $0.held = nil } }
        guard device != 0 else { return }
        let layout = [
            Self.address(kAudioDevicePropertyDataSource, Self.output),
            Self.address(kAudioDevicePropertyStreams, Self.output),
            Self.address(kAudioDevicePropertyNominalSampleRate),
            Self.address(kAudioObjectPropertyControlList),
        ]
        for address in layout {
            if let listener = listen(device, address, { [weak self] in self?.refresh() }) {
                state.withLock { $0.deviceListeners.append(listener) }
            }
        }
    }

    private func volumeMoved() {
        guard let held = state.withLock({ $0.held }) else { return }
        let volume = held.elements.compactMap { Self.scalar(held.device, $0) }.max() ?? 0
        state.withLock { $0.held?.volume = volume }
        putBackIfOver()
    }

    /// Any element over the ceiling is set to it.
    private func putBackIfOver() {
        guard let held = state.withLock({ $0.held }) else { return }
        var moved = false
        for element in held.elements {
            guard let volume = Self.scalar(held.device, element), LoudAudio.isOver(volume, ceiling: held.ceiling) else {
                continue
            }
            var value = held.ceiling
            var address = Self.address(kAudioDevicePropertyVolumeScalar, Self.output, element)
            let status = AudioObjectSetPropertyData(held.device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
            if status == noErr { moved = true } else { Log.error("loud-audio", ["put-back": "failed", "status": status]) }
        }
        if moved {
            state.withLock { s in
                s.putBack += 1
                s.held?.volume = held.ceiling
            }
            noticeOnce()
        }
    }

    /// Nothing held: the tap stops and the volume listeners go. The volume
    /// stays where it is.
    private func release(reason: String) {
        let (held, putBack, listeners) = state.withLock { s -> (Held?, Int, [Listener]) in
            defer {
                s.held = nil
                s.putBack = 0
                s.noticed = false
            }
            let volumeListeners = s.deviceListeners.filter { Self.isHoldListener($0) }
            s.deviceListeners.removeAll { Self.isHoldListener($0) }
            return (s.held, s.putBack, volumeListeners)
        }
        listeners.forEach(remove)
        stopTap()
        if held != nil { Log.info("loud-audio", ["released": reason, "put-back": putBack]) }
    }

    /// The listeners a hold makes on its volume elements, which go when it
    /// does; the device's layout listeners stay while it is the default.
    private static func isHoldListener(_ listener: Listener) -> Bool {
        [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyVolumeRangeDecibels].contains(listener.address.mSelector)
    }

    /// A press the tap stopped short of the ceiling: the volume goes to the
    /// ceiling and sound comes back on, which is what the press asked for, as
    /// far as the hold allows.
    private func raiseToCeiling() {
        guard let held = state.withLock({ $0.held }) else { return }
        var raised = false
        for element in held.elements {
            guard let volume = Self.scalar(held.device, element), volume < held.ceiling - LoudAudio.tolerance else { continue }
            var value = held.ceiling
            var address = Self.address(kAudioDevicePropertyVolumeScalar, Self.output, element)
            let status = AudioObjectSetPropertyData(held.device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
            if status == noErr { raised = true } else { Log.error("loud-audio", ["raise": "failed", "status": status]) }
        }
        if raised { state.withLock { $0.held?.volume = held.ceiling } }
        // Mute is on the main element, or on each channel, as the device has it.
        for element in Set([kAudioObjectPropertyElementMain] + held.elements) {
            var address = Self.address(kAudioDevicePropertyMute, Self.output, element)
            guard Self.read(held.device, address, UInt32(0)) == 1 else { continue }
            var off: UInt32 = 0
            AudioObjectSetPropertyData(held.device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &off)
        }
        putBackIfOver()
    }

    private func listen(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
                        _ action: @escaping @Sendable () -> Void) -> Listener? {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in action() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return nil }
        return Listener(object: object, address: address, block: block)
    }

    private func remove(_ listener: Listener) {
        var address = listener.address
        AudioObjectRemovePropertyListenerBlock(listener.object, &address, queue, listener.block)
    }

    // MARK: the key tap

    /// The callback's whole work. Internal so a test can hand it an event.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = state.withLock({ $0.tap }) { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == Self.systemDefined, let key = NSEvent(cgEvent: event),
              LoudAudio.isVolumeUp(subtype: Int(key.subtype.rawValue), data1: key.data1) else {
            return Unmanaged.passUnretained(event)
        }
        let fine = event.flags.contains(.maskAlternate) && event.flags.contains(.maskShift)
        let swallow = state.withLock { s in
            s.held.map { LoudAudio.swallowsVolumeUp(at: $0.volume, step: LoudAudio.keyStep(fine: fine), ceiling: $0.ceiling) }
                ?? false
        }
        guard swallow else { return Unmanaged.passUnretained(event) }
        if live, LoudAudio.isPress(data1: key.data1) {
            queue.async { [weak self] in self?.raiseToCeiling() }
        }
        noticeOnce()
        return nil
    }

    /// The hold stopped the volume: the first time, say so.
    private func noticeOnce() {
        let level = state.withLock { s -> LoudAudio.Level? in
            guard s.held != nil, !s.noticed else { return nil }
            s.noticed = true
            return s.level
        }
        guard let level, let action = notice.withLock({ $0 }) else { return }
        action(level)
    }

    /// What the listener would have filed, for a test that hands `handle`
    /// events: a ceiling held, at a volume. Nil holds nothing.
    func pretendHeld(ceiling: Float?, volume: Float, level: LoudAudio.Level = .standard) {
        state.withLock { s in
            s.held = ceiling.map { Held(device: 0, elements: [], ceiling: $0, volume: volume) }
            s.level = level
        }
    }

    /// Whether a real tap is running.
    var isTapping: Bool { state.withLock { $0.tap != nil } }

    private func startTap() {
        let mine = state.withLock { s -> Int? in
            guard s.tap == nil else { return nil }
            s.generation += 1
            return s.generation
        }
        guard let mine else { return }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            defer { ready.signal() }
            guard let self else { return }
            let callback: CGEventTapCallBack = { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<LoudAudioGuard>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
            }
            // At the head, so the key is gone before anything after acts on it.
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(1) << CGEventMask(Self.systemDefined),
                callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                Log.error("loud-audio", ["tap": "not made"])
                return
            }
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
            let current = self.state.withLock { s -> Bool in
                guard s.generation == mine else { return false }
                s.tap = tap
                s.loop = loop
                return true
            }
            guard current else {
                CFMachPortInvalidate(tap)
                return
            }
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "lodestar.loud-audio.tap"
        // Every volume key waits on this thread.
        thread.qualityOfService = .userInteractive
        thread.start()
        _ = ready.wait(timeout: .now() + 1)
    }

    private func stopTap() {
        let (tap, loop) = state.withLock { s -> (CFMachPort?, CFRunLoop?) in
            defer {
                s.tap = nil
                s.loop = nil
                s.generation += 1
            }
            return (s.tap, s.loop)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let loop { CFRunLoopStop(loop) }
    }

    /// NX_SYSDEFINED: the event type media keys arrive as.
    private static let systemDefined: UInt32 = 14

    // MARK: CoreAudio

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let output = kAudioDevicePropertyScopeOutput

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                _ element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func read<T: BitwiseCopyable>(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress,
                                                 _ initial: T) -> T? {
        var address = address
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// Headphones by what the output says it is: its first output stream's
    /// terminal type, or the built-in jack's data source.
    private static func isHeadphones(_ device: AudioObjectID) -> Bool {
        let stream = read(device, address(kAudioDevicePropertyStreams, output), AudioObjectID(0))
        let terminal = stream.flatMap { read($0, address(kAudioStreamPropertyTerminalType), UInt32(0)) }
        let source = read(device, address(kAudioDevicePropertyDataSource, output), UInt32(0))
        return LoudAudio.isHeadphones(terminal: terminal, dataSource: source)
    }

    /// The elements that carry the output volume: main where the device has
    /// one, else its channels (Bluetooth has 1 and 2 and no main).
    private static func volumeElements(_ device: AudioObjectID) -> [UInt32] {
        let main = address(kAudioDevicePropertyVolumeScalar, output, kAudioObjectPropertyElementMain)
        var probe = main
        if AudioObjectHasProperty(device, &probe) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter { element in
            var channel = address(kAudioDevicePropertyVolumeScalar, output, element)
            return AudioObjectHasProperty(device, &channel)
        }
    }

    private static func scalar(_ device: AudioObjectID, _ element: UInt32) -> Float32? {
        read(device, address(kAudioDevicePropertyVolumeScalar, output, element), Float32(0))
    }

    /// The curve's silent and full dB, for the log: "-40.0…0.0".
    private static func curveText(_ device: AudioObjectID, _ element: UInt32) -> String {
        let ends = [Float32(0), 1].map { decibels(device, element, scalar: $0).map { String(format: "%.1f", $0) } ?? "?" }
        return ends.joined(separator: "…")
    }

    /// The device's own translation, not kAudioDevicePropertyVolumeDecibels,
    /// which read −75 on a Bluetooth headset whose range is −40…0.
    private static func decibels(_ device: AudioObjectID, _ element: UInt32, scalar: Float32) -> Float32? {
        read(device, address(kAudioDevicePropertyVolumeScalarToDecibels, output, element), scalar)
    }
}
