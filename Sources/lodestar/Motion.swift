import AppKit

/// design/05-motion.md: Lodestar answers at once. Nothing it does often
/// moves, nothing fades in to soften its own arrival, and motion is kept
/// for the two things that report a signal: a level changing now (the
/// draft's voice meter) and a rare change of state (a switch's knob).
///
/// This is the one place a time or a curve is named. A surface that
/// moves reads it here; every other change is in its end state on the
/// next frame. Where something moves, its end state is set first and the
/// motion is a picture of getting there (rule 4), so dropping it leaves
/// nothing wrong. Reduce Motion stops both (rule 5).
enum Motion {
    /// The one curve, decelerating, so a thing settles the way an object
    /// set down does. Nothing springs, bounces or overshoots.
    static let curvePoints: [Float] = [0.25, 0.1, 0.25, 1]
    static var curve: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: curvePoints[0], curvePoints[1], curvePoints[2], curvePoints[3])
    }

    /// How long a falling voice level takes to come down. A rising one
    /// arrives on the next frame: the voice leads, the light follows.
    static let meterFall: TimeInterval = 0.15
    /// How long the switch's knob takes to cross. The track's colour
    /// changes at once.
    static let knobSlide: TimeInterval = 0.12
    /// No motion runs longer than this, whatever it carries.
    static let longest: TimeInterval = 0.15

    /// Nothing moves under Reduce Motion, the two allowed motions included.
    static var reduced: Bool { Accessibility.reduceMotion() }

    /// What is allowed to move, for the contract's table and the motion
    /// sheet: read from the constants above, not typed in again.
    struct Allowed {
        let what: String
        let why: String
        let how: String
        let seconds: TimeInterval
        let underReduceMotion: String
    }

    static let allowed: [Allowed] = [
        Allowed(what: "the draft's voice meter", why: "it is a level that is changing now",
                how: "follows the voice; falls back when it drops", seconds: meterFall,
                underReduceMotion: "holds still at its full length while it is listening"),
        Allowed(what: "the switch's knob", why: "a rare change of state; the travel says which way",
                how: "slides; the track's colour changes at once", seconds: knobSlide,
                underReduceMotion: "jumps"),
    ]

    /// Everything else, which arrives in its end state on the next frame.
    static let instant: [String] = [
        "opening and closing any surface: a bar, the draft, Keep, the pill, a chip, Settings, a sheet",
        "typing, a selection moving, a key lighting, a row becoming chosen, a press collapsing a side",
        "a list growing or shrinking as results change, a panel resizing to fit them",
        "the draft folding open or shut",
        "the keys sheet growing out of a bar, the draft or the pill, and its keys appearing",
        "a page changing in Settings or the walk",
        "a colour changing, the switch's track included",
    ]

    /// The curve as the contract writes it.
    static var curveText: String {
        "cubic-bezier(" + curvePoints.map { String(format: "%g", Double($0)) }.joined(separator: ", ") + ")"
    }

    static func milliseconds(_ seconds: TimeInterval) -> String { "\(Int((seconds * 1000).rounded())) ms" }
}
