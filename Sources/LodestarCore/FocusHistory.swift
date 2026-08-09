import CoreGraphics
import Foundation

/// The attention timeline: every focus change appends here, and back/forward
/// walk it with browser semantics — a fresh navigation while you're back in
/// history truncates the forward branch. Dead windows are skipped when
/// walking; a jump performed BY back/forward moves the cursor instead of
/// recording, so walking never rewrites the history it walks.
public final class FocusHistory {
    public private(set) var entries: [CGWindowID] = []
    public private(set) var cursor: Int = -1
    private var expectedJump: CGWindowID?
    private let capacity: Int

    public init(capacity: Int = 50) {
        self.capacity = capacity
    }

    /// Feed every focus change here.
    public func recordFocus(_ id: CGWindowID) {
        if expectedJump == id {
            // Our own back/forward jump landing — the cursor already points
            // at it; don't truncate, don't append.
            expectedJump = nil
            return
        }
        expectedJump = nil
        if entries.indices.contains(cursor), entries[cursor] == id { return }
        if cursor < entries.count - 1 {
            entries.removeSubrange((cursor + 1)...)
        }
        entries.append(id)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        cursor = entries.count - 1
    }

    /// The previous still-alive destination, moving the cursor to it.
    public func stepBack(isAlive: (CGWindowID) -> Bool) -> CGWindowID? {
        var index = cursor - 1
        while index >= 0 {
            if isAlive(entries[index]) {
                cursor = index
                expectedJump = entries[index]
                return entries[index]
            }
            index -= 1
        }
        return nil
    }

    /// The next still-alive destination toward the present.
    public func stepForward(isAlive: (CGWindowID) -> Bool) -> CGWindowID? {
        var index = cursor + 1
        while index < entries.count {
            if isAlive(entries[index]) {
                cursor = index
                expectedJump = entries[index]
                return entries[index]
            }
            index += 1
        }
        return nil
    }
}
