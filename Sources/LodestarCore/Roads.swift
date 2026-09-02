import Foundation

/// Which road a focus change took.
///
/// The observation layer has always recorded *that* focus moved and never
/// *how* — Lodestar's own summon, the system's ⌘⇥, a click on a window or
/// the Dock — so the transition matrix could price nothing and "what
/// would a back key be worth" could not be answered from the data. This
/// remembers the hand's most recent act, and a focus change that follows
/// inside the window is charged to it. Pure: the shell stamps it from the
/// tap, the mouse, and the summon path, and asks it from the focus
/// observer.
public struct FocusRoads: Equatable {
    /// How long an act stays the plausible cause of a focus change. A
    /// summon raises its window within milliseconds; ⌘⇥ lands on release,
    /// which can be a second later while the switcher is browsed; a click
    /// is immediate.
    public static let window: TimeInterval = 1.5
    public static let cmdTab = "cmd-tab"
    public static let click = "click"
    public static let other = "other"

    private var summonAt = Date.distantPast
    private var summonRoute = ""
    private var cmdTabAt = Date.distantPast
    private var clickAt = Date.distantPast

    public init() {}

    public mutating func summoned(via route: Observations.Route, at now: Date) {
        summonAt = now
        summonRoute = route.rawValue
    }

    public mutating func cmdTabbed(at now: Date) {
        cmdTabAt = now
    }

    public mutating func clicked(at now: Date) {
        clickAt = now
    }

    /// The road the focus change at `now` most plausibly took: the most
    /// recent act inside the window, or `other` when nothing the tap
    /// could name preceded it — a URL another app opened, a notification
    /// clicked, an app activating itself.
    public func road(at now: Date) -> String {
        func fresh(_ at: Date) -> Bool {
            guard at != .distantPast else { return false }
            let age = now.timeIntervalSince(at)
            return age >= 0 && age <= Self.window
        }
        var best: (at: Date, road: String)?
        for (at, road) in [(summonAt, summonRoute), (cmdTabAt, Self.cmdTab), (clickAt, Self.click)]
            where fresh(at) && !road.isEmpty {
            if best == nil || at > best!.at { best = (at, road) }
        }
        return best?.road ?? Self.other
    }
}
