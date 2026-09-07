import CoreGraphics
import Foundation

/// The pointer's acts, timed: what the mouse tap can measure about a
/// click beyond counting it. Pure and value-typed, like `HealthPulse`, so
/// the whole state machine is testable without a tap.
///
/// An *act* is one reach for a target: it opens at the first motion after
/// a rest (or after the previous press) and closes at the press. From it
/// the tracker reads the KLM's own parts, measured instead of assumed —
/// **homing** (last key to first motion, when the hand had been on the
/// keys), **travel** (first motion to last motion), **settle** (last
/// motion to the press), and **press** (button down to up) — plus the
/// **path** the pointer drew and the straight-line **displacement** it
/// needed, whose ratio says how much of the trip was aim. A press held
/// through motion is a **drag**; the first key after a press within a few
/// seconds is the **return** trip to the keys.
///
/// The line: positions live only inside this struct, on the tap's thread,
/// and only to be differenced. What leaves is seconds and points of
/// distance — a scalar has no screen on it. Never a coordinate.
public struct PointerTracker: Equatable {
    /// Motion after this long a pause is a new reach, not the same one.
    public static let restGap: TimeInterval = 0.5
    /// A reach that has been open longer than this is wandering or
    /// reading with the pointer; its travel is capped rather than
    /// believed.
    public static let travelCeiling: TimeInterval = 10.0
    public static let settleCeiling: TimeInterval = 5.0
    public static let homingCeiling: TimeInterval = 5.0
    /// The first key after a press within this long is the hand coming
    /// back to the keys; later is a new thought.
    public static let returnCeiling: TimeInterval = 5.0
    /// A press that carried the pointer at least this far is a drag.
    public static let dragThreshold: Double = 4.0
    public static let pressCeiling: TimeInterval = 10.0

    /// One press, measured.
    public struct Click: Equatable {
        public var travel: Double
        public var settle: Double
        /// Seconds from the last keystroke to the reach's first motion;
        /// nil when the reach did not follow a keystroke.
        public var homing: Double?
        public var path: Double
        public var displacement: Double
        /// The press closed no reach: the pointer had not moved since
        /// the previous press, or its last motion was too long ago to be
        /// this press's aim.
        public var stationary: Bool

        public init(travel: Double = 0, settle: Double = 0, homing: Double? = nil,
                    path: Double = 0, displacement: Double = 0, stationary: Bool = false) {
            self.travel = travel
            self.settle = settle
            self.homing = homing
            self.path = path
            self.displacement = displacement
            self.stationary = stationary
        }
    }

    /// A press released: how long it was held, and the drag it carried.
    public struct Release: Equatable {
        public var press: Double
        public var drag: Drag?
        public init(press: Double, drag: Drag? = nil) {
            self.press = press
            self.drag = drag
        }
    }

    public struct Drag: Equatable {
        public var seconds: Double
        public var path: Double
        public init(seconds: Double, path: Double) {
            self.seconds = seconds
            self.path = path
        }
    }

    private struct Reach: Equatable {
        var start: Date
        var last: Date
        var origin: CGPoint
        var current: CGPoint
        var path = 0.0
    }

    private var reach: Reach?
    private var lastKeyAt: Date?
    private var lastPressAt: Date?
    private var pressed: (at: Date, origin: CGPoint, path: Double, last: CGPoint)?
    private var keyedSincePress = true
    private var movedSincePress = false

    public init() {}

    public static func == (lhs: PointerTracker, rhs: PointerTracker) -> Bool {
        lhs.reach == rhs.reach && lhs.lastKeyAt == rhs.lastKeyAt
            && lhs.lastPressAt == rhs.lastPressAt
            && lhs.keyedSincePress == rhs.keyedSincePress
            && lhs.movedSincePress == rhs.movedSincePress
    }

    /// The pointer moved. Motion under a held button belongs to the
    /// press (a drag), not to a reach.
    public mutating func moved(to point: CGPoint, at now: Date) {
        if var held = pressed {
            held.path += Self.distance(held.last, point)
            held.last = point
            pressed = held
            return
        }
        movedSincePress = true
        if var open = reach, now.timeIntervalSince(open.last) <= Self.restGap {
            open.path += Self.distance(open.current, point)
            open.current = point
            open.last = now
            reach = open
        } else {
            reach = Reach(start: now, last: now, origin: point, current: point)
        }
    }

    /// A keystroke. Returns the return-trip seconds when this is the
    /// first key after a press within the ceiling.
    @discardableResult
    public mutating func keyed(at now: Date) -> Double? {
        lastKeyAt = now
        defer { keyedSincePress = true }
        guard !keyedSincePress, let press = lastPressAt else { return nil }
        let gap = now.timeIntervalSince(press)
        return gap >= 0 && gap <= Self.returnCeiling ? gap : nil
    }

    /// A button went down: the reach ends here and is measured.
    public mutating func down(at point: CGPoint, at now: Date) -> Click {
        defer {
            reach = nil
            lastPressAt = now
            keyedSincePress = false
            movedSincePress = false
            pressed = (at: now, origin: point, path: 0, last: point)
        }
        guard let open = reach, movedSincePress,
              now.timeIntervalSince(open.last) <= Self.settleCeiling else {
            return Click(stationary: true)
        }
        let travel = min(open.last.timeIntervalSince(open.start), Self.travelCeiling)
        let settle = min(max(0, now.timeIntervalSince(open.last)), Self.settleCeiling)
        var homing: Double?
        if let key = lastKeyAt, key <= open.start, open.start.timeIntervalSince(key) <= Self.homingCeiling {
            homing = open.start.timeIntervalSince(key)
        }
        return Click(travel: travel, settle: settle, homing: homing,
                     path: open.path + Self.distance(open.current, point),
                     displacement: Self.distance(open.origin, point))
    }

    /// The button came up. Nil when no press was open (a release the tap
    /// did not see go down).
    public mutating func up(at point: CGPoint, at now: Date) -> Release? {
        guard let held = pressed else { return nil }
        pressed = nil
        let press = min(max(0, now.timeIntervalSince(held.at)), Self.pressCeiling)
        let path = held.path + Self.distance(held.last, point)
        let drag = path >= Self.dragThreshold ? Drag(seconds: press, path: path) : nil
        return Release(press: press, drag: drag)
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(b.x - a.x)
        let dy = Double(b.y - a.y)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// The pointer's acts, folded: sufficient statistics over a set of
/// clicks, the shape the click pulse carries per app and quarter hour
/// and the rollup keeps per app and month. Seconds and points, never a
/// position.
public struct PointerMoments: Codable, Equatable {
    /// Presses that closed a measured reach.
    public var n = 0
    public var travelSum = 0.0
    public var travelSumSq = 0.0
    public var settleSum = 0.0
    /// Reaches that began after a keystroke, and their homing seconds.
    public var homingN = 0
    public var homingSum = 0.0
    public var pathSum = 0.0
    public var displacementSum = 0.0
    /// Presses with no motion since the previous press.
    public var stationary = 0
    public var pressN = 0
    public var pressSum = 0.0
    public var dragN = 0
    public var dragSum = 0.0
    public var dragPathSum = 0.0
    /// First keys after a press within the return ceiling.
    public var returnN = 0
    public var returnSum = 0.0

    public init() {}

    public var isEmpty: Bool { self == PointerMoments() }

    public mutating func add(_ click: PointerTracker.Click) {
        if click.stationary {
            stationary += 1
            return
        }
        n += 1
        travelSum += click.travel
        travelSumSq += click.travel * click.travel
        settleSum += click.settle
        pathSum += click.path
        displacementSum += click.displacement
        if let homing = click.homing {
            homingN += 1
            homingSum += homing
        }
    }

    public mutating func add(_ release: PointerTracker.Release) {
        pressN += 1
        pressSum += release.press
        if let drag = release.drag {
            dragN += 1
            dragSum += drag.seconds
            dragPathSum += drag.path
        }
    }

    public mutating func addReturn(_ seconds: Double) {
        returnN += 1
        returnSum += seconds
    }

    public mutating func merge(_ other: PointerMoments) {
        n += other.n
        travelSum += other.travelSum
        travelSumSq += other.travelSumSq
        settleSum += other.settleSum
        homingN += other.homingN
        homingSum += other.homingSum
        pathSum += other.pathSum
        displacementSum += other.displacementSum
        stationary += other.stationary
        pressN += other.pressN
        pressSum += other.pressSum
        dragN += other.dragN
        dragSum += other.dragSum
        dragPathSum += other.dragPathSum
        returnN += other.returnN
        returnSum += other.returnSum
    }

    // MARK: - Read-time views

    /// Seconds from first motion to the press: travel and settle.
    public var pointMean: Double? { n > 0 ? (travelSum + settleSum) / Double(n) : nil }
    public var travelMean: Double? { n > 0 ? travelSum / Double(n) : nil }
    public var settleMean: Double? { n > 0 ? settleSum / Double(n) : nil }
    public var homingMean: Double? { homingN > 0 ? homingSum / Double(homingN) : nil }
    public var pressMean: Double? { pressN > 0 ? pressSum / Double(pressN) : nil }
    public var returnMean: Double? { returnN > 0 ? returnSum / Double(returnN) : nil }
    public var dragMean: Double? { dragN > 0 ? dragSum / Double(dragN) : nil }
    public var pathMean: Double? { n > 0 ? pathSum / Double(n) : nil }
    /// Straight line over path drawn: 1.0 is a reach with no aim in it.
    public var efficiency: Double? { pathSum > 0 ? displacementSum / pathSum : nil }
}
