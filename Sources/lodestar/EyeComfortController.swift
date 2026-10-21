import AppKit
import LodestarCore

extension Notification.Name {
    /// Eye comfort moved: the level changed, or the switch did. Posted on the
    /// main thread after every surface has been told to paint again.
    static let eyeComfortDidChange = Notification.Name("LodestarEyeComfortDidChange")
}

/// What the theme reads: whether Eye comfort is on and where the evening
/// stands, as the two looks that level makes. One place, so every surface
/// gets the same answer without a line of its own: `BarTheme.steps(for:)`
/// and the accent resolve through it, and with the switch off or the sun up
/// it hands back the palettes exactly as they are.
///
/// Read from colour providers, which AppKit may call from a drawing thread,
/// so the value is behind a lock.
final class EyeComfortState: @unchecked Sendable {
    static let shared = EyeComfortState()

    private let lock = NSLock()
    private var isEnabled = false
    private var current = EyeComfort.Level.day
    private var looks = EyeComfort.unadjusted
    /// The inks a receded surface wears, in each look, for the level in force.
    private var recededClay = Receding.inks(of: Palette.clay)
    private var recededNight = Receding.inks(of: Palette.night)

    var enabled: Bool { lock.withLock { isEnabled } }
    var level: EyeComfort.Level { lock.withLock { current } }

    /// Set what is in force; true when anything a surface draws has changed.
    @discardableResult
    func set(enabled: Bool, level: EyeComfort.Level) -> Bool {
        let effective = enabled ? level : .day
        return lock.withLock {
            let changed = isEnabled != enabled || current != effective
            guard changed else { return false }
            isEnabled = enabled
            current = effective
            looks = EyeComfort.looks(at: effective)
            recededClay = Receding.inks(of: looks.clay.steps)
            recededNight = Receding.inks(of: looks.night.steps)
            return true
        }
    }

    func look(dark: Bool) -> EyeComfort.Look {
        lock.withLock { dark ? looks.night : looks.clay }
    }

    func recededInks(dark: Bool) -> (ink: Readability.RGB, secondary: Readability.RGB) {
        lock.withLock { dark ? recededNight : recededClay }
    }
}

/// The timer and the observers behind Eye comfort. It re-evaluates the level
/// every five minutes and whenever the Mac wakes or the clock or the time
/// zone changes, hands the answer to `EyeComfortState`, and tells every
/// surface to paint again. Nothing animates: each re-evaluation moves the
/// level by a step too small to see (the curve is built for a five-minute
/// beat), and the night look at bedtime lands on the next one, darker and at
/// once, as every look change does.
///
/// Bedtime puts the application itself in the dark look, which every window
/// without an appearance of its own follows, and takes it back to the Mac's
/// when the night ends. The slab keeps standing in the other look (it asks
/// the look around it), so a chosen row is still the opposite.
final class EyeComfortController {
    static let shared = EyeComfortController()

    /// The clock, the zone and the place, injectable so a test can put the
    /// Mac at any hour anywhere.
    var now: () -> Date = Date.init
    var zone: () -> TimeZone = { .current }
    var place: (TimeZone) -> Coordinate = EyeComfortController.estimatedPlace
    /// The application's own appearance when Eye comfort is not forcing the
    /// night: none, which follows the Mac. A test sets one to be a Mac of a
    /// known look.
    var restingAppearance: NSAppearance?

    private(set) var enabled = false
    private var timer: Timer?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    /// The look the type weights were last set for: surfaces built since
    /// carry the weight their look asked for, and the ones built before it
    /// moved are set again when it does.
    private var weightsFor: Bool?

    static let beat: TimeInterval = 5 * 60

    /// Turn it on or off, with the config. Off puts everything back as it was
    /// before it existed: the Mac's own look, the palettes at full.
    func configure(enabled: Bool) {
        if weightsFor == nil { weightsFor = Tone.systemDark }
        self.enabled = enabled
        if enabled { startWatching() } else { stopWatching() }
        reevaluate()
    }

    /// Work out where the evening stands and make it so.
    func reevaluate() {
        let level = enabled ? EyeComfort.level(at: now(), place: place(zone()), zone: zone()) : .day
        let changed = EyeComfortState.shared.set(enabled: enabled, level: level)
        let forced = enabled && level.night
        let wanted = forced ? NSAppearance(named: .darkAqua) : restingAppearance
        let looked = NSApplication.shared.appearance?.name != wanted?.name
        if looked { NSApplication.shared.appearance = wanted }
        if changed || looked { refreshSurfaces() }
    }

    /// The Mac changed its own look (a beat before every window has taken it):
    /// the weights follow it like they follow ours.
    func systemLookChanged() {
        refreshSurfaces()
    }

    /// Every surface paints again in the level in force, and the type set
    /// for the look that has gone is set for the one that has come.
    func refreshSurfaces() {
        Glass.followSystemAppearance()
        let dark = Tone.systemDark
        if let was = weightsFor, was != dark { TypeWeights.follow(dark: dark) }
        weightsFor = dark
        for window in NSApplication.shared.windows { SurfacePaint.again(window.contentView) }
        NotificationCenter.default.post(name: .eyeComfortDidChange, object: nil)
    }

    // MARK: - Watching

    private func startWatching() {
        guard timer == nil else { return }
        let tick = Timer(timeInterval: Self.beat, repeats: true) { [weak self] _ in self?.reevaluate() }
        tick.tolerance = 30
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
        let own = NotificationCenter.default, workspace = NSWorkspace.shared.notificationCenter
        func watch(_ center: NotificationCenter, _ name: Notification.Name, _ then: @escaping () -> Void = {}) {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                then()
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
        timer?.invalidate()
        timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    // MARK: - Where the Mac is

    private static var placeCache: (identifier: String, place: Coordinate)?

    /// The tz database's listed city for the Mac's zone, from the files macOS
    /// already carries; the offset's meridian at a mid latitude toward the
    /// hemisphere when the zone is not in either.
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

/// Paints a view tree again: every surface re-resolves its colours in the
/// look and the level in force. A layer's colour is fixed when it is set, so
/// views that hold one repaint when their appearance "changes" (the same
/// call AppKit makes when the look flips); a level change is that, with the
/// look the same.
enum SurfacePaint {
    static func again(_ view: NSView?) {
        guard let view else { return }
        view.viewDidChangeEffectiveAppearance()
        view.needsDisplay = true
        for sub in view.subviews { again(sub) }
    }
}

/// The type's weight follows the look: one step heavier at night, set when
/// a face is made (`BarTheme.face`). A look that changes under a surface
/// already built (bedtime, or the Mac turning dark) leaves its words in the
/// weight they were built in, so this sets them again: the proportional
/// system faces at the sizes the theme steps, in every label and button
/// standing in a window.
enum TypeWeights {
    static let sizes: Set<CGFloat> = [BarTheme.Scale.body, BarTheme.Scale.title, 19, BarTheme.Scale.input]
    private static let ladder: [NSFont.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]

    static func follow(dark: Bool) {
        for window in NSApplication.shared.windows { walk(window.contentView, dark: dark) }
    }

    private static func walk(_ view: NSView?, dark: Bool) {
        guard let view else { return }
        if let field = view as? NSTextField {
            // A label with one face is its `font`; one with runs of its own
            // (an attributed title) is set run by run. Never both: setting
            // `font` rewrites the runs.
            let runs = field.attributedStringValue
            if runs.length > 0, field.currentEditor() == nil, !isPlain(runs, font: field.font) {
                if let text = restepped(runs, dark: dark) { field.attributedStringValue = text }
            } else if let font = field.font, let moved = stepped(font, dark: dark) {
                field.font = moved
            }
        } else if let button = view as? NSButton, button.attributedTitle.length > 0 {
            if let text = restepped(button.attributedTitle, dark: dark) { button.attributedTitle = text }
        }
        for sub in view.subviews { walk(sub, dark: dark) }
    }

    private static func isPlain(_ text: NSAttributedString, font: NSFont?) -> Bool {
        var plain = true
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if (value as? NSFont) != font { plain = false; stop.pointee = true }
        }
        return plain
    }

    private static func restepped(_ text: NSAttributedString, dark: Bool) -> NSAttributedString? {
        let result = NSMutableAttributedString(attributedString: text)
        var changed = false
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let font = value as? NSFont, let moved = stepped(font, dark: dark) {
                result.addAttribute(.font, value: moved, range: range)
                changed = true
            }
        }
        return changed ? result : nil
    }

    /// The face one weight step toward the look, or nil when it is not one
    /// the theme sets: another family, a mono, a size the theme does not
    /// step, a face with feature settings (the countdown's tabular figures).
    static func stepped(_ font: NSFont, dark: Bool) -> NSFont? {
        guard sizes.contains(font.pointSize),
              !font.fontDescriptor.symbolicTraits.contains(.monoSpace),
              font.fontDescriptor.object(forKey: .featureSettings) == nil,
              font.fontName.hasPrefix(".SF") || font.fontName.hasPrefix(".AppleSystemUIFont"),
              let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any],
              let raw = traits[.weight] as? CGFloat else { return nil }
        guard let index = ladder.indices.min(by: { abs(ladder[$0].rawValue - raw) < abs(ladder[$1].rawValue - raw) })
        else { return nil }
        let target = index + (dark ? 1 : -1)
        guard ladder.indices.contains(target) else { return nil }
        return NSFont.systemFont(ofSize: font.pointSize, weight: ladder[target])
    }
}
