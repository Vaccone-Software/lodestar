import AppKit
import LodestarCore

/// What the engine holds its collaborators by.
///
/// The engine turns the grammar's effects into calls on the window world
/// and the bars, and those calls are the seam between a keystroke and a
/// window moving. `Actions` and the three bar controllers are the app's
/// only implementations; the scenario harness supplies the others, so the
/// real engine, glass, and coach can run against a world that records
/// what it was asked and never touches a window. Nothing here changes
/// what the app does — it names what the engine was already asking for.
protocol EngineActions: AnyObject {
    func focusedAppInfo() -> (pid: pid_t, name: String)?
    func summon(_ target: GraphTarget, beside: Bool, via route: Observations.Route)
    /// The next placement is a chord's later letter: its undo rides the
    /// phrase's first step.
    func joinNextPlacement()
    func maximizeFocused(beside: Bool)
    func flipOrientation()
    func undoLayout()
    func redoLayout()
    func indexJump(_ digit: Int)
    func reorderFocused(toDigit digit: Int)
    func moveFocusedDisplay(direction: Int, beside: Bool)
    func graphGuideRows(_ node: GraphNode) -> [GuideRow]
    func graphCheatRows(_ node: GraphNode, prefix: [String]) -> [GuideRow]
    func breathGuide(prefix: String) -> [GuideRow]
    func indexBadgeItems() -> [(index: Int, frame: CGRect)]
    func breathChain(_ letters: [String]) -> ChainStep
    func bindBreath(_ letters: [String]) -> ChainStep
    func deleteBreathStep(_ letters: [String]) -> ChainStep
    func updateLatestBreath() -> ChainStep
}

extension Actions: EngineActions {}

/// A bar the engine can raise, lower, and ask about.
protocol BarSurface: AnyObject {
    var isVisible: Bool { get }
    func show()
    func hide()
}

/// The launcher, which also chooses among one app's windows.
protocol SearcherSurface: BarSurface {
    func showWindowChooser(pid: pid_t, appName: String)
}

/// Ask, which reads the config afresh at every showing.
protocol WebBarSurface: BarSurface {
    var config: Config { get set }
}

extension SearcherController: SearcherSurface {}
extension WebBarController: WebBarSurface {}
extension CommandsBarController: BarSurface {}
