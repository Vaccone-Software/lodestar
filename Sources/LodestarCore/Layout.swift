import AppKit
import CoreGraphics

/// Per-display layouts: every monitor owns an ordered set of equal-sized
/// windows, and verbs act on the active display — pointer-chosen by
/// default (app.active-display). Resting posture is one window,
/// full-screen, per display; multiplicity only ever comes from an explicit
/// beside-summon or a breath.
public final class LayoutController {
    public static let maxWindows = 10

    public struct DisplayLayout: Equatable {
        public var members: [CGWindowID] = []
        public var orientation: Orientation = .horizontal
    }

    struct Snapshot: Equatable {
        let display: CGDirectDisplayID
        let layout: DisplayLayout
    }

    /// A departed monitor's arrangement, keyed by hardware UUID, waiting
    /// for the monitor to return. In-memory only — a restart while
    /// undocked forgets it, deliberately (restarts are fresh).
    public struct DormantLayout: Equatable {
        public let members: [CGWindowID]
        public let orientation: Orientation
    }

    private var layouts: [CGDirectDisplayID: DisplayLayout] = [:]
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var retileGenerations: [CGDirectDisplayID: Int] = [:]
    private var dormant: [String: DormantLayout] = [:]
    private var knownUUIDs: [CGDirectDisplayID: String] = [:]

    private let model: WindowQuerying
    private let parking: ParkingLot
    private let mover: WindowMoving
    private let displays: DisplayOracle

    public var onChange: (() -> Void)?

    public init(model: WindowQuerying, parking: ParkingLot,
                mover: WindowMoving = AXMover(), displays: DisplayOracle = .live) {
        self.model = model
        self.parking = parking
        self.mover = mover
        self.displays = displays
    }

    // MARK: - Active display

    /// The monitor being used — by pointer or by keyboard focus, per
    /// app.active-display. Falls back sensibly either way.
    public func activeDisplay() -> Displays.DisplayInfo? {
        if ActivePolicy.mode == .pointer,
           let location = CGEvent(source: nil)?.location,
           let display = displays.displayContaining(CGRect(origin: location, size: CGSize(width: 1, height: 1))) {
            return display
        }
        if let focused = model.focusedWindow, focused.isAlive,
           let display = displays.displayContaining(focused.frame) {
            return display
        }
        return displays.ordered().first
    }

    public func members(on display: CGDirectDisplayID) -> [CGWindowID] {
        layouts[display]?.members ?? []
    }

    public func orientation(on display: CGDirectDisplayID) -> Orientation {
        layouts[display]?.orientation ?? .horizontal
    }

    /// Set a display's orientation without touching membership — a breath
    /// resurrecting onto an empty display carries its saved orientation.
    public func setOrientation(_ orientation: Orientation, on display: CGDirectDisplayID) {
        var layout = layouts[display] ?? DisplayLayout()
        guard layout.orientation != orientation else { return }
        layout.orientation = orientation
        layouts[display] = layout
        retile(on: display)
    }

    /// Every window in any display's layout — the visible world.
    public var allMembers: Set<CGWindowID> {
        Set(layouts.values.flatMap(\.members))
    }

    public func display(of windowID: CGWindowID) -> CGDirectDisplayID? {
        layouts.first { $0.value.members.contains(windowID) }?.key
    }

    // MARK: - Mutations (display-scoped)

    /// Plain summon: this window becomes the display's whole layout,
    /// full-screen. The display's previous members are parked.
    public func replace(with id: CGWindowID, on display: CGDirectDisplayID) {
        recordUndo(display)
        detach(id)
        var layout = layouts[display] ?? DisplayLayout()
        let previous = layout.members.filter { $0 != id }
        layout.members = [id]
        layouts[display] = layout
        parking.claim(id)
        park(previous)
        retile(on: display)
        onChange?()
    }

    /// Beside-summon: join the display's layout as an equal member.
    public func add(_ id: CGWindowID, on display: CGDirectDisplayID) {
        parking.claim(id)
        var layout = layouts[display] ?? DisplayLayout()
        if layout.members.contains(id) {
            retile(on: display)
            return
        }
        guard layout.members.count < Self.maxWindows else {
            Log.info("layout", ["display": display, "note": "at cap, replacing"])
            replace(with: id, on: display)
            return
        }
        recordUndo(display)
        detach(id)
        layout = layouts[display] ?? DisplayLayout()
        layout.members.append(id)
        layouts[display] = layout
        retile(on: display)
        onChange?()
    }

    /// A window died or left; its display's survivors retile. World-driven,
    /// so not an undo step.
    public func remove(_ id: CGWindowID) {
        guard let display = display(of: id) else { return }
        layouts[display]?.members.removeAll { $0 == id }
        retile(on: display)
        onChange?()
    }

    public func flipOrientation(on display: CGDirectDisplayID) {
        recordUndo(display)
        var layout = layouts[display] ?? DisplayLayout()
        layout.orientation = layout.orientation.flipped
        layouts[display] = layout
        retile(on: display)
        onChange?()
    }

    /// Restore a breath: the whole world at once, one group per display.
    public func adoptGroups(_ groups: [CGDirectDisplayID: [CGWindowID]], orientation: Orientation) {
        for (display, members) in groups {
            recordUndo(display)
            for id in members { detach(id) }
            var layout = layouts[display] ?? DisplayLayout()
            let incoming = Set(members)
            let previous = layout.members.filter { !incoming.contains($0) }
            layout.members = members
            layout.orientation = orientation
            layouts[display] = layout
            for id in members { parking.claim(id) }
            park(previous)
            retile(on: display)
        }
        onChange?()
    }

    // MARK: - Docking

    /// Reconcile the layout world with the monitors actually present.
    /// A departed display's members park and its arrangement is remembered
    /// by hardware UUID; the same monitor returning restores whatever the
    /// user hasn't re-placed since — the world-moved-on guard, same as
    /// the docking restore.
    public func reconcileDisplays() {
        let live = displays.ordered()
        let liveIDs = Set(live.map(\.id))

        for (display, layout) in layouts where !liveIDs.contains(display) {
            if let uuid = knownUUIDs[display], !layout.members.isEmpty {
                dormant[uuid] = DormantLayout(members: layout.members,
                                              orientation: layout.orientation)
            }
            park(layout.members)
            layouts.removeValue(forKey: display)
            retileGenerations.removeValue(forKey: display)
            knownUUIDs.removeValue(forKey: display)
            Log.info("display-departed", ["display": display, "parked": layout.members.count])
            onChange?()
        }

        // Learn identities while the hardware is present — a UUID can only
        // be read from a connected display.
        for info in live where knownUUIDs[info.id] == nil {
            knownUUIDs[info.id] = displays.uuid(info.id)
        }

        for info in live {
            guard let uuid = knownUUIDs[info.id], let record = dormant[uuid] else { continue }
            dormant.removeValue(forKey: uuid) // one attempt per return
            guard (layouts[info.id]?.members ?? []).isEmpty else { continue }
            let placed = allMembers
            let restorable = record.members.filter { id in
                model.window(id)?.isAlive == true && !placed.contains(id)
            }
            guard !restorable.isEmpty else { continue }
            recordUndo(info.id)
            for id in restorable { parking.claim(id) }
            layouts[info.id] = DisplayLayout(members: restorable, orientation: record.orientation)
            retile(on: info.id)
            Log.info("display-returned", ["display": info.id, "restored": restorable.count])
            onChange?()
        }
    }

    // MARK: - Undo / redo (one global timeline)

    /// Returns the affected display so focus can follow.
    @discardableResult
    public func undo() -> CGDirectDisplayID? {
        guard let snapshot = undoStack.popLast() else { return nil }
        redoStack.append(current(snapshot.display))
        apply(snapshot)
        return snapshot.display
    }

    @discardableResult
    public func redo() -> CGDirectDisplayID? {
        guard let snapshot = redoStack.popLast() else { return nil }
        undoStack.append(current(snapshot.display))
        apply(snapshot)
        return snapshot.display
    }

    private func current(_ display: CGDirectDisplayID) -> Snapshot {
        Snapshot(display: display, layout: layouts[display] ?? DisplayLayout())
    }

    private func recordUndo(_ display: CGDirectDisplayID) {
        let snapshot = current(display)
        if undoStack.last == snapshot { return }
        undoStack.append(snapshot)
        if undoStack.count > 20 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func apply(_ snapshot: Snapshot) {
        let incoming = Set(snapshot.layout.members)
        let previous = (layouts[snapshot.display]?.members ?? []).filter { !incoming.contains($0) }
        Log.info("layout", [
            "display": snapshot.display,
            "was": layouts[snapshot.display]?.members ?? [],
            "now": snapshot.layout.members,
            "orientation": snapshot.layout.orientation.rawValue,
            "parking": previous,
        ])
        for id in snapshot.layout.members { detach(id) }
        layouts[snapshot.display] = snapshot.layout
        for id in snapshot.layout.members { parking.claim(id) }
        park(previous)
        retile(on: snapshot.display)
        onChange?()
    }

    // MARK: - Helpers

    /// A window belongs to at most one display's layout.
    private func detach(_ id: CGWindowID) {
        for (display, var layout) in layouts where layout.members.contains(id) {
            layout.members.removeAll { $0 == id }
            layouts[display] = layout
            retile(on: display)
        }
    }

    private func park(_ ids: [CGWindowID]) {
        for id in ids {
            if let window = model.window(id), window.isAlive {
                parking.park(window)
            }
        }
    }

    // MARK: - Tiling

    public func retile(on display: CGDirectDisplayID) {
        guard var layout = layouts[display] else { return }
        layout.members.removeAll { model.window($0)?.isAlive != true }
        layouts[display] = layout
        let generation = (retileGenerations[display] ?? 0) + 1
        retileGenerations[display] = generation
        guard !layout.members.isEmpty else { return }

        guard let displayBounds = displays.ordered().first(where: { $0.id == display })?.bounds else { return }
        let bounds = displays.visibleFrame(displayBounds)
        let frames = Tiling.frames(count: layout.members.count, in: bounds, orientation: layout.orientation)

        for (id, frame) in zip(layout.members, frames) {
            guard let window = model.window(id), window.isAlive else { continue }
            mover.setFrame(window, frame)
        }
        for id in layout.members { model.refreshFrame(id) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.correctivePass(on: display, generation: generation)
        }
    }

    private func correctivePass(on display: CGDirectDisplayID, generation: Int) {
        guard retileGenerations[display] == generation,
              let layout = layouts[display], layout.members.count > 1 else { return }
        for id in layout.members { model.refreshFrame(id) }
        let alive = layout.members.compactMap { model.window($0) }.filter(\.isAlive)
        guard alive.count == layout.members.count else { return }

        guard let displayBounds = displays.ordered().first(where: { $0.id == display })?.bounds else { return }
        let bounds = displays.visibleFrame(displayBounds)
        let horizontal = layout.orientation == .horizontal
        let requested = Tiling.frames(count: alive.count, in: bounds, orientation: layout.orientation)

        var spans: [CGFloat] = []
        var stubbornTotal: CGFloat = 0
        var flexibleCount = 0
        for (window, want) in zip(alive, requested) {
            let achieved = horizontal ? window.frame.width : window.frame.height
            let wanted = horizontal ? want.width : want.height
            if achieved > wanted + 6 {
                spans.append(achieved)
                stubbornTotal += achieved
            } else {
                spans.append(-1)
                flexibleCount += 1
            }
        }
        guard flexibleCount > 0, flexibleCount < alive.count else { return }
        let total = horizontal ? bounds.width : bounds.height
        let flexibleSpan = (total - stubbornTotal) / CGFloat(flexibleCount)
        guard flexibleSpan >= 120 else { return }

        var cursor = horizontal ? bounds.minX : bounds.minY
        for (index, window) in alive.enumerated() {
            let span = spans[index] > 0 ? spans[index] : flexibleSpan
            let frame = horizontal
                ? CGRect(x: cursor, y: bounds.minY, width: span, height: bounds.height)
                : CGRect(x: bounds.minX, y: cursor, width: bounds.width, height: span)
            mover.setFrame(window, frame)
            cursor += span
        }
        for id in layout.members { model.refreshFrame(id) }
        Log.info("layout-corrective", ["display": display, "absorbed": alive.count - flexibleCount])
    }

    /// lode ⇧digit: insert-and-shift reorder within a display's layout.
    @discardableResult
    public func move(_ id: CGWindowID, toDigit digit: Int, on display: CGDirectDisplayID) -> Bool {
        let ordered = orderedByPosition(on: display)
        guard let reordered = Placement.reorder(ordered, move: id, toDigit: digit) else {
            return false
        }
        recordUndo(display)
        var layout = layouts[display] ?? DisplayLayout()
        layout.members = reordered
        layouts[display] = layout
        Log.info("reorder", ["display": display, "order": reordered])
        retile(on: display)
        onChange?()
        return true
    }

    /// lode+digit on the active display: 1 = leftmost/topmost … 9 = last.
    public func windowID(atDigit digit: Int, on display: CGDirectDisplayID) -> CGWindowID? {
        let ordered = orderedByPosition(on: display)
        guard !ordered.isEmpty else { return nil }
        if digit == 9 { return ordered.last }
        guard digit >= 1 && digit <= ordered.count else { return nil }
        return ordered[digit - 1]
    }

    public func orderedByPosition(on display: CGDirectDisplayID) -> [CGWindowID] {
        let entries = (layouts[display]?.members ?? []).compactMap { id -> (id: CGWindowID, frame: CGRect)? in
            guard let window = model.window(id), window.isAlive else { return nil }
            return (id, window.frame)
        }
        return Tiling.indexOrder(entries)
    }

    /// All members everywhere, display by display left to right, position-
    /// ordered within each — the breath capture order.
    public func worldOrderedByPosition() -> [CGWindowID] {
        displays.ordered().flatMap { orderedByPosition(on: $0.id) }
    }
}
