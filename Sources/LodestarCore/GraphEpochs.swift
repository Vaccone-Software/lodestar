import Foundation

/// What changed between two graphs, as the epoch log records it.
///
/// Every graph edit is a natural experiment, and the diff is what makes it
/// readable as one: added and retargeted addresses restart their learning
/// curves, a removed one may be a retirement — and a removed address whose
/// target reappears at exactly one new address is a *move*, the fact the
/// universal redirect rests on. A coach accept used to be the only move
/// the product could see, because only the ledger knew where an address
/// went; a hand edit, a ⌘K retarget, or a settings change moved the same
/// binding and left the old gesture a plain miss. Now every road to a
/// binding change writes the same signpost.
///
/// Pure, so the diff a reload runs is the diff the tests run.
public enum GraphEpochs {
    public struct Change: Equatable {
        public let address: [String]
        /// added | removed | retargeted | moved
        public let change: String
        /// The new address, for a move only.
        public let to: [String]?

        public init(address: [String], change: String, to: [String]? = nil) {
            self.address = address
            self.change = change
            self.to = to
        }
    }

    /// `old` and `new` map chain keys to target labels, the way the
    /// config's leaves do. Deterministic order: added and retargeted in
    /// key order, removed in key order, then moves in the order of the
    /// removed address.
    public static func diff(old: [String: String], new: [String: String]) -> [Change] {
        var out: [Change] = []
        for key in new.keys.sorted() {
            if old[key] == nil {
                out.append(Change(address: letters(key), change: "added"))
            } else if old[key] != new[key] {
                out.append(Change(address: letters(key), change: "retargeted"))
            }
        }
        let removed = old.filter { new[$0.key] == nil }
        for key in removed.keys.sorted() {
            out.append(Change(address: letters(key), change: "removed"))
        }
        // A move needs one removed and one added binding of the same
        // target. Two of either is ambiguous, and an ambiguous signpost
        // is worse than a plain miss.
        var addedByLabel: [String: [String]] = [:]
        for (key, label) in new where old[key] == nil {
            addedByLabel[label, default: []].append(key)
        }
        var removedByLabel: [String: [String]] = [:]
        for (key, label) in removed {
            removedByLabel[label, default: []].append(key)
        }
        for key in removed.keys.sorted() {
            let label = removed[key]!
            guard removedByLabel[label]?.count == 1,
                  let to = addedByLabel[label], to.count == 1 else { continue }
            out.append(Change(address: letters(key), change: "moved", to: letters(to[0])))
        }
        return out
    }

    static func letters(_ key: String) -> [String] {
        key.split(separator: " ").map(String.init)
    }
}
