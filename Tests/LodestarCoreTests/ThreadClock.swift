import Foundation

/// The CPU time the calling thread has spent, in seconds. A speed limit
/// measured on the wall clock fails whenever the machine is busy (other
/// shards, a browser, Spotlight after a restart); the thread's own CPU time
/// is what the code cost, and a change of order still shows in it.
enum ThreadClock {
    static func now() -> TimeInterval {
        var spec = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spec)
        return TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1e9
    }

    /// How long `work` kept this thread busy.
    static func measure<T>(_ work: () throws -> T) rethrows -> (T, TimeInterval) {
        let started = now()
        let result = try work()
        return (result, now() - started)
    }
}
