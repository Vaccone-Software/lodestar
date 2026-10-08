import Foundation

/// Which keyboard sent a press, exactly: the press the tap saw matched, by
/// its own timestamp, to the HID report that produced it.
///
/// The roster's attribution (`DeviceRoster.attribute`) goes by the event's
/// keyboard type and the lid, and writes nothing when two keyboards could
/// have sent a press. A keyboard change moves hold times more than most
/// effects worth studying, so with `health.exact-keyboards` on (and Input
/// Monitoring granted) the HID manager is listened to as well, and each
/// press is charged to the one device whose report matches it.
///
/// **The usage never leaves this type.** It is compared in memory to make
/// the match and then dropped: it is not stored, not logged, not returned.
/// A report is consumed by the press it matches, so it cannot be matched
/// twice, and reports older than `retention` are forgotten. The record
/// keeps no key identity, and this does not change that.
///
/// A match must be one device, from a physical keyboard, inside the
/// tolerance. Anything else is not an exact attribution, and the caller
/// falls back to the roster's (which writes zero when it is unsure too):
/// - no report inside the tolerance — the tap saw an event no keyboard
///   reported then (posted by another process, or rewritten and re-posted
///   by a remapper, which stamps it anew);
/// - reports from two devices — the same key on two boards inside 2 ms;
/// - a report from a virtual device — a remapper that seizes the physical
///   keyboard and re-emits from a virtual one (Karabiner's DriverKit
///   keyboard is one): the physical board's reports never reach a
///   listener that does not seize it, and the virtual one is not a board.
public struct KeyReportMatcher {
    /// How far apart a report's stamp and the tap event's may be. Both are
    /// the HID event's own time, so they should agree to the microsecond;
    /// two milliseconds is the margin, and it sits under every report
    /// interval a keyboard uses (8 ms on the built-in, at least 7.5 ms on
    /// Bluetooth), so one keystroke cannot match two reports from a board.
    public static let tolerance: TimeInterval = 0.002
    /// How long a report waits for its press. A press is handed over at
    /// its release, and a modifier can be held through a minute of chord.
    public static let retention: TimeInterval = 120
    /// Reports kept per usage, beyond which the oldest go.
    static let perUsage = 64

    public enum Match: Equatable {
        case device(String)
        /// The keycode has no keyboard usage this table knows.
        case unmapped
        /// No report inside the tolerance.
        case missing
        /// Reports from more than one device.
        case ambiguous
        /// The report came from a virtual device: a remapper's.
        case virtual

        var name: String {
            switch self {
            case .device: return "exact"
            case .unmapped: return "unmapped"
            case .missing: return "missing"
            case .ambiguous: return "ambiguous"
            case .virtual: return "virtual"
            }
        }
    }

    private struct Report {
        let device: String
        let virtual: Bool
        let stamp: Double
    }

    private var reports: [UInt32: [Report]] = [:]
    /// How the matches went, by outcome: counts only, for a log line that
    /// says whether exact attribution is doing anything on this machine.
    public private(set) var outcomes: [String: Int] = [:]

    public init() {}

    /// A key went down on `device` (its roster id) at `stamp`, monotonic
    /// nanoseconds. Usage page 7 only; other usages are ignored.
    public mutating func report(usage: UInt32, device: String, virtual: Bool, stamp: Double) {
        guard (0x04...0xE7).contains(usage) else { return }
        var list = reports[usage] ?? []
        list.removeAll { stamp - $0.stamp > Self.retention * 1e9 }
        list.append(Report(device: device, virtual: virtual, stamp: stamp))
        if list.count > Self.perUsage { list.removeFirst(list.count - Self.perUsage) }
        reports[usage] = list
    }

    /// The device behind the press whose keydown had `keycode` and `stamp`.
    public mutating func match(keycode: Int64, stamp: Double?) -> Match {
        let result = matched(keycode: keycode, stamp: stamp)
        outcomes[result.name, default: 0] += 1
        return result
    }

    public mutating func resetOutcomes() { outcomes = [:] }

    private mutating func matched(keycode: Int64, stamp: Double?) -> Match {
        guard let usage = Self.usage(forKeycode: keycode) else { return .unmapped }
        guard let stamp, let list = reports[usage] else { return .missing }
        let near = list.indices.filter { abs(list[$0].stamp - stamp) <= Self.tolerance * 1e9 }
        guard !near.isEmpty else { return .missing }
        if near.contains(where: { list[$0].virtual }) { return .virtual }
        let devices = Set(near.map { list[$0].device })
        guard devices.count == 1, let device = devices.first else { return .ambiguous }
        // Consumed: one report, one press.
        let closest = near.min { abs(list[$0].stamp - stamp) < abs(list[$1].stamp - stamp) }!
        reports[usage]?.remove(at: closest)
        return .device(device)
    }

    /// A Mac virtual keycode's USB HID keyboard usage (page 7), for the
    /// positions the tap names. A keycode not here matches nothing.
    static func usage(forKeycode keycode: Int64) -> UInt32? { usages[keycode] }

    private static let usages: [Int64: UInt32] = [
        0: 0x04, 11: 0x05, 8: 0x06, 2: 0x07, 14: 0x08, 3: 0x09, 5: 0x0A, 4: 0x0B, 34: 0x0C, 38: 0x0D,
        40: 0x0E, 37: 0x0F, 46: 0x10, 45: 0x11, 31: 0x12, 35: 0x13, 12: 0x14, 15: 0x15, 1: 0x16, 17: 0x17,
        32: 0x18, 9: 0x19, 13: 0x1A, 7: 0x1B, 16: 0x1C, 6: 0x1D,
        18: 0x1E, 19: 0x1F, 20: 0x20, 21: 0x21, 23: 0x22, 22: 0x23, 26: 0x24, 28: 0x25, 25: 0x26, 29: 0x27,
        36: 0x28, 53: 0x29, 51: 0x2A, 48: 0x2B, 49: 0x2C, 27: 0x2D, 24: 0x2E, 33: 0x2F, 30: 0x30, 42: 0x31,
        41: 0x33, 39: 0x34, 50: 0x35, 43: 0x36, 47: 0x37, 44: 0x38, 57: 0x39,
        122: 0x3A, 120: 0x3B, 99: 0x3C, 118: 0x3D, 96: 0x3E, 97: 0x3F, 98: 0x40, 100: 0x41, 101: 0x42,
        109: 0x43, 103: 0x44, 111: 0x45,
        115: 0x4A, 116: 0x4B, 117: 0x4C, 119: 0x4D, 121: 0x4E, 124: 0x4F, 123: 0x50, 125: 0x51, 126: 0x52,
        76: 0x58,
        59: 0xE0, 56: 0xE1, 58: 0xE2, 55: 0xE3, 62: 0xE4, 60: 0xE5, 61: 0xE6, 54: 0xE7,
    ]
}
