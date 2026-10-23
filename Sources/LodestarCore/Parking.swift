import AppKit
import CoreGraphics

/// Who a parked window was, without the id. The id dies with the login;
/// the app and the title are how a later one recognizes the sliver.
public struct ParkedIdentity: Codable, Sendable, Equatable {
    public var bundleID: String?
    public var appName: String
    public var title: String

    public init(bundleID: String?, appName: String, title: String) {
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
    }
}

/// A window's real frame, and enough to find the window again after its
/// id has been handed out to someone else.
public struct ParkedWindow: Codable, Sendable, Equatable {
    public var frame: CGRect
    public var bundleID: String?
    public var appName: String
    public var title: String

    public init(frame: CGRect, bundleID: String?, appName: String, title: String) {
        self.frame = frame
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
    }

    public var identity: ParkedIdentity {
        ParkedIdentity(bundleID: bundleID, appName: appName, title: title)
    }

    /// A frame with no app behind it cannot be matched to a live window,
    /// and must not be aimed at whatever window now holds the old id.
    public var isRecognizable: Bool {
        if let bundleID, !bundleID.isEmpty { return true }
        return !appName.isEmpty
    }
}

/// Sliver parking — the hide mechanism slice 0 proved macOS allows.
/// Fully off-screen is clamped by AppKit on every path, so a hidden window
/// keeps a 1px-wide, title-bar-tall corner on its display's bottom-right.
public final class ParkingLot {
    /// A live window a stranded frame might belong to.
    public struct Candidate: Equatable, Sendable {
        public var id: CGWindowID
        public var frame: CGRect
        public var bundleID: String?
        public var appName: String
        public var title: String

        public init(id: CGWindowID, frame: CGRect, bundleID: String?, appName: String, title: String) {
            self.id = id
            self.frame = frame
            self.bundleID = bundleID
            self.appName = appName
            self.title = title
        }
    }

    private var remembered: [CGWindowID: ParkedWindow] = [:]
    /// Bumped whenever a window's record is replaced, so a refusal for an
    /// older unpark cannot write its frame back over a newer one.
    private var tickets: [CGWindowID: UInt] = [:]

    public var spots: [CGWindowID: CGRect] {
        remembered.mapValues(\.frame)
    }

    private let mover: WindowMoving
    private let bounds: () -> [CGRect]

    /// The lane the writes travel on — the same serial queue the layout's
    /// frame moves use, so a park queued before a move lands before it.
    /// Nil runs them inline, which is the tests' world.
    private let moveQueue: DispatchQueue?
    private let revisionLock = NSLock()
    private var revisions: [() -> Void] = []

    /// A queued refusal changed the books. It runs on the main thread, or
    /// inside `waitForWrites` when a caller is waiting, so a save that
    /// already recorded the optimistic bookkeeping can be rewritten.
    public var onRevision: (() -> Void)?

    public init(mover: WindowMoving = AXMover(), bounds: @escaping () -> [CGRect] = Displays.allBounds,
                moveQueue: DispatchQueue? = nil) {
        self.moveQueue = moveQueue
        self.mover = mover
        self.bounds = bounds
    }

    public static func parkPosition(on display: CGRect) -> CGPoint {
        CGPoint(x: display.maxX - 1, y: display.maxY - 30)
    }

    /// The displays a park or a corner match would use right now.
    public var screenBounds: [CGRect] { bounds() }

    public func isParked(_ id: CGWindowID) -> Bool { remembered[id] != nil }

    /// Remember the window's real frame and slide it to the corner sliver of
    /// the display it currently occupies.
    @discardableResult
    public func park(_ window: WindowModel.Window) -> Bool {
        guard remembered[window.id] == nil else { return true }
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
        let saved = ParkedWindow(frame: original, bundleID: window.bundleID,
                                 appName: window.appName, title: window.title)
        let id = window.id
        bump(id)
        remembered[id] = saved
        let ok = write({ [mover] in mover.setPosition(window, target) }) { [weak self] in
            guard let self, self.remembered[id]?.frame == original else { return }
            self.remembered.removeValue(forKey: id)
            self.onRevision?()
        }
        if !ok, remembered[id]?.frame == original { remembered.removeValue(forKey: id) }
        return ok
    }

    /// One write on the lane. Inline it answers honestly; queued it
    /// answers "accepted" and reports a refusal later — on the main
    /// thread, and also inside `waitForWrites`, so a caller that waits
    /// sees the refusal before it reports success. "Accepted" is not
    /// "the window moved."
    private func write(_ work: @escaping () -> Bool, onFailure: @escaping () -> Void) -> Bool {
        guard let moveQueue else { return work() }
        moveQueue.async { [weak self] in
            guard !work() else { return }
            self?.enqueueRevision(onFailure)
        }
        return true
    }

    private func enqueueRevision(_ revision: @escaping () -> Void) {
        revisionLock.lock()
        revisions.append(revision)
        revisionLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.applyRevisions() }
    }

    private func applyRevisions() {
        revisionLock.lock()
        let pending = revisions
        revisions.removeAll()
        revisionLock.unlock()
        pending.forEach { $0() }
    }

    /// Every write queued so far has landed, and so has the bookkeeping a
    /// refusal owes. The shutdown path restores the parked windows and
    /// then exits, and an exit with parks still in the lane — or a refusal
    /// still waiting on the main thread — would strand them in the corner.
    public func waitForWrites() {
        moveQueue?.sync {}
        applyRevisions()
    }

    /// Restore a parked window to its remembered frame (size-position-size,
    /// in case the original frame lives on another display).
    ///
    /// The record leaves the books as the intent and comes back if the
    /// move is refused, which is the shape park already has. Inline, the
    /// returned bool is the move's own answer. On the lane it is only
    /// "accepted": the frame is put back when the refusal arrives, and
    /// `waitForWrites` is when a caller can see which one it was.
    @discardableResult
    public func unpark(_ window: WindowModel.Window) -> Bool {
        guard let saved = remembered[window.id] else { return true }
        let id = window.id
        let ticket = bump(id)
        guard window.isAlive else {
            remembered.removeValue(forKey: id)
            return false
        }
        remembered.removeValue(forKey: id)
        let frame = restorable(saved.frame)
        let ok = write({ [mover] in mover.setFrame(window, frame) }) { [weak self] in
            guard let self, self.tickets[id] == ticket, self.remembered[id] == nil else { return }
            self.remembered[id] = saved
            Log.error("unpark: the app refused the frame", ["window": id])
            self.onRevision?()
        }
        if !ok, tickets[id] == ticket, remembered[id] == nil {
            remembered[id] = saved
        }
        return ok
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
        bump(id)
        remembered.removeValue(forKey: id)
    }

    public func forget(_ id: CGWindowID) {
        bump(id)
        remembered.removeValue(forKey: id)
    }

    public func snapshot() -> [CGWindowID: CGRect] { spots }

    public func records() -> [CGWindowID: ParkedWindow] { remembered }

    public func adopt(_ state: [CGWindowID: CGRect]) {
        for (id, frame) in state where remembered[id] == nil {
            remembered[id] = ParkedWindow(frame: frame, bundleID: nil, appName: "", title: "")
        }
    }

    public func adopt(_ records: [CGWindowID: ParkedWindow]) {
        for (id, record) in records where remembered[id] == nil {
            remembered[id] = record
        }
    }

    @discardableResult
    private func bump(_ id: CGWindowID) -> UInt {
        let next = (tickets[id] ?? 0) &+ 1
        tickets[id] = next
        return next
    }

    /// Pair frames left behind by an unclean exit with windows that are
    /// still sitting in a parking corner.
    ///
    /// A window that is not in a corner is never a candidate: a recycled
    /// id, or a window the user has since placed, keeps the frame it has.
    /// App and title have to agree, and the two sides have to be the same
    /// length, so a missing window is not guessed. One window of an app
    /// whose title changed while it was a sliver is the exception — there
    /// is nothing to confuse it with. Same-title windows are paired in a
    /// stable order and can swap frames; both leave the corner.
    public static func reattach(_ stranded: [ParkedWindow], onto windows: [Candidate],
                                displays: [CGRect]) -> [CGWindowID: ParkedWindow] {
        let recognizable = windows.filter {
            $0.isRecognizable && isParkedCorner($0.frame, on: displays)
        }
        var pool = recognizable
        var left = stranded.filter(\.isRecognizable)
        var paired: [CGWindowID: ParkedWindow] = [:]

        func take(_ wants: [ParkedWindow], from haves: [Candidate]) {
            guard wants.count == haves.count, !wants.isEmpty else { return }
            let orderedWants = wants.sorted {
                ($0.frame.minX, $0.frame.minY, $0.title) < ($1.frame.minX, $1.frame.minY, $1.title)
            }
            let orderedHaves = haves.sorted { $0.id < $1.id }
            for (record, window) in zip(orderedWants, orderedHaves) {
                paired[window.id] = record
                pool.removeAll { $0.id == window.id }
                if let index = left.firstIndex(of: record) { left.remove(at: index) }
            }
        }

        for key in Set(left.map { identity($0, title: true) }) {
            take(left.filter { identity($0, title: true) == key },
                 from: pool.filter { identity($0, title: true) == key })
        }
        for key in Set(left.map { identity($0, title: false) }) {
            let wants = left.filter { identity($0, title: false) == key }
            let haves = pool.filter { identity($0, title: false) == key }
            guard wants.count == 1, haves.count == 1 else { continue }
            take(wants, from: haves)
        }
        return paired
    }

    /// Whether `frame` is sitting on a display's park position. The y
    /// slack is the title-bar clamp: the corner we ask for and the corner
    /// AppKit actually keeps are a few dozen points apart, and a window
    /// someone placed by hand is not.
    public static func isParkedCorner(_ frame: CGRect, on displays: [CGRect]) -> Bool {
        guard frame.isOnAScreensScale else { return false }
        for display in displays {
            let park = parkPosition(on: display)
            if abs(frame.minX - park.x) <= 4, abs(frame.minY - park.y) <= 80 { return true }
        }
        return false
    }

    private static func identity(_ window: ParkedWindow, title: Bool) -> String {
        appKey(window.bundleID, window.appName) + (title ? "\t\(window.title)" : "")
    }

    private static func identity(_ window: Candidate, title: Bool) -> String {
        appKey(window.bundleID, window.appName) + (title ? "\t\(window.title)" : "")
    }

    private static func appKey(_ bundleID: String?, _ appName: String) -> String {
        if let bundleID, !bundleID.isEmpty { return "b:\(bundleID.lowercased())" }
        return "n:\(appName.lowercased())"
    }
}

extension ParkingLot.Candidate {
    fileprivate var isRecognizable: Bool {
        if let bundleID, !bundleID.isEmpty { return true }
        return !appName.isEmpty
    }
}
