import Foundation
import MLX
import Synchronization

/// The one limit on MLX's buffer cache in this process.
///
/// MLX keeps freed GPU buffers for reuse, and left to itself keeps nearly as
/// much as the Mac has: 1.5 times the GPU's recommended working set, capped
/// at 95% of memory. Measured 2026-11-05 on 25 to 80 real questions, the
/// cache reached 347 MB on Gemma and 1.3 GB on Qwen3.6, and at 64 MB neither
/// answered more slowly. The ear settled 1.3 GB lower over fifteen phrases,
/// with the same words. The buffers a model is using are not cache and this
/// does not touch them: Qwen3.6's weights are 18.7 GB whatever is set here.
public enum MLXCap {
    public static let bytes = 64 << 20

    private static let applied = Mutex(false)

    /// Before a model loads, once. Not at launch: the first word to MLX
    /// builds its Metal device, and a Mac that never loads a model should
    /// not pay for one.
    public static func apply() {
        applied.withLock { applied in
            guard !applied else { return }
            Memory.cacheLimit = bytes
            applied = true
        }
    }

    /// What MLX holds now, in MB, or nil when no model has loaded in this
    /// run: asking would build the device for nothing. Counters only, so
    /// they need no turn on the GPU's lane.
    public static func reading() -> (activeMB: Int, cacheMB: Int)? {
        guard applied.withLock({ $0 }) else { return nil }
        return (Memory.activeMemory >> 20, Memory.cacheMemory >> 20)
    }
}
