import Foundation
import Stoic
import StoicFoundation

extension Backend {
    /// Where a release is announced: GitHub's releases list for the preview
    /// channel, the site's stable answer for the other. One dependency, as
    /// far as the updater is concerned: both are small JSON documents read
    /// to learn whether a newer build exists.
    static let updateFeed = Backend.remote("update-feed")
}

/// The updater's one question to the network, as a declared operation.
///
/// Reading the feed changes nothing, so it is `readOnly`, and Stoic derives
/// the rest from who is waiting (`withUrgency`): the periodic check, which
/// nobody watches, is patient and waits out an open breaker; the menu item,
/// which someone pressed, gives up quickly. A failure that still stands
/// after that is left to `UpdateController`'s own timer, which asks again
/// in a quarter of an hour and then an hour: that is a later check, not a
/// retry of this one.
///
/// A URLError is wrapped (`Transport`) before it leaves the attempt. Erased
/// to `any Error`, which is all `URLSession` hands back, it is an NSError
/// on this platform, and Stoic's cast of a failure to `Retryable` does not
/// see through that: a refused certificate would be asked for again like a
/// dropped connection.
public enum UpdateFeed {
    static let fetch = Backend.updateFeed.readOnly("fetch")

    /// The feed's bytes, or the error `perform` gave up with. A URLError
    /// classifies itself (StoicFoundation: a timeout or a lost connection is
    /// tried again, a refused certificate is not), and so does `HTTPFailure`.
    public static func data(for request: URLRequest, session: URLSession) async throws -> Data {
        try await data(for: request, load: { try await session.data(for: $0) })
    }

    /// `data(for:session:)` with the transport as a parameter, so a test
    /// scripts the answers and the clock decides how long each wait lasts.
    static func data(for request: URLRequest,
                     load: (URLRequest) async throws -> (Data, URLResponse)) async throws -> Data {
        try await fetch.perform { _ in
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await load(request)
            } catch let error as URLError {
                throw Transport(error: error)
            }
            if let response = response as? HTTPURLResponse, let failure = HTTPFailure(response) { throw failure }
            return data
        }
    }

    /// What went wrong, in the words the check's log line has always used:
    /// the HTTP status (with GitHub's rate limit named), or the transport
    /// error as it was thrown.
    public static func problem(_ error: any Error) -> String {
        if let transport = error as? Transport { return String(describing: transport.error) }
        guard let error = error as? OperationError<any Error> else { return String(describing: error) }
        switch error.stop {
        case .failed(let failure): return problem(failure)
        case .rejected(let rejection): return String(describing: rejection)
        case .cancelled: return "cancelled"
        }
    }

    /// A transport failure, classified by StoicFoundation's table for URLError.
    struct Transport: Error, Retryable {
        let error: URLError
        var retryDecision: RetryDecision { error.retryDecision }
        var neverReachedBackend: Bool { error.neverReachedBackend }
    }

    /// An HTTP answer that is not an answer: the status, and when to come
    /// back if the server said. A rate limit (403 or 429 from GitHub) with
    /// no `Retry-After` is not tried again in seconds, which is what the
    /// limit is there to stop: the next check is the retry.
    struct HTTPFailure: Error, Retryable, CustomStringConvertible {
        let status: Int
        let retryAfter: Duration?

        init?(_ response: HTTPURLResponse) {
            guard Updater.httpProblem(status: response.statusCode) != nil else { return nil }
            status = response.statusCode
            retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .map { .seconds(max(0, $0)) }
        }

        var retryDecision: RetryDecision {
            switch status {
            case 429, 503:
                retryAfter.map { .retryAfter($0) } ?? (status == 503 ? .retry : .stop)
            case 408, 500, 502, 504:
                .retry
            default:
                .stop
            }
        }

        var description: String { Updater.httpProblem(status: status) ?? "HTTP \(status)" }
    }
}
