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
/// A browser cannot be asked, but it does say: a tab making sound carries
/// " - Audio playing" in its accessible name, the tab strip's own speaker
/// icon, which never reads a keyboard click. So when no player said
/// "playing" and a tab did, the ⏯ is pressed after all, and because it is
/// still a blind toggle aimed at whoever owns Now Playing, the press is
/// checked. The label outlives the sound by about three seconds (2.71,
/// 3.15, 3.14 s measured on Brave 156, against fifteen for CoreAudio's
/// silent stream), which sets when the check can believe it. A player
/// that now says "playing" took the press, and is paused exactly. A label
/// count that did not fall means the press started a video the hand had
/// paused just before the draft, or reached nothing, and one more press
/// undoes it. Either way nothing is owed.
///
/// Derived, never configured: it acts only when the input about to be
/// read and the current output are the same Bluetooth radio, and it
/// touches only what said it was playing.
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
        /// Off the main thread: how many browser tabs are labelled as
        /// making sound, completing on main. The tab strip is a walk of
        /// some hundreds of Accessibility calls.
        var audibleTabs: (@escaping (Int) -> Void) -> Void
        /// The ⏯, aimed at whoever owns Now Playing.
        var pressPlayPause: () -> Void
        /// The default output's nominal sample rate right now, off the
        /// main thread and completing on main: read at the draft's close,
        /// which is when the radio flips back and the HAL answers late.
        var outputRate: (@escaping (Double) -> Void) -> Void
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
                audibleTabs: { done in
                    queue.async {
                        let audible = BrowserTabs.audibleCount()
                        DispatchQueue.main.async { done(audible) }
                    }
                },
                pressPlayPause: MediaKey.pressPlayPause,
                outputRate: { done in
                    queue.async {
                        let rate = SystemAudio.outputRate() ?? 0
                        DispatchQueue.main.async { done(rate) }
                    }
                },
                watchRate: SystemAudio.watchOutputRate)
        }()
    }

    /// The resume never waits longer than this on a profile that is not
    /// coming back.
    static let resumeBackstop: TimeInterval = 3.0
    /// Hands-free profiles speak at 8 or 16 kHz; a rate at or above
    /// this is a music profile again.
    static let musicRate: Double = 32_000
    /// How long after the ⏯ the tab labels can be believed: past the
    /// three seconds the label outlives the sound, with room for a busy
    /// Mac. A check that came early would read a good press as a failed
    /// one, and its undo would restart the video.
    static let tabCheck: TimeInterval = 4.0

    /// What a resume has to give back.
    private enum Owed {
        /// These players said "playing" and were paused.
        case players([String])
        /// The ⏯ silenced a tab, and this many others stayed audible: only
        /// more than these at the end means a hand pressed play.
        case tab(left: Int)
    }

    private enum State {
        case idle
        /// The route, then the players, then the tabs, are being asked,
        /// off the main thread.
        case asking
        /// The ⏯ went out for this many audible tabs, and is not yet
        /// believed.
        case pressed(audible: Int)
        /// Something was paused and is owed a resume.
        case paused(Owed)
    }

    private let world: World
    private let clock: Clock
    private var state: State = .idle
    private var draftOpen = false
    /// The ⏯ has gone out for this draft. A session restart mid-draft
    /// begins again, and must not press again a toggle that was just
    /// undone.
    private var pressedThisDraft = false
    /// The input the route is being asked about, and a newer one that
    /// arrived while it was. With the Mac's microphone standing in for a
    /// waking headset the draft begins twice — on the Mac's microphone,
    /// then on the headset — and the second came while the first ask was
    /// still out: it was dropped, the first answered "no shared radio",
    /// and the music played on through the telephone band.
    private var askedInput: String?
    private var newerInput: String??
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
            if input != askedInput { newerInput = .some(input) }
        case .pressed:
            // The check settles it, and its end honours this draft.
            break
        case .idle:
            ask(input)
        }
    }

    private func ask(_ input: String?) {
        state = .asking
        askedInput = input
        newerInput = nil
        world.sharedRoute(input) { [weak self] shared in self?.routeAnswered(shared) }
    }

    private func routeAnswered(_ shared: Bool) {
        guard case .asking = state else { return }
        guard shared else {
            // Not this input — but the session may have moved on to one
            // that is, while the question was out.
            if let newer = newerInput, draftOpen {
                ask(newer)
                return
            }
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
        pressedThisDraft = false
        guard case .paused = state else { return }
        beginResume()
    }

    private func pausedPlayers(_ players: [String]) {
        guard case .asking = state else { return }
        guard !players.isEmpty else {
            world.audibleTabs { [weak self] audible in self?.tabsAnswered(audible) }
            return
        }
        state = .paused(.players(players))
        Log.info("draft", ["playback": "paused", "players": players.joined(separator: " ")])
        if !draftOpen { beginResume() }
    }

    private func tabsAnswered(_ audible: Int) {
        guard case .asking = state else { return }
        guard audible > 0, !pressedThisDraft else {
            state = .idle
            Log.info("draft", ["playback": "nothing playing"])
            return
        }
        state = .pressed(audible: audible)
        pressedThisDraft = true
        world.pressPlayPause()
        Log.info("draft", ["playback": "pressed", "audible": "\(audible)"])
        clock.after(Self.tabCheck, DispatchWorkItem { [weak self] in self?.checkPress() })
    }

    /// Whether the press did what it was for. A player is asked first: it
    /// answers exactly, and a stale label could otherwise fall on its own
    /// while the press was starting music.
    private func checkPress() {
        guard case .pressed = state else { return }
        world.pausePlaying { [weak self] strays in
            guard let self, case .pressed = self.state else { return }
            guard strays.isEmpty else {
                self.state = .idle
                Log.info("draft", ["playback": "press reached a player",
                                   "players": strays.joined(separator: " ")])
                return
            }
            self.world.audibleTabs { [weak self] audible in self?.tabsChecked(audible) }
        }
    }

    private func tabsChecked(_ audible: Int) {
        guard case .pressed(let before) = state else { return }
        guard audible < before else {
            state = .idle
            world.pressPlayPause()
            Log.info("draft", ["playback": "press undone", "audible": "\(audible)"])
            return
        }
        state = .paused(.tab(left: audible))
        Log.info("draft", ["playback": "paused", "players": "browser"])
        if !draftOpen { beginResume() }
    }

    /// Send the resume the moment the output is a music profile again,
    /// or at the backstop, whichever comes first: resuming into a
    /// still-flipped profile would put the first seconds of music
    /// through the telephone band.
    private func beginResume() {
        world.outputRate { [weak self] rate in
            // A draft that opened while the rate was being read keeps the
            // quiet; its own end asks again.
            guard let self, case .paused = self.state, !self.draftOpen else { return }
            if rate >= Self.musicRate { self.resume(); return }
            self.cancelResume()
            self.stopWatching = self.world.watchRate { [weak self] rate in
                guard rate >= Self.musicRate else { return }
                self?.resume()
            }
            let work = DispatchWorkItem { [weak self] in self?.resume() }
            self.backstop = work
            self.clock.after(Self.resumeBackstop, work)
        }
    }

    private func resume() {
        guard case .paused(let owed) = state else { return }
        cancelResume()
        switch owed {
        case .players(let players):
            state = .idle
            world.resumePlayers(players) { played in
                Log.info("draft", ["playback": played.isEmpty ? "resumed by hand" : "resumed",
                                   "players": played.joined(separator: " ")])
            }
        case .tab(let left):
            // The debt stands while the tabs are read: a draft that opens
            // meanwhile keeps the quiet, and its own end asks again.
            world.audibleTabs { [weak self] audible in
                guard let self, case .paused(.tab) = self.state, !self.draftOpen else { return }
                self.state = .idle
                let byHand = audible > left
                if !byHand { self.world.pressPlayPause() }
                Log.info("draft", ["playback": byHand ? "resumed by hand" : "resumed", "players": "browser"])
            }
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

/// The browsers whose tab strip says which tabs are making sound. The
/// label is the tab strip's own speaker icon, spoken: measured on Brave
/// 156, and the same Chromium strings in Chrome. It is translated, so a
/// browser in another language reads as silent and is left alone.
enum BrowserTabs {
    static let known = ["com.brave.Browser", "com.google.Chrome"]
    static let audibleLabel = " - Audio playing"
    /// Enough for a few hundred tabs; a walk that finds more has wandered.
    private static let nodeLimit = 3_000

    /// Not always the end of the name: "- Memory usage - 1.0 GB" can follow.
    static func isAudible(_ name: String) -> Bool {
        name.contains(audibleLabel)
    }

    /// A walk of about 630 calls and 330 ms over 84 tabs, so never on the
    /// main thread. It stops at the page: only the strip is wanted.
    static func audibleCount() -> Int {
        known.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .reduce(0) { $0 + audibleCount(in: AXUIElementCreateApplication($1.processIdentifier)) }
    }

    private static func audibleCount(in app: AXUIElement) -> Int {
        var audible = 0
        var nodes = 0
        func walk(_ element: AXUIElement, inStrip: Bool) {
            nodes += 1
            guard nodes < nodeLimit else { return }
            let role = AX.string(element, kAXRoleAttribute)
            if role == "AXWebArea" { return }
            if inStrip, role == kAXRadioButtonRole {
                let names = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { AX.string(element, $0) }
                if names.contains(where: isAudible) { audible += 1 }
                return
            }
            for child in AX.elements(element, kAXChildrenAttribute) ?? [] {
                walk(child, inStrip: inStrip || role == kAXTabGroupRole)
            }
        }
        for window in AX.elements(app, kAXWindowsAttribute) ?? [] { walk(window, inStrip: false) }
        return audible
    }
}

/// The keyboard's ⏯, as the keyboard sends it: a system-defined event
/// carrying the key and its state, down then up.
enum MediaKey {
    private static let playPause = 16 // NX_KEYTYPE_PLAY
    private static let subtype: Int16 = 8 // NX_SUBTYPE_AUX_CONTROL_BUTTONS

    static func pressPlayPause() {
        for state in [0xa, 0xb] { // key down, key up
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                                           timestamp: 0, windowNumber: 0, context: nil, subtype: subtype,
                                           data1: (playPause << 16) | (state << 8), data2: -1)
            SystemEvents.post(event?.cgEvent, tap: .cghidEventTap)
        }
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

    /// The watch's own queue: the device lookup, the listener, and every
    /// read inside it are HAL calls, and the main thread hosts the event
    /// tap. `onChange` still arrives on main.
    private static let listenerQueue = DispatchQueue(label: "com.vaccone.lodestar.playback-rate",
                                                     qos: .utility)

    /// Watch the default output's nominal sample rate — the profile
    /// flip made visible: 44100 falls to 16000 when hands-free takes
    /// the radio, and rises when music gets it back. Returns a cancel.
    static func watchOutputRate(_ onChange: @escaping (Double) -> Void) -> () -> Void {
        final class Watch {
            var device: AudioDeviceID?
            var block: AudioObjectPropertyListenerBlock?
            var cancelled = false
        }
        let watch = Watch() // touched only on listenerQueue
        listenerQueue.async {
            guard !watch.cancelled, let device = defaultOutput() else { return }
            var listenAddress = address(kAudioDevicePropertyNominalSampleRate)
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                let rate = readDouble(device, address(kAudioDevicePropertyNominalSampleRate)) ?? 0
                DispatchQueue.main.async { onChange(rate) }
            }
            AudioObjectAddPropertyListenerBlock(device, &listenAddress, listenerQueue, block)
            watch.device = device
            watch.block = block
        }
        return {
            listenerQueue.async {
                watch.cancelled = true
                guard let device = watch.device, let block = watch.block else { return }
                var removeAddress = address(kAudioDevicePropertyNominalSampleRate)
                AudioObjectRemovePropertyListenerBlock(device, &removeAddress, listenerQueue, block)
                watch.block = nil
            }
        }
    }
}
