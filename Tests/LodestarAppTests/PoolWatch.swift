import Foundation
import Synchronization
import XCTest

/// Swift's cooperative pool, watched for the whole test run.
///
/// A task handed to the pool runs only when one of its threads is free, and
/// the pool is as wide as the machine has cores: six in the virtual Mac, three
/// or four on a hosted runner. Code that blocks a pool thread (a semaphore, a
/// sleep, a synchronous wait inside an async function) costs nothing on a desk
/// with ten cores and stalls every task in the process on a small one, and the
/// test that fails is whichever happened to need the pool next, not the one
/// that blocked it: it says only that something "never settled".
///
/// The pool's width is counted for each priority apart: tasks made on the
/// main thread run among the user-initiated ones, a detached task among the
/// default ones, and one set can be starved while another runs freely.
///
/// So a timer on a queue of Dispatch's own, which the pool cannot hold up,
/// hands the pool a task that does nothing once a second at each priority.
/// If one has not run in `patience`, the pool is starved at that priority:
/// the process is sampled, once,
/// while it still is, and the file says what every thread was doing. The
/// sample lands beside the shard logs, where a failed run's results are kept
/// (`.build/test-shards/pool-starved-<pid>.txt`), and a line in the log names
/// the test that was running.
enum PoolWatch {
    /// How long a task that does nothing may wait for a thread. Long enough
    /// that a loaded machine does not trip it, far short of the minute a
    /// scenario waits before it gives up.
    static let patience: TimeInterval = 8

    /// The priorities tasks are made at here: on the main thread, by default
    /// and detached, and for work that can wait.
    private static let priorities: [(name: String, priority: TaskPriority)] = [
        ("user-initiated", .userInitiated), ("medium", .medium), ("utility", .utility), ("background", .background),
    ]

    private struct State {
        /// When the task asked of each priority was asked, until it runs.
        var askedAt: [String: Date] = [:]
        var sampled = false
        var running = ""
    }

    private static let state = Mutex(State())
    private static let queue = DispatchQueue(label: "lodestar.tests.pool-watch", qos: .userInteractive)
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var observer: Observer?

    static func install() {
        queue.async {
            guard timer == nil else { return }
            let made = DispatchSource.makeTimerSource(queue: queue)
            made.schedule(deadline: .now() + 1, repeating: 1)
            made.setEventHandler { beat() }
            made.resume()
            timer = made
        }
        // The observation centre is the main thread's.
        DispatchQueue.main.async {
            guard observer == nil else { return }
            let made = Observer()
            XCTestObservationCenter.shared.addTestObserver(made)
            observer = made
        }
    }

    private static func beat() {
        let now = Date()
        for (name, priority) in priorities {
            let starved: (since: Date, test: String)? = state.withLock { state in
                guard let asked = state.askedAt[name] else { return nil }
                guard now.timeIntervalSince(asked) >= patience, !state.sampled else { return nil }
                state.sampled = true
                return (asked, state.running)
            }
            if let starved { sample(priority: name, since: starved.since, test: starved.test) }
            // Asked only when the one before has answered, so a starved pool
            // is not handed a queue of these.
            let ask = state.withLock { state -> Bool in
                guard state.askedAt[name] == nil else { return false }
                state.askedAt[name] = now
                return true
            }
            if ask { Task(priority: priority) { state.withLock { $0.askedAt[name] = nil } } }
        }
    }

    private static func sample(priority: String, since: Date, test: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-shards", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("pool-starved-\(pid).txt")
        let waited = Int(Date().timeIntervalSince(since))
        let line = "POOL-STARVED: a \(priority) task waited \(waited) s for a thread of the cooperative pool"
            + " during \(test.isEmpty ? "no test" : test); every thread's stack is in \(file.path)\n"
        FileHandle.standardError.write(Data(line.utf8))
        let sampler = Process()
        sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sampler.arguments = ["\(pid)", "2", "-file", file.path]
        sampler.standardOutput = FileHandle.nullDevice
        sampler.standardError = FileHandle.nullDevice
        try? sampler.run()
    }

    private final class Observer: NSObject, XCTestObservation {
        func testCaseWillStart(_ testCase: XCTestCase) {
            let name = testCase.name
            PoolWatch.state.withLock { $0.running = name }
        }
    }
}

// A constructor in the bundle's own image, like LeakGuard's: it runs when
// xctest loads the bundle.
@section("__DATA,__mod_init_func")
@used
private let installPoolWatch: @convention(c) () -> Void = { PoolWatch.install() }
