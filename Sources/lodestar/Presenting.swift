import AppKit
import CoreAudio
import LodestarCore

/// Are you on a call right now?
///
/// Lodestar's offers — the coach's suggestion, the chip a held link leaves
/// behind — are the only things it says without being asked. They are
/// welcome at a quiet moment and mortifying at one particular moment, which
/// is while your screen is being shared with other people. Chips became
/// draggable and clickable in 0.24.10, which made them more visible than
/// they have ever been, and made this worth answering properly.
///
/// Two senses, because neither is enough alone:
///
/// - **The calendar** knows about the meeting you accepted, exactly, with a
///   start and an end. It knows nothing about the call somebody started in
///   a huddle thirty seconds ago.
/// - **The microphone** knows about any call at all, because being on one
///   means something has the input device open. It cannot tell a meeting
///   from a voice memo.
///
/// Wrong in one direction costs a suggestion arriving late, which is
/// nothing — the coach speaks twice a week and is in no hurry. Wrong in the
/// other direction costs a chip appearing on a screen a room full of people
/// is looking at. The asymmetry is the whole design: when in doubt, hold.
final class Presenting {
    /// How often the senses are asked. Nothing here is urgent — the cost of
    /// noticing a call five seconds late is that an offer already on screen
    /// stands five seconds longer — and both reads are cheap enough that
    /// this interval is chosen for the log's sake rather than the CPU's.
    static let interval: TimeInterval = 5

    /// The calendar half, handed in so this file owns no EventKit.
    var meetingInProgress: () -> Bool = { false }
    /// Fired only on a change, with the new value.
    var onChange: ((Bool) -> Void)?

    /// The cached answer. Read on the navigation path — `coach.suppressed`
    /// is consulted at every boundary, thousands of times a day — so it must
    /// never be a CoreAudio round trip.
    private(set) var isOn = false
    private var timer: Timer?
    /// When the input device was first seen open, so a device that never
    /// closes cannot hold the floor for the rest of the week. See
    /// `Presence.microphoneCeiling` for why that is a real hazard rather
    /// than a hypothetical one.
    private var microphoneSince: Date?
    private var reportedCeiling = false

    func start() {
        sample()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval,
                                     repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The microphone read is a CoreAudio property call, and while a
    /// Bluetooth radio flips profiles the HAL answers it late. The main
    /// thread hosts the event tap, so the read happens here and only the
    /// verdict comes back.
    private static let senses = DispatchQueue(label: "com.vaccone.lodestar.presenting", qos: .utility)

    private func sample() {
        let calendar = meetingInProgress()
        Self.senses.async { [weak self] in
            let open = Microphone.isInUse()
            DispatchQueue.main.async { self?.apply(calendar: calendar, microphoneOpen: open) }
        }
    }

    private func apply(calendar: Bool, microphoneOpen open: Bool) {
        let clock = Date()
        if open {
            microphoneSince = microphoneSince ?? clock
        } else {
            microphoneSince = nil
            reportedCeiling = false
        }
        let microphone = Presence.microphoneHolds(openSince: microphoneSince, now: clock)
        if open, !microphone, !reportedCeiling {
            reportedCeiling = true
            // Said once per stuck device, not once every five seconds. This
            // is the line that explains a coach which has gone quiet for a
            // reason nobody would guess.
            Log.info("presenting", ["microphone": "open past the ceiling — no longer holding"])
        }

        let now = calendar || microphone
        guard now != isOn else { return }
        isOn = now
        // Which sense answered, because "why did the coach go quiet for
        // fifty minutes" has to be answerable from the log alone.
        Log.info("presenting", ["on": now, "calendar": calendar,
                                "microphone": microphone])
        onChange?(now)
    }
}

/// Is the default input device open somewhere on this machine?
///
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` is the system's own
/// answer to "is anything listening", the same fact behind the orange dot
/// in the menu bar. It is public API, needs no permission, and names no
/// process — this asks whether the microphone is on, never who turned it
/// on or what was said.
enum Microphone {
    static func isInUse() -> Bool {
        guard let device = defaultInputDevice() else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
        guard status == noErr else { return false }
        return running != 0
    }

    /// Asked every sample rather than cached: the default input changes
    /// when a headset is plugged in, and a stale device id would answer for
    /// a microphone nobody is using.
    private static func defaultInputDevice() -> AudioObjectID? {
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
}
