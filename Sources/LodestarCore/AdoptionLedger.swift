import CoreGraphics
import Foundation

/// Adoption is a transaction. The ledger remembers what each adopted
/// window displaced, so its close can bring the arrangement back — a
/// transient (Finder reveal, one-off dialog window) must not leave a
/// crater. Pure bookkeeping: the caller supplies the world.
public struct AdoptionLedger {
    private var records: [CGWindowID: (display: CGDirectDisplayID, displaced: [CGWindowID])] = [:]

    public init() {}

    public mutating func recordAdoption(of id: CGWindowID, on display: CGDirectDisplayID,
                                        displacing: [CGWindowID]) {
        guard !displacing.isEmpty else { return }
        records[id] = (display, displacing)
    }

    /// On the adopted window's destruction: the displaced members to bring
    /// back, or nil when the world moved on — any layout activity since
    /// the adoption (the display holds something else now) or nothing left
    /// alive to restore.
    public mutating func settle(destroyed id: CGWindowID,
                                layoutNowEmpty: (CGDirectDisplayID) -> Bool,
                                isAlive: (CGWindowID) -> Bool) -> (display: CGDirectDisplayID, restore: [CGWindowID])? {
        guard let record = records.removeValue(forKey: id) else { return nil }
        let survivors = record.displaced.filter(isAlive)
        guard layoutNowEmpty(record.display), !survivors.isEmpty else { return nil }
        return (record.display, survivors)
    }
}

/// A launched app's window arrives asynchronously; intents wait for it.
/// The first live intent matching an arriving window claims it — before
/// adoption ever sees it.
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
