import AppKit
import LodestarCore

extension Notification.Name {
    /// Eye comfort moved: the level changed, or the switch did. Posted on
    /// the main thread after every surface has been told to paint again.
    static let eyeComfortDidChange = Notification.Name("LodestarEyeComfortDidChange")
}

/// Where the level lives (design/06-eye-comfort.md): the one place the
/// palette is resolved. `BarTheme.steps(for:)` asks it for a look and every
/// colour of the theme comes through that, so a surface needs no line of its
/// own to be dimmed, calmed or receded; a test fails any that reads a palette
/// directly. With the switch off, or the sun up, it hands back the palettes
/// exactly as they are.
///
/// Read from colour providers, which AppKit may call from a drawing thread,
/// so the value is behind a lock.
final class EyeComfortState: @unchecked Sendable {
    static let shared = EyeComfortState()

    private let lock = NSLock()
    private var isEnabled = false
    private var current = EyeComfort.full
    private var clay = Palette.clay
    private var night = Palette.night

    /// Whether Eye comfort is on.
    var enabled: Bool { lock.withLock { isEnabled } }
    /// The share of its luminance a bright colour keeps: 1 when it is off.
    var level: Double { lock.withLock { current } }

    /// Set what is in force; true when anything a surface draws has changed.
    /// Off is exactly off: the level is full and the palettes are the ones
    /// Palette.swift holds.
    @discardableResult
    func set(enabled: Bool, level: Double) -> Bool {
        let effective = enabled ? min(EyeComfort.full, max(EyeComfort.bedtime, level)) : EyeComfort.full
        return lock.withLock {
            let changed = isEnabled != enabled || current != effective
            guard changed else { return false }
            isEnabled = enabled
            current = effective
            clay = EyeComfort.steps(Palette.clay, level: effective)
            night = EyeComfort.steps(Palette.night, level: effective)
            return true
        }
    }

    /// The look at the level in force.
    func steps(dark: Bool) -> Palette.Steps { lock.withLock { dark ? night : clay } }

    /// The inks a receded surface wears in a look, on that look's pane.
    func recededInks(dark: Bool) -> (ink: Readability.RGB, quietInk: Readability.RGB) {
        Receding.inks(of: steps(dark: dark))
    }
}

/// The timer and the observers behind Eye comfort. It works the level out
/// every five minutes and whenever the Mac wakes or the clock or the time
/// zone changes, hands the answer to `EyeComfortState`, and has every
/// surface paint again. Nothing animates: each step moves a colour's
/// luminance by under 1%, which nobody sees.
///
/// It never touches the look. The Mac's appearance, or the one a test says
/// the Mac has, is what light and dark are; Eye comfort only dims within it.
final class EyeComfortController {
    static let shared = EyeComfortController()

    /// The clock, the zone and the place, injectable so a test can put the
    /// Mac at any hour anywhere.
    var now: () -> Date = Date.init
    var zone: () -> TimeZone = { .current }
    var place: (TimeZone) -> Coordinate = EyeComfortController.estimatedPlace

    /// The step's repeating timer, and what stops it. The app's is a run loop
    /// timer, allowed the tolerance that lets the system coalesce it; a test
    /// turns its own clock instead.
    var every: (_ seconds: TimeInterval, _ work: @escaping () -> Void) -> () -> Void = EyeComfortController.timer

    static func timer(_ seconds: TimeInterval, _ work: @escaping () -> Void) -> () -> Void {
        let tick = Timer(timeInterval: seconds, repeats: true) { _ in work() }
        tick.tolerance = 30
        RunLoop.main.add(tick, forMode: .common)
        return { tick.invalidate() }
    }

    private(set) var enabled = false
    private var stopTimer: (() -> Void)?
    /// The beat it is stepping at, or nil when nothing is watching.
    private(set) var watchingEvery: TimeInterval?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    /// Turn it on or off, with the config. Off puts everything back as it
    /// was before it existed: the palettes at full.
    func configure(enabled: Bool) {
        self.enabled = enabled
        if enabled { startWatching() } else { stopWatching() }
        reevaluate()
    }

    /// Work out where the day stands and make it so.
    func reevaluate() {
        let level = enabled ? EyeComfort.level(at: now(), place: place(zone()), zone: zone()) : EyeComfort.full
        guard EyeComfortState.shared.set(enabled: enabled, level: level) else { return }
        refreshSurfaces()
    }

    /// Every surface paints again in the level in force.
    func refreshSurfaces() {
        for window in NSApplication.shared.windows { SurfacePaint.again(window.contentView) }
        NotificationCenter.default.post(name: .eyeComfortDidChange, object: nil)
    }

    // MARK: - Watching

    private func startWatching() {
        guard stopTimer == nil else { return }
        stopTimer = every(EyeComfort.beat) { [weak self] in self?.reevaluate() }
        watchingEvery = EyeComfort.beat
        let own = NotificationCenter.default, workspace = NSWorkspace.shared.notificationCenter
        func watch(_ center: NotificationCenter, _ name: Notification.Name, _ before: @escaping () -> Void = {}) {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                before()
                self?.reevaluate()
            }))
        }
        watch(workspace, NSWorkspace.didWakeNotification)
        watch(own, .NSSystemClockDidChange)
        watch(own, .NSSystemTimeZoneDidChange) {
            NSTimeZone.resetSystemTimeZone()
            EyeComfortController.placeCache = nil
        }
    }

    private func stopWatching() {
        stopTimer?()
        stopTimer = nil
        watchingEvery = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    // MARK: - Where the Mac is

    private static var placeCache: (identifier: String, place: Coordinate)?

    /// The tz database's listed city for the Mac's zone, from the files macOS
    /// already carries (zone1970.tab, then zone.tab); the offset's meridian
    /// at a mid latitude toward the hemisphere when the zone is in neither.
    /// No location is asked for, and nothing leaves the Mac.
    static func estimatedPlace(for zone: TimeZone) -> Coordinate {
        if let cached = placeCache, cached.identifier == zone.identifier { return cached.place }
        let tables = ["/usr/share/zoneinfo/zone1970.tab", "/usr/share/zoneinfo/zone.tab"]
            .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        let now = Date()
        let standard = TimeInterval(zone.secondsFromGMT(for: now)) - zone.daylightSavingTimeOffset(for: now)
        // A zone that keeps daylight time in January and not in July is in
        // the south; one that keeps neither says nothing, and the north is
        // where most of the world's clocks are.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let year = calendar.component(.year, from: now)
        let january = calendar.date(from: DateComponents(year: year, month: 1, day: 15, hour: 12)) ?? now
        let july = calendar.date(from: DateComponents(year: year, month: 7, day: 15, hour: 12)) ?? now
        let southern = zone.isDaylightSavingTime(for: january) && !zone.isDaylightSavingTime(for: july)
        let place = ZoneCoordinates.estimate(identifier: zone.identifier, tables: tables,
                                             standardOffset: standard, southern: southern)
        placeCache = (zone.identifier, place)
        return place
    }
}

/// Paints a view tree again, the way a change of look does: a layer's colour
/// is fixed when it is set, so every surface that bakes one into a layer
/// already repaints in `viewDidChangeEffectiveAppearance`, which AppKit calls
/// when the look flips and which has no other way to be asked for when the
/// look stays the same (setting the same appearance again calls nothing). A
/// level step is that, with the look unchanged. It runs only when the level
/// moved, which is by day never and at night every five minutes, and every
/// colour the surfaces then resolve comes from `EyeComfortState`.
enum SurfacePaint {
    static func again(_ view: NSView?) {
        guard let view else { return }
        view.viewDidChangeEffectiveAppearance()
        view.needsDisplay = true
        for sub in view.subviews { again(sub) }
    }
}
