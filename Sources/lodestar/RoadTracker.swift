import Foundation
import LodestarCore

/// `FocusRoads` behind a lock: stamped from the main tap (⌘⇥), the
/// health monitor's mouse tap (clicks), and the summon path, and asked
/// from the focus observer. The decision lives in core; this only carries
/// it across threads.
final class RoadTracker {
    private var roads = FocusRoads()
    private let lock = NSLock()

    func summoned(via route: Observations.Route, at now: Date = Date()) {
        lock.lock()
        roads.summoned(via: route, at: now)
        lock.unlock()
    }

    func cmdTabbed(at now: Date = Date()) {
        lock.lock()
        roads.cmdTabbed(at: now)
        lock.unlock()
    }

    func clicked(at now: Date = Date()) {
        lock.lock()
        roads.clicked(at: now)
        lock.unlock()
    }

    func road(at now: Date = Date()) -> String {
        lock.lock()
        defer { lock.unlock() }
        return roads.road(at: now)
    }
}
