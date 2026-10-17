import AppKit
import Carbon
import Foundation
import LodestarCore

/// What the instrument runs inside: the screens, the keyboard layout,
/// and the system's input settings. Each is a fact that changes the
/// measurement without the hand changing — a pixel's size, which key a
/// position is, what a repeated press or a scroll is — so each is
/// written down beside the record and kept when it changes.
enum Environment {
    /// Every screen, in the system's order, with what a point is on it.
    static func displays() -> [DisplayInfo] {
        NSScreen.screens.map { screen in
            let id = displayID(of: screen)
            let size = id.map { CGDisplayScreenSize($0) } ?? .zero
            return DisplayInfo(width: Int(screen.frame.width), height: Int(screen.frame.height),
                               scale: screen.backingScaleFactor,
                               mmWidth: Double(size.width), mmHeight: Double(size.height),
                               main: screen == NSScreen.main)
        }
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    /// The screen a point is on, as an index into `displays()`; zero
    /// when no screen holds it.
    static func screenIndex(of point: CGPoint) -> Int {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0 else { return 0 }
        return NSScreen.screens.firstIndex { displayID(of: $0) == id } ?? 0
    }

    /// The keyboard input source's system id.
    static func layoutID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// The settings that scale the measurement, from the global domain
    /// and the trackpad's own.
    static func inputSettings() -> InputSettings {
        func global(_ key: String) -> Any? {
            CFPreferencesCopyAppValue(key as CFString, kCFPreferencesAnyApplication)
        }
        func trackpad(_ key: String) -> Any? {
            CFPreferencesCopyAppValue(key as CFString, "com.apple.AppleMultitouchTrackpad" as CFString)
        }
        func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
        func flag(_ value: Any?) -> Bool? {
            if let n = value as? NSNumber { return n.boolValue }
            if let s = value as? String { return s.lowercased() == "true" || s == "1" }
            return nil
        }
        return InputSettings(
            keyRepeat: number(global("KeyRepeat")),
            initialKeyRepeat: number(global("InitialKeyRepeat")),
            mouseScaling: number(global("com.apple.mouse.scaling")),
            trackpadScaling: number(global("com.apple.trackpad.scaling")),
            naturalScroll: flag(global("com.apple.swipescrolldirection")),
            tapToClick: flag(trackpad("Clicking")),
            forceClick: flag(trackpad("ForceSuppressed")).map { !$0 } ?? flag(global("com.apple.trackpad.forceClick")))
    }
}

/// One `era` event whenever the instrument's own state differs from the
/// last one written down. The fingerprint is kept in `era.json` beside
/// the record, so the comparison survives a restart and the event fires
/// once per change, not once per boot.
final class EraTracker {
    let file: URL
    /// `era.json`, sealed with the health record and read in either form.
    private let stored: SealedValueFile

    init(file: URL = Paths.data.appendingPathComponent("era.json"), ring: Vault.Ring) {
        self.file = file
        self.stored = SealedValueFile(url: file, ring: ring)
    }

    private struct Stored: Codable {
        var fingerprint: String
        var at: Date
        /// Every keyboard's report interval written down so far, by id.
        /// Absent in a file from before intervals were read.
        var intervals: [String: ReportInterval]?
    }

    /// Seal an era file an earlier build left in the clear. Off main.
    func migrateLegacy() -> RecordMigration {
        var outcome = RecordMigration()
        switch stored.migrate() {
        case .nothing: break
        case .sealed(let bytes):
            outcome.files = 1
            outcome.bytes = Int64(bytes)
        case .paused:
            outcome.paused = true
            outcome.remaining = 1
        case .failed(let why):
            outcome.remaining = 1
            outcome.failed = ["era.json"]
            Log.error("era: could not seal era.json (\(why)) — the plaintext was kept")
        }
        return outcome
    }

    /// The event to record, or nil when nothing changed. A keyboard whose
    /// interval has not been written down (attached for the first time, or
    /// reporting differently) is a change too; one going away is not, for
    /// the reason devices are not in the fingerprint.
    ///
    /// A fingerprint that is there and cannot be read (the key is unavailable,
    /// or it will not open) is not "none yet": no era is recorded and nothing
    /// is written over it.
    func check(_ info: EraInfo, now: Date = Date()) -> ObservationEvent? {
        let previous: Stored?
        switch stored.read() {
        case .absent:
            previous = nil
        case .value(let data, _):
            previous = try? JSONDecoder().decode(Stored.self, from: Data(data))
        case .unavailable, .unreadable:
            return nil
        }
        let known = previous?.intervals ?? [:]
        let unseen = (info.reportIntervals ?? [:]).filter { known[$0.key] != $0.value }
        let changed = previous?.fingerprint != info.fingerprint
        guard changed || !unseen.isEmpty else { return nil }
        var info = info
        info.reason = previous == nil ? "boot" : changed ? "changed" : "keyboard"
        let intervals = known.merging(info.reportIntervals ?? [:]) { _, new in new }
        guard let data = try? JSONEncoder().encode(Stored(fingerprint: info.fingerprint, at: now, intervals: intervals)),
              stored.write([UInt8](data)) == .written
        else {
            // Not written: the event would fire again at the next check, and
            // the record would say "changed" twice for one change.
            return nil
        }
        var event = ObservationEvent(t: now, kind: .era)
        event.era = info
        return event
    }
}
