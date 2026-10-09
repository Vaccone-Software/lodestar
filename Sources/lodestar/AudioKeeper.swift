import CoreAudio
import Foundation

/// What `AudioInput` knows about silence, kept apart from the engine.
///
/// The engine's keeper decides four things the engine itself cannot: when
/// a running engine is deaf, when a device is charged for a window of
/// silence, when the charges add up to a write-off and when they are
/// forgotten, and how many rebuilds a session may spend. Those decisions
/// were fields and branches inside `AudioInput`, beside CoreAudio and an
/// `AVAudioEngine`, so the rules could only be read, never run. Here they
/// take the time and the machine's facts as arguments; `AudioInput` asks
/// at each event and does what the answer says, on its own queue, so the
/// behaviour is the same and the rules can be driven by a clock.
struct AudioKeeper {
    /// The engine ran and heard nothing, so the next start builds a new
    /// one rather than restarting this.
    private(set) var deaf = false
    /// When the engine last started and reported running; nil while it
    /// is not. What a stop measures the run against before believing the
    /// device heard nothing.
    private(set) var runningSince: Date?
    /// Rebuilds this session has spent: a radio that keeps flipping must
    /// not rebuild forever.
    private(set) var rebuilds = 0
    /// How many whole windows each device has run through in silence.
    ///
    /// A system default that delivers nothing will deliver nothing on
    /// the next draft too, and retrying it every time is how a dictation
    /// feature spends a whole evening hearing silence: a monitor or a
    /// dock that presents an input with no microphone behind it is the
    /// ordinary way to end up here, and it can be the default without
    /// anyone having chosen it. Once is an engine that may have been
    /// born deaf and is rebuilt; twice is the device, and the default is
    /// read elsewhere. Never a device a hand named on the register line:
    /// `choose` reads that one as named, whatever this says about it.
    private(set) var silentWindows: [AudioDeviceID: Int] = [:]
    /// The inputs the machine had when the last window was charged. The
    /// write-off lasts only while that set stands: a device arriving or
    /// leaving clears it, so a headset that was slow once is not held
    /// against it after it reconnects, and a pin made under one set of
    /// devices never outlives them. It used to last the process, and
    /// one evening that pinned every session to a microphone the lid
    /// had switched off, whatever the register line was set to.
    private(set) var silentRoster: Set<AudioDeviceID> = []

    /// A device charged for a window of silence: how many it has run, and
    /// whether that writes it off.
    struct Charge: Equatable {
        let device: AudioDeviceID
        let windows: Int
        let writtenOff: Bool
    }

    // MARK: - A session

    /// A new session: its rebuilds start from none.
    mutating func sessionBegan() { rebuilds = 0 }

    /// The engine started cleanly. It is believed again until a window
    /// says otherwise.
    mutating func started(running: Bool, at now: Date) {
        deaf = false
        runningSince = running ? now : nil
    }

    /// The same engine started again (a restart in place, a resume): the
    /// run is measured from here, and a deaf verdict stands.
    mutating func ran(running: Bool, at now: Date) {
        runningSince = running ? now : nil
    }

    /// Whether a rebuild may be spent, and spends it.
    mutating func mayRebuild() -> Bool {
        guard rebuilds < AudioInput.rebuildCap else { return false }
        rebuilds += 1
        return true
    }

    /// What the silence watch decides when its window closes.
    enum Verdict: Equatable {
        /// Heard, or no longer about the engine in flight.
        case keep
        /// Deaf: rebuilt on the spot, the device that ran it charged
        /// when it is known.
        case rebuild(Charge?)
    }

    /// The silence watch's window closed. `watching` is whether the watch
    /// is still about the engine in flight: the same engine, a session
    /// open, the engine running.
    mutating func windowClosed(watching: Bool, signalled: Bool, device: AudioDeviceID?,
                               roster: () -> Set<AudioDeviceID>) -> Verdict {
        guard watching, !signalled else { return .keep }
        deaf = true
        // The window is judged here, once. The rebuild that follows stops
        // this engine first, and that stop must not judge the same window
        // again: a device charged twice for one silence was written off
        // after a single window, when twice is what calls it the device.
        runningSince = nil
        return .rebuild(device.map { charge($0, roster: roster()) })
    }

    /// The session stopped. A session that ran a whole window and heard
    /// no signal indicts the engine and the device, so the next one does
    /// not inherit either; a session stopped sooner, which is what a
    /// timed-out start's retry is, says nothing. Answers the charge, if
    /// one was made.
    mutating func stopped(at now: Date, inFlight: Bool, hasEngine: Bool, signalled: () -> Bool,
                          window: () -> TimeInterval, device: AudioDeviceID?,
                          roster: () -> Set<AudioDeviceID>) -> Charge? {
        let ran = runningSince.map { now.timeIntervalSince($0) }
        runningSince = nil
        guard inFlight, hasEngine,
              AudioInput.indicts(ranFor: ran, signalled: signalled(), window: window()) else { return nil }
        deaf = true
        return device.map { charge($0, roster: roster()) }
    }

    // MARK: - The ledger

    /// One whole window of silence, against the device that ran it.
    mutating func charge(_ device: AudioDeviceID, roster: Set<AudioDeviceID>) -> Charge {
        silentWindows[device, default: 0] += 1
        silentRoster = roster
        let windows = silentWindows[device] ?? 0
        return Charge(device: device, windows: windows, writtenOff: windows >= AudioInput.windowsToWriteOff)
    }

    /// The devices written off for this roster. A roster that is not the
    /// one the charges were made under forgets them all first; answers
    /// how many were forgotten, when any were.
    mutating func writtenOff(roster: Set<AudioDeviceID>) -> (devices: Set<AudioDeviceID>, forgotten: Int?) {
        var forgotten: Int?
        if !silentWindows.isEmpty, !AudioInput.writeOffHolds(roster: roster, chargedUnder: silentRoster) {
            forgotten = silentWindows.count
            silentWindows = [:]
        }
        let devices = Set(silentWindows.filter { $0.value >= AudioInput.windowsToWriteOff }.map(\.key))
        return (devices, forgotten)
    }

    /// The machine as a start sees it.
    struct Machine {
        var devices: [AudioDeviceID]
        var systemDefault: AudioDeviceID?
        var builtIn: AudioDeviceID?
        var lidClosed: Bool
        var isBluetooth: (AudioDeviceID) -> Bool
    }

    /// Which device a start reads: the write-offs for this machine's
    /// roster (forgetting them when it changed), the first headset not
    /// written off, and `AudioInput.choose`.
    mutating func choose(wanted: AudioDeviceID?, on machine: Machine)
        -> (choice: AudioInput.Choice, forgotten: Int?) {
        let (writtenOff, forgotten) = self.writtenOff(roster: Set(machine.devices))
        let headset = machine.devices.first { !writtenOff.contains($0) && machine.isBluetooth($0) }
        let choice = AudioInput.choose(wanted: wanted, systemDefault: machine.systemDefault,
                                       writtenOff: writtenOff, builtIn: machine.builtIn,
                                       lidClosed: machine.lidClosed, headset: headset)
        return (choice, forgotten)
    }
}
