import Foundation

/// The instrument's own state, written down whenever it changes: which
/// build is writing, which record formats, what the input settings were,
/// what the screens were, which layout the keys were read through. A
/// collection change with no marker in the data has to be reconstructed
/// from a log afterwards; this is the marker. One `era` event at boot
/// when anything here differs from the last one written, and the
/// monthly rollup keeps the set of builds it saw.
public struct EraInfo: Codable, Equatable {
    public var appVersion: String
    public var keySchema: Int
    public var pointerSchema: Int
    /// The keyboard input source, by its system id — an OS layout change
    /// is visible; a firmware remap on the keyboard itself is not, and
    /// cannot be, so the hand map is only ever as positional as the
    /// board is honest.
    public var layout: String?
    public var keyboards: [String]
    public var pointers: [String]
    public var displays: [DisplayInfo]
    public var settings: InputSettings
    public var lid: Bool?
    /// The finger map's fingerprint — which keys the person has declared
    /// to sit off the convention, per keyboard. A change to it changes
    /// what the stored finger column means from here on. Nil in an era
    /// written before the map existed, and empty when nothing is declared.
    public var fingerMap: String?
    /// How often each attached keyboard reports, by its roster id: the
    /// grain every stamp from it, and so every hold, is quantised to (the
    /// built-in's 8 ms is the comb its holds were found to sit on). What
    /// the device says, or `unknown`; never a guess. Nil in an era written
    /// before it was read. Not part of the fingerprint, since devices come
    /// and go: the tracker writes an era when an attached keyboard's
    /// interval is not yet written down (`EraTracker`).
    public var reportIntervals: [String: ReportInterval]?
    /// The keyboard column was written by matching each press to its
    /// keyboard's own report (`health.exact-keyboards`, Input Monitoring
    /// granted), falling back to the roster's attribution only when no
    /// single physical keyboard matched. Nil or false: the roster's
    /// attribution alone. It changes what the column means, so it is part
    /// of the fingerprint when on.
    public var exactKeyboards: Bool?
    /// "boot", "changed", or "keyboard" when only a keyboard's interval is
    /// new.
    public var reason: String

    public init(appVersion: String, keySchema: Int, pointerSchema: Int, layout: String? = nil,
                keyboards: [String] = [], pointers: [String] = [], displays: [DisplayInfo] = [],
                settings: InputSettings = InputSettings(), lid: Bool? = nil,
                fingerMap: String? = nil, reportIntervals: [String: ReportInterval]? = nil,
                exactKeyboards: Bool? = nil, reason: String = "boot") {
        self.appVersion = appVersion
        self.keySchema = keySchema
        self.pointerSchema = pointerSchema
        self.layout = layout
        self.keyboards = keyboards
        self.pointers = pointers
        self.displays = displays
        self.settings = settings
        self.lid = lid
        self.fingerMap = fingerMap
        self.reportIntervals = reportIntervals
        self.exactKeyboards = exactKeyboards
        self.reason = reason
    }

    /// What counts as the instrument changing. Devices come and go with
    /// a Bluetooth radio and are carried by every pulse and window
    /// anyway, so they are not part of it; the build, the formats, the
    /// settings, the screens, the layout — and the finger map, because a
    /// relabeled key is a step in what the finger column means. An empty
    /// map adds nothing, so an era written before the map existed still
    /// matches an install that has declared none.
    public var fingerprint: String {
        let screens = displays.map { "\($0.width)x\($0.height)@\($0.scale)/\($0.mmWidth)x\($0.mmHeight)" }
        var parts = [appVersion, "\(keySchema)", "\(pointerSchema)", layout ?? "",
                     screens.joined(separator: "|"), settings.fingerprint]
        if let fingerMap, !fingerMap.isEmpty { parts.append("fingers=" + fingerMap) }
        if exactKeyboards == true { parts.append("exact-keyboards") }
        return parts.joined(separator: ";")
    }
}

/// How often a device sends a report, as the device states it in the HID
/// registry (`ReportInterval`, microseconds), or `unknown` when it states
/// none or states zero. Written as a number or as "unknown".
public enum ReportInterval: Codable, Equatable, Sendable {
    case microseconds(Int)
    case unknown

    /// From the registry's value: nothing, or nothing positive, is unknown.
    public init(registry value: Int?) {
        if let value, value > 0 { self = .microseconds(value) } else { self = .unknown }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .microseconds(value)
        } else {
            let word = try container.decode(String.self)
            guard word == "unknown" else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an interval: \(word)")
            }
            self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .microseconds(let value): try container.encode(value)
        case .unknown: try container.encode("unknown")
        }
    }
}

/// One screen: what a pixel is, so a reach measured in points can be
/// read in millimetres on any display it ran on.
public struct DisplayInfo: Codable, Equatable {
    public var width: Int
    public var height: Int
    public var scale: Double
    public var mmWidth: Double
    public var mmHeight: Double
    public var main: Bool

    public init(width: Int, height: Int, scale: Double, mmWidth: Double, mmHeight: Double, main: Bool) {
        self.width = width
        self.height = height
        self.scale = scale
        self.mmWidth = mmWidth
        self.mmHeight = mmHeight
        self.main = main
    }
}

/// The system settings that change the measurement the way a keyboard
/// swap does: the repeat delay and rate define what a repeated press is,
/// the tracking speeds scale every delta into points, and the rest
/// change which act a click or a scroll was.
public struct InputSettings: Codable, Equatable {
    public var keyRepeat: Double?
    public var initialKeyRepeat: Double?
    public var mouseScaling: Double?
    public var trackpadScaling: Double?
    public var naturalScroll: Bool?
    public var tapToClick: Bool?
    public var forceClick: Bool?

    public init(keyRepeat: Double? = nil, initialKeyRepeat: Double? = nil, mouseScaling: Double? = nil,
                trackpadScaling: Double? = nil, naturalScroll: Bool? = nil, tapToClick: Bool? = nil,
                forceClick: Bool? = nil) {
        self.keyRepeat = keyRepeat
        self.initialKeyRepeat = initialKeyRepeat
        self.mouseScaling = mouseScaling
        self.trackpadScaling = trackpadScaling
        self.naturalScroll = naturalScroll
        self.tapToClick = tapToClick
        self.forceClick = forceClick
    }

    var fingerprint: String {
        func s(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "-" }
        func b(_ v: Bool?) -> String { v.map { $0 ? "1" : "0" } ?? "-" }
        return [s(keyRepeat), s(initialKeyRepeat), s(mouseScaling), s(trackpadScaling),
                b(naturalScroll), b(tapToClick), b(forceClick)].joined(separator: ",")
    }
}
