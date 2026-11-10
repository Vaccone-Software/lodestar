import Foundation
import Stoic
import StoicFoundation
import StoicHTTP

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
/// which someone pressed and will wait a few seconds for, gives up within
/// about the thirty seconds the single request was given. A failure that
/// still stands after that is left to `UpdateController`'s own timer, which
/// asks again in a quarter of an hour and then an hour: that is a later
/// check, not a retry of this one.
///
/// The request goes through `HTTPClient`, which inside the operation's
/// attempt is the transport and nothing else (the operation is the retry
/// layer), and which holds what a bare `URLSession` did not: a limit on how
/// much of an answer is read (`byteLimit`), a redirect from `https` to `http`
/// refused, and a `Retry-After` read in both of its forms.
public enum UpdateFeed {
    static let fetch = Backend.updateFeed.readOnly("fetch")

    /// The most of an answer that is read. The stable pointer is under a
    /// kilobyte, and the preview channel's list of ten releases is about
    /// 150 to 200 KB as GitHub serves it (the notes of the ten newest are
    /// 40 KB of that, the rest each release's author, assets and URLs).
    /// GitHub caps a release's notes at 125,000 characters, so the largest
    /// list it can ever send is some 1.5 MB: four mebibytes is that with
    /// room to spare, and still stops an answer that never ends from being
    /// held in memory. Too small a limit would be worse than none: a build
    /// that could not read the list could never be told of its own fix.
    public static let byteLimit = 4 << 20

    /// How long one request may take, the same thirty seconds it was given
    /// when it was a `URLRequest`. The operation's own attempt timer is
    /// shorter at the menu item's urgency (ten seconds) and longer for the
    /// daily check (a minute), so this is the bound that holds at every
    /// urgency: a request cut here is a timeout, and is asked again.
    static let attemptTimeout = Duration.seconds(30)

    /// The session the feed's requests go through, bounded: `URLSession.shared`
    /// would let a trickling answer hold the update in `.checking` for days,
    /// refusing every later check. Thirty seconds of silence is a cut, and a
    /// hundred and eighty is the most the whole answer may take, as they
    /// have always been. (The zip is fetched by `UpdateDownload`, bounded by
    /// a deadline of its own.)
    public static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        return configuration
    }

    /// The client the feed is read through. One try for each request (the
    /// operation is the retry layer) and the limit above on the answer.
    ///
    /// - Parameters:
    ///   - transport: How the request reaches the network; a scripted one
    ///     in tests.
    ///
    /// An HTTP-date `Retry-After` is counted from the ambient wall clock
    /// (`Moment.now`), which a test pins with `withAmbient`.
    public static func client(transport: (any HTTPTransport)? = nil) -> HTTPClient {
        var policy = HTTPPolicy.singleAttempt
        policy.attemptTimeout = attemptTimeout
        policy.maxResponseBytes = byteLimit
        return HTTPClient(
            base: Updater.stableURL, policy: policy,
            transport: transport ?? URLSessionTransport(configuration: sessionConfiguration()),
            label: "update-feed")
    }

    /// The feed's bytes, or the error `perform` gave up with. A transport
    /// failure classifies itself (StoicFoundation: a timeout or a lost
    /// connection is tried again, a refused certificate is not), and so does
    /// `HTTPFailure`, which holds what the updater has always made of a status.
    public static func data(from url: URL, client: HTTPClient) async throws -> Data {
        // The header rides on the request, not the client: the client's own
        // headers go to its base URL alone, and the feed is two hosts.
        let request = HTTPRequest.get(url, headers: ["User-Agent": "lodestar/\(Lodestar.version)"])
        return try await fetch.perform { _ in
            do {
                let response = try await client.send(request, overrides: HTTPOverrides(attemptTimeout: attemptTimeout))
                return Data(response.body)
            } catch HTTPError.status(let status, _, let retryAfter, _, _) {
                throw HTTPFailure(status: status, retryAfter: retryAfter)
            }
        }
    }

    /// What went wrong, in the words the check's log line has always used:
    /// the HTTP status (with GitHub's rate limit named), or the transport
    /// error as it was thrown.
    public static func problem(_ error: any Error) -> String {
        guard let error = error as? OperationError<any Error> else { return describe(error) }
        switch error.stop {
        case .failed(let failure): return problem(failure)
        case .rejected(let rejection): return String(describing: rejection)
        case .cancelled: return "cancelled"
        }
    }

    /// The client's own wording for a failure of the network is a code and a
    /// count of attempts; the log has always had the system's.
    private static func describe(_ error: any Error) -> String {
        switch error {
        case HTTPError.transport(let code, _): String(describing: URLError(code) as any Error)
        case HTTPError.timedOut: String(describing: URLError(.timedOut) as any Error)
        default: String(describing: error)
        }
    }

    /// An HTTP answer that is not an answer: the status, and when to come
    /// back if the server said. A rate limit (403 or 429 from GitHub) with
    /// no `Retry-After` is not tried again in seconds, which is what the
    /// limit is there to stop: the next check is the retry.
    ///
    /// This is the updater's own reading of a status, not `HTTPError`'s:
    /// that one retries a `429` whether or not the server named a time,
    /// where here it is final until it does.
    struct HTTPFailure: Error, Retryable, CustomStringConvertible {
        let status: Int
        let retryAfter: Duration?

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
