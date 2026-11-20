import Foundation
import Stoic
public import StoicProcess
import Synchronization

/// Another program, run the one way: Stoic's `ChildProcess` (design/33).
/// Every child is in a process group of its own and inherits nothing but
/// its three streams. A stop reaches whatever the child started, and its
/// output is read as it comes, so a chatty child never fills a pipe
/// nobody reads.
public enum Programs {
    /// What a child is given: this process's environment, whole. A
    /// `Command` names its environment rather than inheriting one.
    public static var environment: [String: String] { ProcessEnvironment.current }

    /// A program on a fixed path, its output and errors dropped.
    public static func quiet(_ executable: String, _ arguments: [String]) -> Command {
        Command(executable, arguments, environment: environment, output: .discard, errors: .discard)
    }

    /// Runs `command` to its end, or until `timeout`, blocking the calling
    /// thread, for the callers that have no task to await in: a dispatch
    /// queue's work and the launch path. A timed-out child and everything
    /// it started are stopped before this returns.
    ///
    /// The run happens in a task, and a task started from a queue or a
    /// thread carries no Stoic context, so the events it records
    /// (`process.*`, `deadline.expired`) would reach the unified log alone.
    /// `ambient` is the context they go to: the caller's when none is named.
    ///
    /// `label` names the child in those events: the program's name when nil.
    ///
    /// - Returns: the result, or the error that kept it from starting.
    public static func runBlocking(_ command: Command, timeout: Duration,
                                   keepingLast: Int = 64 * 1024, label: String? = nil,
                                   ambient: Ambient = .current) -> Result<ProcessResult, any Error> {
        let outcome = Mutex<Result<ProcessResult, any Error>?>(nil)
        let finished = DispatchSemaphore(value: 0)
        // The priority is named, because a task started from a queue
        // otherwise takes the queue's, and a run from the utility queue
        // would wait behind every other utility task.
        Task(priority: .medium) {
            let result: Result<ProcessResult, any Error>
            do {
                result = .success(try await withAmbient({ $0 = ambient }) {
                    try await ChildProcess.run(command, timeout: timeout, keepingLast: keepingLast,
                                               options: ChildProcess.Options(label: label))
                })
            } catch {
                result = .failure(error)
            }
            outcome.withLock { $0 = result }
            finished.signal()
        }
        finished.wait()
        return outcome.withLock { $0 } ?? .failure(CancellationError())
    }
}
