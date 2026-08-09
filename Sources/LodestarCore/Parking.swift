import AppKit
import CoreGraphics

/// Sliver parking — the hide mechanism slice 0 proved macOS allows.
/// Fully off-screen is clamped by AppKit on every path, so a hidden window
/// keeps a 1px-wide, title-bar-tall corner on its display's bottom-right.
public final class ParkingLot {
    public private(set) var spots: [CGWindowID: CGRect] = [:]

    private let mover: WindowMoving
    private let bounds: () -> [CGRect]

    public init(mover: WindowMoving = AXMover(), bounds: @escaping () -> [CGRect] = Displays.allBounds) {
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
        let display = allBounds.first { $0.intersects(window.frame) }
            ?? allBounds.reduce(.null) { $0.union($1) }
        // Through the mover, never AX directly — its wrapped setters
        // suppress the enhanced-UI move animation (a park must snap, not
        // glide into the corner).
        guard mover.setPosition(window, Self.parkPosition(on: display)) else {
            return false
        }
        spots[window.id] = window.frame
        return true
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
        let ok = mover.setFrame(window, original)
        spots.removeValue(forKey: window.id)
        return ok
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
