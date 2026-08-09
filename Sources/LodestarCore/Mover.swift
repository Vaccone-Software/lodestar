import CoreGraphics

/// The one gate through which lodestar moves windows. Production goes to
/// AX; tests substitute a recorder so layout logic is exercised without a
/// window server.
public protocol WindowMoving: AnyObject {
    @discardableResult func setFrame(_ window: WindowModel.Window, _ frame: CGRect) -> Bool
    @discardableResult func setPosition(_ window: WindowModel.Window, _ point: CGPoint) -> Bool
    func raise(_ window: WindowModel.Window)
}

public final class AXMover: WindowMoving {
    public init() {}

    @discardableResult
    public func setFrame(_ window: WindowModel.Window, _ frame: CGRect) -> Bool {
        AXWindow(element: window.element)?.setFrame(frame) ?? false
    }

    @discardableResult
    public func setPosition(_ window: WindowModel.Window, _ point: CGPoint) -> Bool {
        AXWindow(element: window.element)?.setPosition(point) ?? false
    }

    public func raise(_ window: WindowModel.Window) {
        let ax = AXWindow(element: window.element)
        ax?.makeMain()
        ax?.raise()
    }
}

/// Displays as layout logic sees them — injectable so tests can plug and
/// unplug monitors at will.
public struct DisplayOracle {
    public var ordered: () -> [Displays.DisplayInfo]
    public var visibleFrame: (CGRect) -> CGRect
    public var displayContaining: (CGRect) -> Displays.DisplayInfo?
    public var uuid: (CGDirectDisplayID) -> String?

    public init(ordered: @escaping () -> [Displays.DisplayInfo],
                visibleFrame: @escaping (CGRect) -> CGRect,
                displayContaining: @escaping (CGRect) -> Displays.DisplayInfo?,
                uuid: @escaping (CGDirectDisplayID) -> String?) {
        self.ordered = ordered
        self.visibleFrame = visibleFrame
        self.displayContaining = displayContaining
        self.uuid = uuid
    }

    public static let live = DisplayOracle(
        ordered: Displays.ordered,
        visibleFrame: Displays.visibleFrame(containing:),
        displayContaining: Displays.display(containing:),
        uuid: Displays.uuid(for:)
    )
}

/// What layout logic needs to know about windows.
public protocol WindowQuerying: AnyObject {
    func window(_ id: CGWindowID) -> WindowModel.Window?
    var focusedWindow: WindowModel.Window? { get }
    func refreshFrame(_ id: CGWindowID)
}

extension WindowModel: WindowQuerying {}
