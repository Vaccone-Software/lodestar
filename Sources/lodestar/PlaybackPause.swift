import AppKit
import CoreAudio
import LodestarCore

/// Music steps aside while the draft listens.
///
/// Opening the microphone on a Bluetooth headset drops the whole device
/// to its hands-free profile — mono, telephone-band, a separately
/// remembered volume — because the classic radio cannot carry music out
/// and voice in at once. No setting prevents it, every app that opens
/// the mic causes it, and while it stands there is nothing worth
/// listening to. So whatever is playing is paused instead, and resumed
/// once the device is back on its music profile.
///
/// Derived, never configured. It acts only when the input about to be
/// read and the current output are the same Bluetooth radio, only when
/// something was verifiably playing across a small window (a keyboard
/// click app flickers in one roll call; music stands in two), and it
/// resumes only what it watched stop. The pause key is a toggle aimed at
/// whichever app owns Now Playing, so every step distrusts it: sent,
/// then checked, and any doubt collapses to doing nothing — the one
/// wrong action it could take, starting something silent, is watched for
/// and undone on the spot.
final class PlaybackPause {
    /// The system's side, behind closures so the stage can play it.
    struct World {
        /// Whether `input` (nil = the system default) and the current
        /// default output are the same Bluetooth radio.
        var sharedRoute: (String?) -> Bool
        /// Processes with audio flowing to an output right now, ours
        /// excluded. Empty on macOS before 14.4, where the roll call
        /// does not exist and the gate stays closed.
        var outputters: () -> Set<pid_t>
        /// The ⏯ a keyboard would send, to whoever owns Now Playing.
        var playPause: () -> Void
        /// The default output's nominal sample rate right now.
        var outputRate: () -> Double
        /// Watch that rate; the closure returned stops watching.
        var watchRate: (@escaping (Double) -> Void) -> () -> Void

        static let live = World(
            sharedRoute: SystemAudio.sharedBluetoothRoute,
            outputters: SystemAudio.outputtingPids,
            playPause: SystemAudio.playPauseKey,
            outputRate: { SystemAudio.outputRate() ?? 0 },
            watchRate: SystemAudio.watchOutputRate)
    }

    /// Two roll calls this far apart tell music from a click.
    static let sampleGap: TimeInterval = 0.25
    /// How long the Now Playing app gets to act on the key before the
    /// check on what it did.
    static let verifyDelay: TimeInterval = 0.8
    /// The resume never waits longer than this on a profile that is not
    /// coming back.
    static let resumeBackstop: TimeInterval = 3.0
    /// Hands-free profiles speak at 8 or 16 kHz; a rate at or above this
    /// is a music profile again.
    static let musicRate: Double = 32_000

    private enum State {
        case idle
        /// First roll call taken; the second is scheduled.
        case sampling(first: Set<pid_t>)
        /// The key went out; the check on what it did is scheduled.
        case verifying(candidates: Set<pid_t>, baseline: Set<pid_t>)
        /// These stopped when asked, so they are owed a resume.
        case paused(Set<pid_t>)
    }

    private let world: World
    private let clock: Clock
    private var state: State = .idle
    private var draftOpen = false
    private var pending: DispatchWorkItem?
    private var backstop: DispatchWorkItem?
    private var stopWatching: (() -> Void)?

    init(world: World = .live, clock: Clock = .live) {
        self.world = world
        self.clock = clock
    }

    /// The recognizer reached its listening state: the microphone is
    /// open and the profile flip, if this route flips, is under way.
    /// A session restart mid-draft calls this again; a new draft while
    /// the last resume is still owed keeps the pause standing.
    func dictationBegan(input: String?) {
        draftOpen = true
        switch state {
        case .paused:
            // The next draft inherits the quiet; the resume waits for
            // this one's own end.
            cancelResume()
        case .sampling, .verifying:
            break
        case .idle:
            guard world.sharedRoute(input) else {
                Log.info("draft", ["playback": "no shared radio"])
                return
            }
            let first = world.outputters()
            guard !first.isEmpty else {
                Log.info("draft", ["playback": "nothing playing"])
                return
            }
            state = .sampling(first: first)
            let work = DispatchWorkItem { [weak self] in self?.secondSample() }
            pending = work
            clock.after(Self.sampleGap, work)
        }
    }

    /// The draft closed, whatever the ending.
    func dictationEnded() {
        draftOpen = false
        switch state {
        case .idle:
            break
        case .sampling:
            // No key was sent; there is nothing to undo.
            pending?.cancel()
            pending = nil
            state = .idle
        case .verifying:
            // The check still lands, and starts the resume itself.
            break
        case .paused:
            beginResume()
        }
    }

    private func secondSample() {
        guard case .sampling(let first) = state else { return }
        guard draftOpen else { state = .idle; return }
        let second = world.outputters()
        let playing = first.intersection(second)
        guard !playing.isEmpty else { state = .idle; return }
        world.playPause()
        Log.info("draft", ["playback": "pause sent", "playing": playing.count])
        state = .verifying(candidates: playing, baseline: first.union(second))
        let work = DispatchWorkItem { [weak self] in self?.verify() }
        pending = work
        clock.after(Self.verifyDelay, work)
    }

    private func verify() {
        guard case .verifying(let candidates, let baseline) = state else { return }
        let after = world.outputters()
        let stopped = candidates.subtracting(after)
        let started = after.subtracting(baseline)
        if !stopped.isEmpty {
            state = .paused(stopped)
            Log.info("draft", ["playback": "paused", "stopped": stopped.count])
            if !draftOpen { beginResume() }
        } else if !started.isEmpty {
            // The toggle toggled something on. Undo it, owe nothing.
            world.playPause()
            state = .idle
            Log.info("draft", ["playback": "misfire undone"])
        } else {
            // The key went nowhere — a call, no Now Playing app, or a
            // player that paused but kept a silent stream open. All
            // indistinguishable from here, so nothing is owed: a pause
            // this could strand is one keypress to undo, a guess is not.
            state = .idle
            Log.info("draft", ["playback": "no effect"])
        }
    }

    /// The draft is closed and a resume is owed: send it the moment the
    /// output is a music profile again, or at the backstop, whichever
    /// comes first. Resuming into a still-flipped profile would put the
    /// first seconds of music through the telephone band.
    private func beginResume() {
        guard case .paused = state else { return }
        if world.outputRate() >= Self.musicRate { resume(); return }
        stopWatching = world.watchRate { [weak self] rate in
            guard rate >= Self.musicRate else { return }
            self?.resume()
        }
        let work = DispatchWorkItem { [weak self] in self?.resume() }
        backstop = work
        clock.after(Self.resumeBackstop, work)
    }

    private func resume() {
        guard case .paused(let owed) = state else { return }
        cancelResume()
        state = .idle
        // A hand may have pressed play first; a resume on top of that
        // is the toggle's other wrong action. Owed pids audible again
        // mean the debt was settled by the user, not by us.
        if !owed.isDisjoint(with: world.outputters()) {
            Log.info("draft", ["playback": "resumed by hand"])
            return
        }
        world.playPause()
        Log.info("draft", ["playback": "resumed"])
    }

    private func cancelResume() {
        stopWatching?()
        stopWatching = nil
        backstop?.cancel()
        backstop = nil
    }
}

/// The CoreAudio and event-posting side, kept apart from the decisions.
enum SystemAudio {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// 'abcd' → the selector, for the process properties macOS 14.4
    /// added: asked by raw value, the binary still links on 13, where
    /// the question has no answer and answers empty.
    private static func selector(_ code: String) -> AudioObjectPropertySelector {
        code.utf8.reduce(0) { $0 << 8 | AudioObjectPropertySelector($1) }
    }

    private static func readU32(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var address = address
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func readDouble(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Double? {
        var address = address
        var value = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func readString(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var address = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    private static func readList(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    static func defaultOutput() -> AudioDeviceID? {
        guard let id = readU32(system, address(kAudioHardwarePropertyDefaultOutputDevice)),
              id != kAudioObjectUnknown else { return nil }
        return AudioDeviceID(id)
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32? {
        readU32(id, address(kAudioDevicePropertyTransportType))
    }

    private static func bluetooth(_ id: AudioDeviceID) -> Bool {
        let transport = transport(id)
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// One radio presents as two devices — "…7C-57:input" and
    /// "…7C-57:output", different ids, different UIDs. The root before
    /// the last colon (the whole UID when there is none) is the radio.
    private static func uidRoot(_ id: AudioDeviceID) -> String? {
        guard let uid = readString(id, address(kAudioDevicePropertyDeviceUID)) else { return nil }
        guard let colon = uid.lastIndex(of: ":") else { return uid }
        return String(uid[..<colon])
    }

    /// Whether the input the draft is about to read and the current
    /// default output are the same Bluetooth radio — the one condition
    /// under which opening the mic degrades what is playing.
    static func sharedBluetoothRoute(input name: String?) -> Bool {
        var wanted = name.flatMap { name in AudioInput.inputDevices().first { $0.name == name }?.id }
        // An engine following the system default reads through a private
        // aggregate its process owns ("CADefaultDeviceAggregate-<pid>-<n>"),
        // and that is the name the session can report. The wrapper is
        // never the radio itself — its transport says aggregate — but it
        // is on the owner's own device list, so the name resolves. Gate
        // on what it wraps: the system default. (v0.26.1 gated on the
        // wrapper and never opened.)
        if let id = wanted, transport(id) == kAudioDeviceTransportTypeAggregate { wanted = nil }
        guard let input = wanted ?? AudioInput.defaultInput(),
              let output = defaultOutput() else { return false }
        guard bluetooth(input), bluetooth(output) else { return false }
        guard let inRoot = uidRoot(input), let outRoot = uidRoot(output) else { return false }
        return inRoot == outRoot
    }

    /// Every process with audio flowing to an output right now, ours
    /// excluded. macOS 14.4's process roll call; older systems answer
    /// nothing and no pause is ever attempted.
    static func outputtingPids() -> Set<pid_t> {
        let me = getpid()
        var pids: Set<pid_t> = []
        for process in readList(system, address(selector("prs#"))) {
            guard readU32(process, address(selector("piro"))) == 1,
                  let raw = readU32(process, address(selector("ppid"))) else { continue }
            let pid = pid_t(bitPattern: raw)
            if pid != me { pids.insert(pid) }
        }
        return pids
    }

    static func outputRate() -> Double? {
        guard let output = defaultOutput() else { return nil }
        return readDouble(output, address(kAudioDevicePropertyNominalSampleRate))
    }

    /// Watch the default output's nominal sample rate — the profile
    /// flip made visible: 44100 falls to 16000 when hands-free takes
    /// the radio, and rises when music gets it back. Returns a cancel.
    static func watchOutputRate(_ onChange: @escaping (Double) -> Void) -> () -> Void {
        guard let device = defaultOutput() else { return {} }
        var listenAddress = address(kAudioDevicePropertyNominalSampleRate)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            onChange(readDouble(device, address(kAudioDevicePropertyNominalSampleRate)) ?? 0)
        }
        AudioObjectAddPropertyListenerBlock(device, &listenAddress, .main, block)
        return {
            var removeAddress = address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(device, &removeAddress, .main, block)
        }
    }

    /// The ⏯ a keyboard sends: NX_KEYTYPE_PLAY in a system-defined
    /// event, down then up, landing on whichever app owns Now Playing.
    static func playPauseKey() {
        postMediaKey(down: true)
        postMediaKey(down: false)
    }

    private static func postMediaKey(down: Bool) {
        // NX_KEYTYPE_PLAY = 16; data1 packs the key and its state the
        // way IOKit's hid system does.
        let data1 = Int((16 << 16) | ((down ? 0x0A : 0x0B) << 8))
        guard let event = NSEvent.otherEvent(
            with: .systemDefined, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1) else { return }
        event.cgEvent?.post(tap: .cghidEventTap)
    }
}
