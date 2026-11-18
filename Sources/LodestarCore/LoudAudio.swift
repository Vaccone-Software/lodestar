/// Reduce loud audio: headphone volume held under the level that is safe to
/// listen at all day, the way iPhone limits headphones it did not make, from
/// the volume setting alone. Nothing is measured: measuring what plays costs
/// 4 to 7 percent of a core for as long as it runs (`probe listening tap`,
/// 2026-11-18), so the ceiling assumes the worst instead.
///
/// The level at the ear is the headphones' level at full volume, plus the
/// content's level, plus the volume setting. With the loudest sustained
/// music (about −8 dB under full scale) on headphones that reach 110 dBA,
/// the setting that keeps the ear at 75 dBA (the level ITU-T H.870 gives for
/// sensitive ears, 40 hours a week) is 75 − 110 + 8 = −27 dB. Quieter content
/// is quieter still; louder headphones than assumed are the error that
/// remains, the same one iPhone accepts.
///
/// This is the rules. The app's `LoudAudioGuard` holds them: it swallows
/// volume-up at the keys (putting the volume back after a key press lets the
/// next press climb from the system's own count) and puts back any other raise,
/// the slider's, an app's or the headset's own buttons, which the keys then
/// step from without drifting (`probe listening drift`).
public enum LoudAudio {
    /// The level at the ear the ceiling keeps under, in dBA.
    public static let limitDBA = 75.0
    /// What headphones are assumed to reach at full volume, in dBA.
    public static let fullScaleDBA = 110.0
    /// The loudest sustained content, in dB under full scale.
    public static let loudestContentDBFS = -8.0
    /// The volume setting, in the device's own dB, that the ceiling is: −27.
    public static let ceilingDecibels = Float(limitDBA - fullScaleDBA - loudestContentDBFS)

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

    /// The largest volume, in the device's own 0…1 scale, whose dB is at or
    /// under the ceiling, found through the device's own curve (`decibels`
    /// answers a scalar's dB, nil if the device has no curve). Nil when it has
    /// none, and then nothing is held: a ceiling that cannot be placed is no
    /// ceiling. A device that never gets as loud as the ceiling is held at 1.
    public static func ceilingScalar(decibels: (Float) -> Float?) -> Float? {
        guard let top = decibels(1), let bottom = decibels(0) else { return nil }
        if top <= ceilingDecibels { return 1 }
        if bottom > ceilingDecibels { return 0 }
        var low: Float = 0
        var high: Float = 1
        for _ in 0..<32 {
            let middle = (low + high) / 2
            guard let db = decibels(middle) else { return nil }
            if db <= ceilingDecibels { low = middle } else { high = middle }
        }
        return low
    }

    /// Whether a volume is over the ceiling, and is to be put back.
    public static func isOver(_ volume: Float, ceiling: Float) -> Bool {
        volume > ceiling + tolerance
    }

    /// One press of a volume key: a sixteenth, or a quarter of that with
    /// Option and Shift held.
    public static func keyStep(fine: Bool) -> Float { fine ? 1.0 / 64 : 1.0 / 16 }

    /// Whether volume-up is swallowed: when the step it takes would cross
    /// the ceiling. The volume stops at the last step under it, never over,
    /// and the system's count of the keys stays true.
    public static func swallowsVolumeUp(at volume: Float, step: Float, ceiling: Float) -> Bool {
        volume + step > ceiling + tolerance
    }

    /// NX_KEYTYPE_SOUND_UP, in a system-defined event's data1.
    public static let soundUpKey = 0
    /// The subtype of a system-defined event that carries a media key.
    public static let mediaKeySubtype = 8

    /// Whether a system-defined event is the volume-up key, pressed or let go.
    public static func isVolumeUp(subtype: Int, data1: Int) -> Bool {
        subtype == mediaKeySubtype && (data1 & 0xFFFF_0000) >> 16 == soundUpKey
    }
}
