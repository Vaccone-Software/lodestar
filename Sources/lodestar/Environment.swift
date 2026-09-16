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

    init(file: URL = Paths.data.appendingPathComponent("era.json")) {
        self.file = file
    }

    private struct Stored: Codable {
        var fingerprint: String
        var at: Date
    }

    /// The event to record, or nil when nothing changed.
    func check(_ info: EraInfo, now: Date = Date()) -> ObservationEvent? {
        let stored = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        guard stored?.fingerprint != info.fingerprint else { return nil }
        var info = info
        info.reason = stored == nil ? "boot" : "changed"
        if let data = try? JSONEncoder().encode(Stored(fingerprint: info.fingerprint, at: now)) {
            try? data.write(to: file, options: .atomic)
            Paths.restrict(file)
        }
        var event = ObservationEvent(t: now, kind: .era)
        event.era = info
        return event
    }
}
