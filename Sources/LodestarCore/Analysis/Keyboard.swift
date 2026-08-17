import Foundation

/// Physical QWERTY geometry, for pricing what a chain asks of the hand.
/// The coefficients on these features are fitted from the user's own gaps
/// (see `LatencyModel`), never assumed; the geometry only says which keys
/// share a hand, a finger, a row.
public enum Keyboard {
    public struct Key: Equatable {
        public let row: Int
        public let column: Double
        /// 0 left, 1 right.
        public let hand: Int
        /// 0–3 per hand, index finger inward.
        public let finger: Int
    }

    static let layout: [Character: Key] = {
        // Standard QWERTY three rows; columns include the stagger.
        let rows: [(Int, Double, String)] = [
            (0, 0.0, "qwertyuiop"),
            (1, 0.25, "asdfghjkl"),
            (2, 0.75, "zxcvbnm"),
        ]
        // Finger by column for a ten-column row: pinky ring middle index
        // index | index index middle ring pinky.
        let fingers = [3, 2, 1, 0, 0, 0, 0, 1, 2, 3]
        let hands = [0, 0, 0, 0, 0, 1, 1, 1, 1, 1]
        var keys: [Character: Key] = [:]
        for (row, stagger, letters) in rows {
            for (index, letter) in letters.enumerated() {
                keys[letter] = Key(row: row, column: Double(index) + stagger,
                                   hand: hands[min(index, 9)],
                                   finger: fingers[min(index, 9)])
            }
        }
        return keys
    }()

    public static func key(_ letter: String) -> Key? {
        guard let character = letter.lowercased().first else { return nil }
        return layout[character]
    }

    /// The features of moving from one key to the next, in the order
    /// `LatencyModel` expects: same hand, same finger, row distance.
    public static func digraph(_ from: String, _ to: String) -> (sameHand: Double,
                                                                  sameFinger: Double,
                                                                  rowDistance: Double) {
        guard let a = key(from), let b = key(to) else { return (0, 0, 0) }
        return (a.hand == b.hand ? 1 : 0,
                a.hand == b.hand && a.finger == b.finger ? 1 : 0,
                Double(abs(a.row - b.row)))
    }
}
