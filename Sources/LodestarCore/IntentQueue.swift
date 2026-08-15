import CoreGraphics
import Foundation

/// A launched app's window arrives asynchronously; intents wait for it.
/// The first live intent matching an arriving window claims it; a window
/// nothing was waiting for is left alone.
public struct IntentQueue {
    public struct Intent {
        let matches: (WindowModel.Window) -> Bool
        let action: (WindowModel.Window) -> Void
        let expires: Date

        public init(matches: @escaping (WindowModel.Window) -> Bool,
                    action: @escaping (WindowModel.Window) -> Void,
                    expires: Date) {
            self.matches = matches
            self.action = action
            self.expires = expires
        }
    }

    private var intents: [Intent] = []

    public init() {}

    public mutating func expect(_ intent: Intent) {
        intents.append(intent)
    }

    /// The first live matching intent's action, consumed. Expired intents
    /// are pruned on every claim.
    public mutating func claim(_ window: WindowModel.Window,
                               now: Date = Date()) -> ((WindowModel.Window) -> Void)? {
        intents.removeAll { $0.expires < now }
        guard let index = intents.firstIndex(where: { $0.matches(window) }) else { return nil }
        return intents.remove(at: index).action
    }
}
