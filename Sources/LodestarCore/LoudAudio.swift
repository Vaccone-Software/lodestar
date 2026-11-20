/// Reduce loud audio: headphone volume held under the level that is safe to
/// listen at all day, the way iPhone limits headphones it did not make, from
/// the volume setting alone. Nothing is measured: measuring what plays costs
/// 4 to 7 percent of a core for as long as it runs (`probe listening tap`,
/// 2026-11-18), so the ceiling assumes the worst instead.
///
/// The level at the ear is the headphones' level at full volume, plus the
/// content's level, plus the volume setting. With the loudest sustained
/// music (about −8 dB under full scale) on headphones that reach F dBA at
/// full volume, the setting that keeps the ear at a level is that level − F
/// + 8. Bluetooth headphones drive themselves and are taken to reach 110.
/// Wired ones are driven by the Mac: its jack gives up to 1.25 V into
/// ordinary headphones (Apple, "Use high-impedance headphones with your
/// Mac"), which typical earbuds and headphones, at 100 to 120 dB a volt,
/// turn into 102 to 122 dB, so they are taken to reach 120. There
/// are three levels, named for how much they reduce, never by a figure: the
/// figure is a worst case that real headphones and loudness-matched
/// streaming land 5 to 15 dB under, so printing it would claim a precision
/// nothing measured. Standard keeps the ear at 80 dBA (ITU-T H.870's adult
/// level, 40 hours a week), Strong at 75 (its level for children and
/// sensitive ears), Light at 85 (eight hours a day by the workplace rule).
/// Louder headphones than assumed are the error that remains, the same one
/// iPhone accepts.
///
/// This is the rules. The app's `LoudAudioGuard` holds them: it swallows
/// volume-up at the keys (putting the volume back after a key press lets the
/// next press climb from the system's own count) and puts back any other raise,
/// the slider's, an app's or the headset's own buttons, which the keys then
/// step from without drifting (`probe listening drift`).
public enum LoudAudio {
    /// How much loud audio is reduced: off, or one of three levels, each
    /// 5 dB from the next on every pair of headphones.
    public enum Level: String, CaseIterable, Equatable, Sendable {
        case off, light, standard, strong

        /// The level at the ear the ceiling keeps under, in dBA, if any.
        public var limitDBA: Double? {
            switch self {
            case .off: nil
            case .light: 85
            case .standard: 80
            case .strong: 75
            }
        }

        /// The ceiling, in dB on the curve the volume is held through, on
        /// headphones that reach `fullScaleDBA` at full volume: −17, −22 or
        /// −27 on Bluetooth, 10 dB under on wired. On a call it is
        /// `callAllowance` higher, since a call plays speech, not music.
        public func ceilingDecibels(fullScaleDBA: Double, call: Bool = false) -> Float? {
            let content = call ? loudestCallContentDBFS : loudestContentDBFS
            return limitDBA.map { Float($0 - fullScaleDBA - content) }
        }

        /// The level's name, as the menu says it.
        public var name: String {
            switch self {
            case .off: "Off"
            case .light: "Light"
            case .standard: "Standard"
            case .strong: "Strong"
            }
        }
    }

    /// What Bluetooth headphones are assumed to reach at full volume, in dBA.
    public static let bluetoothFullScaleDBA = 110.0
    /// What wired headphones, driven by the Mac, are assumed to reach.
    public static let wiredFullScaleDBA = 120.0
    /// Bluetooth and Bluetooth LE, the transports whose headphones drive
    /// themselves ('blue', 'blea').
    public static let bluetoothTransports: Set<UInt32> = [0x626C_7565, 0x626C_6561]

    /// Whether an output is connected by Bluetooth or Bluetooth LE.
    public static func isBluetooth(transport: UInt32?) -> Bool {
        transport.map(bluetoothTransports.contains) == true
    }

    /// What an output's headphones are assumed to reach at full volume, by
    /// how they are connected: anything not Bluetooth is driven by the Mac.
    public static func fullScaleDBA(transport: UInt32?) -> Double {
        isBluetooth(transport: transport) ? bluetoothFullScaleDBA : wiredFullScaleDBA
    }

    /// The curve every Bluetooth headphone is held through, whatever it
    /// reports: linear in dB from −40 at silent to 0 at full, as measured on
    /// a Bose headset (2026-11-18). Bluetooth volume is the headphones' own,
    /// sent to them as a step, and the curve macOS reports for it is a guess
    /// that differs by maker and by mode: AirPods Pro say −100…0 and the Bose
    /// −40…0, so Strong let AirPods reach 73 percent of the slider and the
    /// Bose 33; in a call the same headsets say −52…0 and −32…0, so the
    /// ceiling moved every time a call began or ended. One curve keeps each
    /// level at the same place on the slider on every headset, in every mode.
    public static let bluetoothCurve: (bottom: Float, top: Float) = (-40, 0)

    /// The dB of a Bluetooth headphone's volume, on `bluetoothCurve`.
    public static func bluetoothDecibels(_ scalar: Float) -> Float {
        bluetoothCurve.bottom + (bluetoothCurve.top - bluetoothCurve.bottom) * scalar
    }

    /// What the note says the first time a hold stops the volume.
    public static let noticeSentence = "Your volume is held to protect your hearing"
    public static func noticeDetail(_ level: Level) -> String {
        "Reduce loud audio is set to \(level.name) in Settings"
    }
    /// The loudest sustained content, in dB under full scale.
    public static let loudestContentDBFS = -8.0
    /// The loudest sustained content on a call. Zoom, FaceTime and the
    /// browsers' calls level every voice to a target (the voice-call
    /// pipelines' automatic gain), and speech peaks far over its average, so
    /// a call plays well under the loudest music. Held at the music level, a
    /// quiet voice on a narrowband headset could not be turned up enough to
    /// follow: on 2026-11-20 Strong stopped the keys twice in a Zoom standup
    /// and was turned off 40 s in. An estimate until a real call is measured
    /// (`probe listening tap` during one).
    public static let loudestCallContentDBFS = -20.0
    /// How much higher the ceiling sits on a call, in dB.
    public static var callAllowance: Double { loudestContentDBFS - loudestCallContentDBFS }

    /// Whether an app holding a microphone is on a call: a meeting or chat
    /// app, a browser (a page with the microphone is a call), or the
    /// system's own calls (FaceTime's and Continuity's run in
    /// avconferenced). Anything else with a microphone is not: Lodestar's
    /// own dictation, Siri, a notch app that holds it all day (Alcove,
    /// measured 2026-11-20). Audio comes from helpers as often as from the
    /// app: Chromium browsers play and record from `<app>.helper`, Safari
    /// from WebKit's GPU process, Zoom from `us.zoom.caphost`.
    public static func isCall(bundleID: String) -> Bool {
        var id = bundleID.lowercased()
        if callBundles.contains(id) || id.hasPrefix("us.zoom.") { return true }
        if id.hasSuffix(".helper") { id.removeLast(".helper".count) }
        return ["meeting", "chat", "browser"].contains(AppCategory.of(bundleID: id, declared: nil).kind)
    }

    /// Calls that run outside the app the person sees.
    static let callBundles: Set<String> = ["com.apple.webkit.gpu", "com.apple.avconferenced"]

    /// How far over the ceiling a volume may read before it is put back: the
    /// device rounds what it is given, and a raise is never this small.
    public static let tolerance: Float = 0.0005

    /// The output stream's terminal type for headphones ('hdph'): Bluetooth
    /// headphones and headsets report it, with no Bluetooth permission.
    public static let headphonesTerminal: UInt32 = 0x6864_7068
    /// The built-in output's data source with headphones in the jack ('hdpn').
    public static let headphonesDataSource: UInt32 = 0x6864_706E

    /// Whether an output is headphones. Only what says so is limited: a
    /// speaker, a display, anything unknown is left alone.
    public static func isHeadphones(terminal: UInt32?, dataSource: UInt32?) -> Bool {
        terminal == headphonesTerminal || dataSource == headphonesDataSource
    }

    /// How far a volume curve must fall from full to silent before it is
    /// believed: every real one measured falls 32 dB or more (a headset in a
    /// call −32…0, a Bluetooth headset −40…0, the built-in output −63.5…0,
    /// AirPods Pro −100…0).
    public static let minimumCurveSpan: Float = 20
    /// The points a curve is read at to see that it rises: a seventeenth each.
    static let curveSamples = 16

    /// The largest volume, in the device's own 0…1 scale, whose dB is at or
    /// under `ceilingDecibels`, found through a curve (`decibels`
    /// answers a scalar's dB, nil if the device has no curve). A device that
    /// never gets as loud as the ceiling is held at 1.
    ///
    /// Nil when no ceiling can be placed, and then nothing is held: a curve
    /// that is missing, does not rise from silent to full, spans under
    /// `minimumCurveSpan`, or never gets as quiet as the ceiling. That last is
    /// what a headset answers in the instant it changes mode or connects (0 dB
    /// at every volume, 2026-11-19): read as a curve, it held the volume at
    /// silence and nothing read it again, so the keys and the slider did
    /// nothing until the level was chosen again. The guard reads again when
    /// the device settles.
    public static func ceilingScalar(_ ceilingDecibels: Float, decibels: (Float) -> Float?) -> Float? {
        guard let curve = plausibleCurve(decibels) else { return nil }
        let (bottom, top) = curve
        if top <= ceilingDecibels { return 1 }
        guard bottom <= ceilingDecibels else { return nil }
        var low: Float = 0
        var high: Float = 1
        for _ in 0..<32 {
            let middle = (low + high) / 2
            guard let db = decibels(middle) else { return nil }
            if db <= ceilingDecibels { low = middle } else { high = middle }
        }
        return low
    }

    /// A curve's silent and full dB, if it reads at every point, never falls
    /// as the volume rises, and spans at least `minimumCurveSpan`.
    public static func plausibleCurve(_ decibels: (Float) -> Float?) -> (bottom: Float, top: Float)? {
        var points: [Float] = []
        for index in 0...curveSamples {
            guard let db = decibels(Float(index) / Float(curveSamples)), db.isFinite || db == -.infinity else { return nil }
            points.append(db)
        }
        guard let bottom = points.first, let top = points.last, top.isFinite,
              zip(points, points.dropFirst()).allSatisfy({ $0 <= $1 + 0.01 }),
              top - bottom >= minimumCurveSpan else { return nil }
        return (bottom, top)
    }

    /// Whether a volume is over the ceiling, and is to be put back.
    public static func isOver(_ volume: Float, ceiling: Float) -> Bool {
        volume > ceiling + tolerance
    }

    /// One press of a volume key: a sixteenth, or a quarter of that with
    /// Option and Shift held.
    public static func keyStep(fine: Bool) -> Float { fine ? 1.0 / 64 : 1.0 / 16 }

    /// Whether volume-up is swallowed: when the step it takes would cross
    /// the ceiling. The system's count of the keys stays true, and the guard
    /// sets the volume to the ceiling itself, so the keys reach the same most
    /// as the slider does, even where the ceiling is less than a step from
    /// silence.
    public static func swallowsVolumeUp(at volume: Float, step: Float, ceiling: Float) -> Bool {
        volume + step > ceiling + tolerance
    }

    /// NX_KEYTYPE_SOUND_UP, in a system-defined event's data1.
    public static let soundUpKey = 0
    /// The subtype of a system-defined event that carries a media key.
    public static let mediaKeySubtype = 8

    /// Whether a media key's data1 is its press (key state 0xA), not its
    /// release (0xB).
    public static func isPress(data1: Int) -> Bool {
        (data1 & 0xFF00) >> 8 == 0xA
    }

    /// Whether a system-defined event is the volume-up key, pressed or let go.
    public static func isVolumeUp(subtype: Int, data1: Int) -> Bool {
        subtype == mediaKeySubtype && (data1 & 0xFFFF_0000) >> 16 == soundUpKey
    }
}
