import Foundation
import StoicStore

extension Log {
    /// Runs `body`. When it throws, the failure is logged as a warning that
    /// names what was being done and carries the error, and the answer is nil:
    /// the shape of `try?`, with the story kept.
    ///
    /// For work whose failure the caller carries on from (a best-effort write,
    /// a cleanup) but which somebody reading the log later must be able to find.
    /// A failure that is the expected answer (a file that is not there) is not a
    /// failure to tell: use `attemptUnlessAbsent` for removals, or a `do`/`catch`
    /// that names the case.
    @discardableResult
    public static func attempt<T>(
        _ doing: String, _ fields: KeyValuePairs<String, Any> = [:], _ body: () throws -> T
    ) -> T? {
        do {
            return try body()
        } catch {
            failed(doing, fields, error)
            return nil
        }
    }

    /// `attempt` for work that waits.
    @discardableResult
    public static func attempt<T>(
        _ doing: String, _ fields: KeyValuePairs<String, Any> = [:],
        _ body: nonisolated(nonsending) () async throws -> T
    ) async -> T? {
        do {
            return try await body()
        } catch {
            failed(doing, fields, error)
            return nil
        }
    }

    /// For a removal, which is done when the thing is not there: absence is
    /// the goal, so it is not a failure and is not logged. Any other failure
    /// (a permission, a busy volume) leaves the thing behind and is logged.
    public static func attemptUnlessAbsent(
        _ doing: String, _ fields: KeyValuePairs<String, Any> = [:], _ body: () throws -> Void
    ) {
        do {
            try body()
        } catch where isAbsence(error) {
            return
        } catch {
            failed(doing, fields, error)
        }
    }

    /// Whether `error` says only that the path is not there.
    static func isAbsence(_ error: any Error) -> Bool {
        if let store = error as? StoreError { return store.kind == .notFound }
        if let cocoa = error as? CocoaError { return cocoa.code == .fileNoSuchFile || cocoa.code == .fileReadNoSuchFile }
        if let posix = error as? POSIXError { return posix.code == .ENOENT }
        return false
    }

    private static func failed(_ doing: String, _ fields: KeyValuePairs<String, Any>, _ error: any Error) {
        warning(doing, fields: Array(fields) + [(key: "error", value: "\(error)")])
    }
}
