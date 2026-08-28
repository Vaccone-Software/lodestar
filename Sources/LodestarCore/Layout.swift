import AppKit
import CoreGraphics

/// Per-display layouts: every monitor owns an ordered set of equal-sized
/// windows, and verbs act on the active display — pointer-chosen by
/// default (app.active-display). Resting posture is one window,
/// full-screen, per display; multiplicity only ever comes from an explicit
/// beside-summon or a breath.
public final class LayoutController {
    /// Nine, because the digits are the addresses: `lode 1…9` reaches
    /// every member, and a tenth window made 9 ambiguous (the "last" it
    /// promised was a window no digit could name). Beyond this is not
    /// usefully navigable, so the tenth beside-summon is refused rather
    /// than supported.
    public static let maxWindows = 9

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
    /// One gesture, one entry: a step is every display the gesture
    /// touched, snapshotted together — a cross-display move holds both
    /// its source and its destination, so one undo restores both.
    private var undoStack: [[Snapshot]] = []
    private var redoStack: [[Snapshot]] = []
    private var retileGenerations: [CGDirectDisplayID: Int] = [:]
    private var dormant: [String: DormantLayout] = [:]
    private var knownUUIDs: [CGDirectDisplayID: String] = [:]
    /// The usable area each laid-out display had when it was last tiled.
    /// Reconciliation used to branch on display *identity* alone, so a
    /// display that stayed put but changed shape — a resolution switch, an
    /// arrangement drag, the Dock appearing — kept a tiling cut for the
    /// old rectangle: overlaps, gaps, or a strip hidden under the Dock,
    /// until some other layout verb happened to re-cut it.
    private var tiledFrames: [CGDirectDisplayID: CGRect] = [:]

    private let model: WindowQuerying
    private let parking: ParkingLot
    private let mover: WindowMoving
    private let displays: DisplayOracle
    /// Where the AX moves run. Nil executes them inline — tests, and any
    /// caller that needs the world settled on return. The app passes a
    /// serial queue: a retile is ten AX round trips per member, each one
    /// bounded only by the target app's event loop, and the tap shares
    /// the main run loop — so a wedged app used to hold the machine's
    /// keyboard for as long as its slowest window took to answer.
    private let moveQueue: DispatchQueue?

    public var onChange: (() -> Void)?
    /// One retile batch finished: its wall-clock seconds and member count
    /// — the instrument observing itself.
    public var onMoves: ((TimeInterval, Int) -> Void)?

    public init(model: WindowQuerying, parking: ParkingLot,
                mover: WindowMoving = AXMover(), displays: DisplayOracle = .live,
                moveQueue: DispatchQueue? = nil) {
        self.model = model
        self.parking = parking
        self.mover = mover
        self.displays = displays
        self.moveQueue = moveQueue
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
        recordUndo(touching: id, on: display)
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
    /// Returns false — having touched nothing — when the display is at
    /// its cap: the tenth window is prevented, not absorbed. Replacing
    /// instead, which is what this used to do, answered "beside" with a
    /// takeover — the one summon whose meaning must never drift.
    @discardableResult
    public func add(_ id: CGWindowID, on display: CGDirectDisplayID) -> Bool {
        var layout = layouts[display] ?? DisplayLayout()
        if layout.members.contains(id) {
            parking.claim(id)
            retile(on: display)
            return true
        }
        guard layout.members.count < Self.maxWindows else {
            Log.info("layout", ["display": display, "note": "at cap, refused"])
            return false
        }
        parking.claim(id)
        recordUndo(touching: id, on: display)
        detach(id)
        layout = layouts[display] ?? DisplayLayout()
        layout.members.append(id)
        layouts[display] = layout
        retile(on: display)
        onChange?()
        return true
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

    /// Restore a breath: the whole world at once, one group per display —
    /// and one undo step for all of it. Every display the restore touches
    /// is snapshotted together, including displays that only *lose* a
    /// member to it, so a single undo puts the whole world back.
    public func adoptGroups(_ groups: [CGDirectDisplayID: [CGWindowID]], orientation: Orientation) {
        let touched = Set(groups.keys)
            .union(groups.values.flatMap { $0 }.compactMap(display(of:)))
        recordUndo(touched.sorted())
        for (display, members) in groups {
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
            // The layout is gone, so its history has to go with it.
            // Undoing onto a departed display restored the snapshot,
            // claimed each window's parking spot — erasing the record that
            // it was parked — and then moved nothing, because retile
            // returns early for a display that is not there. The windows
            // stayed in the 1px sliver with nothing left that knew where
            // they had come from.
            undoStack.removeAll { step in step.contains { $0.display == display } }
            redoStack.removeAll { step in step.contains { $0.display == display } }
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

        // A display that stayed but changed shape gets its cut redone.
        for info in live {
            guard let layout = layouts[info.id], !layout.members.isEmpty else { continue }
            let bounds = displays.visibleFrame(info.bounds)
            guard let tiled = tiledFrames[info.id], tiled != bounds else { continue }
            Log.info("display-reshaped", ["display": info.id, "members": layout.members.count])
            retile(on: info.id)
            onChange?()
        }
        // Nothing laid out on a display any more: forget its shape too.
        tiledFrames = tiledFrames.filter { liveIDs.contains($0.key) }
    }

    // MARK: - Undo / redo (one global timeline)

    /// Returns the affected display so focus can follow.
    @discardableResult
    public func undo() -> CGDirectDisplayID? {
        guard let step = undoStack.popLast() else { return nil }
        redoStack.append(step.map { current($0.display) })
        apply(step: step)
        // The last snapshot is the source in a cross-display step — where
        // the moved window just returned, which is where the eye went.
        return step.last?.display
    }

    @discardableResult
    public func redo() -> CGDirectDisplayID? {
        guard let step = redoStack.popLast() else { return nil }
        undoStack.append(step.map { current($0.display) })
        apply(step: step)
        return step.last?.display
    }

    /// Every display in the step restores under one rule: a window that
    /// belongs anywhere in the step is never parked by another display's
    /// half of it — parked-then-claimed was a visible flick to the sliver
    /// and back.
    private func apply(step: [Snapshot]) {
        let arriving = Set(step.flatMap(\.layout.members))
        for snapshot in step { apply(snapshot, keeping: arriving) }
    }

    private func current(_ display: CGDirectDisplayID) -> Snapshot {
        Snapshot(display: display, layout: layouts[display] ?? DisplayLayout())
    }

    private func recordUndo(_ display: CGDirectDisplayID) {
        recordUndo([display])
    }

    /// The undo for a summon: the destination, plus — when the window is
    /// leaving another display's layout — the source, so undo returns it
    /// home instead of parking it as a stranger.
    private func recordUndo(touching id: CGWindowID, on display: CGDirectDisplayID) {
        var displays = [display]
        if let source = self.display(of: id), source != display {
            displays.append(source)
        }
        recordUndo(displays)
    }

    private func recordUndo(_ displays: [CGDirectDisplayID]) {
        let step = displays.map(current)
        if undoStack.last == step { return }
        undoStack.append(step)
        if undoStack.count > 20 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func apply(_ snapshot: Snapshot, keeping: Set<CGWindowID> = []) {
        let incoming = Set(snapshot.layout.members)
        let previous = (layouts[snapshot.display]?.members ?? [])
            .filter { !incoming.contains($0) && !keeping.contains($0) }
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
        tiledFrames[display] = bounds
        let frames = Tiling.frames(count: layout.members.count, in: bounds, orientation: layout.orientation)

        // The decision happens here, on the model's thread; only the AX
        // conversation moves. Windows are captured now so the batch acts
        // on the members this retile decided, not on whatever the layout
        // holds by the time a queue gets to it.
        var moves: [(WindowModel.Window, CGRect)] = []
        for (id, frame) in zip(layout.members, frames) {
            guard let window = model.window(id), window.isAlive else { continue }
            moves.append((window, frame))
        }
        let members = layout.members
        perform(moves: moves) { [weak self] in
            guard let self, self.retileGenerations[display] == generation else { return }
            for id in members { self.model.refreshFrame(id) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.correctivePass(on: display, generation: generation)
            }
        }
    }

    /// Run a batch of frame writes, then `completion` on the main thread.
    /// Inline when no queue was given — the tests' world, where the moves
    /// must land before the assertion. Ordering across batches holds
    /// either way: the queue is serial.
    private func perform(moves: [(WindowModel.Window, CGRect)],
                         completion: @escaping () -> Void) {
        guard let moveQueue else {
            let began = Date()
            for (window, frame) in moves { mover.setFrame(window, frame) }
            onMoves?(Date().timeIntervalSince(began), moves.count)
            completion()
            return
        }
        moveQueue.async { [mover, onMoves] in
            let began = Date()
            for (window, frame) in moves { mover.setFrame(window, frame) }
            let took = Date().timeIntervalSince(began)
            DispatchQueue.main.async {
                onMoves?(took, moves.count)
                completion()
            }
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
        var moves: [(WindowModel.Window, CGRect)] = []
        for (index, window) in alive.enumerated() {
            let span = spans[index] > 0 ? spans[index] : flexibleSpan
            let frame = horizontal
                ? CGRect(x: cursor, y: bounds.minY, width: span, height: bounds.height)
                : CGRect(x: bounds.minX, y: cursor, width: bounds.width, height: span)
            moves.append((window, frame))
            cursor += span
        }
        let members = layout.members
        perform(moves: moves) { [weak self] in
            guard let self, self.retileGenerations[display] == generation else { return }
            for id in members { self.model.refreshFrame(id) }
        }
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
