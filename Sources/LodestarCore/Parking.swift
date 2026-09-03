import AppKit
import CoreGraphics

/// Sliver parking — the hide mechanism slice 0 proved macOS allows.
/// Fully off-screen is clamped by AppKit on every path, so a hidden window
/// keeps a 1px-wide, title-bar-tall corner on its display's bottom-right.
public final class ParkingLot {
    public private(set) var spots: [CGWindowID: CGRect] = [:]

    private let mover: WindowMoving
    private let bounds: () -> [CGRect]

    /// The lane the writes travel on — the same serial queue the layout's
    /// frame moves use, so a park queued before a move lands before it.
    /// Nil runs them inline, which is the tests' world.
    private let moveQueue: DispatchQueue?

    public init(mover: WindowMoving = AXMover(), bounds: @escaping () -> [CGRect] = Displays.allBounds,
                moveQueue: DispatchQueue? = nil) {
        self.moveQueue = moveQueue
        self.mover = mover
        self.bounds = bounds
    }

    public static func parkPosition(on display: CGRect) -> CGPoint {
        CGPoint(x: display.maxX - 1, y: display.maxY - 30)
    }

    public func isParked(_ id: CGWindowID) -> Bool { spots[id] != nil }

    /// Remember the window's real frame and slide it to the corner sliver of
    /// the display it currently occupies.
    @discardableResult
    public func park(_ window: WindowModel.Window) -> Bool {
        guard spots[window.id] == nil else { return true }
        guard window.isAlive else { return false }
        let allBounds = bounds()
        // A real display, or nowhere. The union used to be the fallback,
        // and with no displays attached — which happens, briefly, around
        // sleep and display changes — it is CGRect.null, so the park
        // position came out (inf, inf). AX accepts that, and `spots` then
        // recorded a park that had not happened. FINDINGS §2 also warns
        // that a union corner can land on no display at all in an L-shaped
        // arrangement, which would peek the sliver onto a second monitor.
        guard let display = allBounds.first(where: { $0.intersects(window.frame) })
                ?? allBounds.first else {
            Log.error("park: no display to park onto", ["window": window.id])
            return false
        }
        // Through the mover, never AX directly — its wrapped setters
        // suppress the enhanced-UI move animation (a park must snap, not
        // glide into the corner). On the move lane, off the tap: a park
        // was a synchronous accessibility write inside the gesture, and a
        // wedged app answered it a second late — the tap's whole budget —
        // while the keyboard waited. The spot is recorded as the intent
        // and forgotten again if the write comes back refused.
        let target = Self.parkPosition(on: display)
        let original = window.frame
        spots[window.id] = original
        let id = window.id
        let ok = write({ [mover] in mover.setPosition(window, target) }) { [weak self] in
            guard let self, self.spots[id] == original else { return }
            self.spots.removeValue(forKey: id)
        }
        if !ok { spots.removeValue(forKey: id) }
        return ok
    }

    /// One write on the lane. Inline it answers honestly; queued it
    /// answers "queued" and reports a refusal on the main thread later,
    /// which is the only shape a write off the tap can have.
    private func write(_ work: @escaping () -> Bool, onFailure: @escaping () -> Void) -> Bool {
        guard let moveQueue else { return work() }
        moveQueue.async {
            if !work() { DispatchQueue.main.async(execute: onFailure) }
        }
        return true
    }

    /// Every write queued so far has landed. The shutdown path restores
    /// the parked windows and then exits, and an exit with parks still in
    /// the lane would strand them in the corner.
    public func waitForWrites() {
        moveQueue?.sync {}
    }

    /// Restore a parked window to its remembered frame (size-position-size,
    /// in case the original frame lives on another display).
    @discardableResult
    public func unpark(_ window: WindowModel.Window) -> Bool {
        guard let original = spots[window.id] else { return true }
        guard window.isAlive else {
            spots.removeValue(forKey: window.id)
            return false
        }
        spots.removeValue(forKey: window.id)
        let frame = restorable(original)
        return write({ [mover] in mover.setFrame(window, frame) }) {
            Log.error("unpark: the app refused the frame", ["window": window.id])
        }
    }

    /// The remembered frame, made reachable on the displays that exist now.
    ///
    /// A frame recorded on a monitor that has since been unplugged names a
    /// coordinate space nobody has any more; replaying it verbatim let
    /// AppKit clamp the window to a screen edge, which is where the user
    /// then had to go find it with the mouse. A degenerate frame — one
    /// saved while the window was already a sliver — is no better.
    private func restorable(_ frame: CGRect) -> CGRect {
        let allBounds = bounds()
        let live = allBounds.first { $0.intersects(frame) }
        // A parked sliver is 1pt wide by construction, so anything this
        // thin was never a window the user arranged.
        let degenerate = frame.width < 8 || frame.height < 8

        // A frame that still reaches a live display is the user's own
        // arrangement and comes back exactly as it was — including a
        // window deliberately straddling two monitors, which clamping
        // would have yanked wholly onto one of them.
        if live != nil, !degenerate { return frame }

        guard let home = live ?? allBounds.first else { return frame }
        var out = frame
        if degenerate { out.size = CGSize(width: 320, height: 240) }
        out.size.width = min(out.width, home.width)
        out.size.height = min(out.height, home.height)
        out.origin.x = min(max(out.minX, home.minX), home.maxX - out.width)
        out.origin.y = min(max(out.minY, home.minY), home.maxY - out.height)
        return out
    }

    /// Drop bookkeeping for a window without moving it (e.g. it was summoned
    /// into a layout and will be framed explicitly).
    public func claim(_ id: CGWindowID) {
        spots.removeValue(forKey: id)
    }

    public func forget(_ id: CGWindowID) {
        spots.removeValue(forKey: id)
    }

    public func snapshot() -> [CGWindowID: CGRect] { spots }

    public func adopt(_ state: [CGWindowID: CGRect]) {
        spots.merge(state) { current, _ in current }
    }
}
