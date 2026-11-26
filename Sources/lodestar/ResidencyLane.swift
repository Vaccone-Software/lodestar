import Synchronization

/// Work on one thing that is loaded and let go, one piece at a time, in the
/// order it was asked: each piece starts once the one before it has ended.
///
/// A `Task` per piece has no order: a release asked before a load could
/// reach the model after it, and one asked while a load was on its way found
/// nothing to let go and left what the load then brought. In a lane a
/// release waits out the load before it, and a load the release.
///
/// Each piece runs in the ambient context it was asked in, off the main
/// thread, as an ordinary `Task` does.
final class ResidencyLane: Sendable {
    private let tail = Mutex<Task<Void, Never>?>(nil)

    func run(priority: TaskPriority? = nil, _ work: @escaping @Sendable () async -> Void) {
        tail.withLock { tail in
            let previous = tail
            tail = Task(priority: priority) {
                await previous?.value
                await work()
            }
        }
    }

    /// Returns once every piece asked so far has ended.
    func settled() async {
        await tail.withLock { $0 }?.value
    }
}
