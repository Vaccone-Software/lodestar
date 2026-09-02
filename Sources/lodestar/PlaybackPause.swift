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
/// hearing. So whatever is playing is paused, and resumed once the
/// device is back on its music profile.
///
/// The players are asked directly, by Apple Events, because the audio
/// system cannot answer the question. A first design inferred "playing"
/// from CoreAudio's process roll call and pressed the Now Playing ⏯:
/// measurement killed it twice on the machine it was built for — a
/// paused player keeps its silent output stream for fifteen seconds
/// (the verify read "no effect" and stranded the pause), and a
/// keyboard-click app holds one forever (the gate read "playing" from
/// silence, and the ⏯, a blind toggle, would have started music into
/// every silent dictation). Asking the player is exact in both
/// directions: pause is pause, play is play, and only what said
/// "playing" is ever owed a resume.
///
/// Derived, never configured: it acts only when the input about to be
/// read and the current output are the same Bluetooth radio, and it
/// touches only players that answered. A browser tab cannot be asked
/// and is left alone.
final class PlaybackPause {
    /// The system's side, behind closures so the stage can play it.
    ///
    /// The player calls are Apple Events, and an Apple Event can block —
    /// on a beachballing player, or on the one-time automation-consent
    /// prompt itself. The main thread hosts the event tap, so a blocked
    /// main thread holds every keyDown on the machine until macOS kills
    /// the tap. The live world therefore runs all player work on its
    /// own serial queue and completes on main; the stage completes
    /// inline.
    struct World {
        /// Whether `input` (nil = the system default) and the current
        /// default output are the same Bluetooth radio. Off the main
        /// thread, completing on main: the question is asked the moment
        /// the microphone opens, which is the moment the radio is busy
        /// flipping profiles, and CoreAudio answers a device roll call
        /// slowly while it is.
        var sharedRoute: (String?, @escaping (Bool) -> Void) -> Void
        /// Off the main thread: pause every running player that says
        /// "playing", and complete on main with who was paused.
        var pausePlaying: (@escaping ([String]) -> Void) -> Void
        /// Off the main thread: play each owed player that is not
        /// already playing — a hand that pressed play first settles the
        /// debt, and a player quit meanwhile is left quit. Completes on
        /// main with who was actually played.
        var resumePlayers: ([String], @escaping ([String]) -> Void) -> Void
        /// The default output's nominal sample rate right now.
        var outputRate: () -> Double
        /// Watch that rate; the closure returned stops watching.
        var watchRate: (@escaping (Double) -> Void) -> () -> Void

        static let live: World = {
            let queue = DispatchQueue(label: "com.vaccone.lodestar.playback")
            return World(
                sharedRoute: { input, done in
                    queue.async {
                        let shared = SystemAudio.sharedBluetoothRoute(input: input)
                        DispatchQueue.main.async { done(shared) }
                    }
                },
                pausePlaying: { done in
                    queue.async {
                        let playing = Players.playing()
                        playing.forEach(Players.pause)
                        DispatchQueue.main.async { done(playing) }
                    }
                },
                resumePlayers: { owed, done in
                    queue.async {
                        let played = owed.filter { !Players.isPlaying($0) }
                        played.forEach(Players.play)
                        DispatchQueue.main.async { done(played) }
                    }
                },
                outputRate: { SystemAudio.outputRate() ?? 0 },
                watchRate: SystemAudio.watchOutputRate)
        }()
    }

    /// The resume never waits longer than this on a profile that is not
    /// coming back.
    static let resumeBackstop: TimeInterval = 3.0
    /// Hands-free profiles speak at 8 or 16 kHz; a rate at or above
    /// this is a music profile again.
    static let musicRate: Double = 32_000

    private enum State {
        case idle
        /// The route, then the players, are being asked, off the main
        /// thread.
        case asking
        /// These players said "playing" and were paused; they are owed
        /// a resume.
        case paused([String])
    }

    private let world: World
    private let clock: Clock
    private var state: State = .idle
    private var draftOpen = false
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
        case .asking:
            break
        case .idle:
            state = .asking
            world.sharedRoute(input) { [weak self] shared in self?.routeAnswered(shared) }
        }
    }

    private func routeAnswered(_ shared: Bool) {
        guard case .asking = state else { return }
        guard shared else {
            state = .idle
            Log.info("draft", ["playback": "no shared radio"])
            return
        }
        world.pausePlaying { [weak self] paused in self?.pausedPlayers(paused) }
    }

    /// The draft closed, whatever the ending. An ask still in flight
    /// finishes on its own and starts the resume itself.
    func dictationEnded() {
        draftOpen = false
        guard case .paused = state else { return }
        beginResume()
    }

    private func pausedPlayers(_ players: [String]) {
        guard case .asking = state else { return }
        guard !players.isEmpty else {
            state = .idle
            Log.info("draft", ["playback": "nothing playing"])
            return
        }
        state = .paused(players)
        Log.info("draft", ["playback": "paused", "players": players.joined(separator: " ")])
        if !draftOpen { beginResume() }
    }

    /// Send the resume the moment the output is a music profile again,
    /// or at the backstop, whichever comes first: resuming into a
    /// still-flipped profile would put the first seconds of music
    /// through the telephone band.
    private func beginResume() {
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
        world.resumePlayers(owed) { played in
            Log.info("draft", ["playback": played.isEmpty ? "resumed by hand" : "resumed",
                               "players": played.joined(separator: " ")])
        }
    }

    private func cancelResume() {
        stopWatching?()
        stopWatching = nil
        backstop?.cancel()
        backstop = nil
    }
}

/// The players the draft can ask directly, by Apple Events: the ones
/// that own Now Playing in practice. Asking is exact — no roll call,
/// no toggle — at the price of a one-time automation consent per
/// player, which the entitlement and the Info.plist purpose string
/// permit. A player that is not running is never addressed: sending
/// script to a quit app would launch it.
enum Players {
    static let known = ["com.apple.Music", "com.spotify.client"]

    static func playing() -> [String] {
        known.filter { isPlaying($0) }
    }

    static func isPlaying(_ id: String) -> Bool {
        running(id) && ask("player state as string", of: id) == "playing"
    }

    static func pause(_ id: String) {
        guard running(id) else { return }
        _ = ask("pause", of: id)
    }

    static func play(_ id: String) {
        guard running(id) else { return }
        _ = ask("play", of: id)
    }

    private static func running(_ id: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
    }

    private static func ask(_ body: String, of id: String) -> String? {
        let source = "tell application id \"\(id)\" to \(body)"
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            Log.info("draft", ["playback": "script error", "player": id,
                               "error": "\(error[NSAppleScript.errorMessage] ?? error)"])
            return nil
        }
        return result?.stringValue
    }
}

/// The CoreAudio side, kept apart from the decisions.
enum SystemAudio {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
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
}
