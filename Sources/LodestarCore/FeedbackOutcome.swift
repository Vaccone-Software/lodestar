import Foundation
import StoicHTTP

/// What one try at delivering a note came to, and what that means for the
/// note. The one place that says it, so the window, the queue and the log
/// cannot disagree.
public enum FeedbackOutcome: Equatable, Sendable {
    /// The site took it and sent it on. The note is done.
    case delivered
    /// The site read the note and will not take it, now or ever (it is
    /// empty, or not JSON). Trying again would be refused the same way, so
    /// the note leaves the queue, and the person is told if they are there.
    case refused
    /// Nothing is known to have happened to it. The note stays queued.
    case unsent(Reason)

    /// Why a note stays queued, in words safe for the log.
    public enum Reason: Equatable, Sendable {
        /// No answer: offline, a dropped connection, a name that did not resolve.
        case network
        /// No answer in the twenty seconds a try has.
        case timeout
        /// An answer that is not a delivery: a 5xx, the site's 503 "not set
        /// up", a 429, a 404 in the middle of a deploy. About the site or
        /// the road to it, never about this note, so it is tried again.
        case status(Int)
        /// Nothing came back that proves a delivery or a refusal: a 200 that
        /// is not the site's own (a captive portal's page, a proxy's), or a
        /// failure of the client's own making.
        case unrecognized

        public var word: String {
            switch self {
            case .network: "network"
            case .timeout: "timeout"
            case .status(let code): "status_\(code)"
            case .unrecognized: "unrecognized"
            }
        }
    }

    /// The word the log carries for the outcome.
    public var word: String {
        switch self {
        case .delivered: "delivered"
        case .refused: "refused"
        case .unsent(let reason): "unsent_\(reason.word)"
        }
    }

    /// A response the client handed back, which is a 2xx. Delivered only
    /// when it is exactly the site's `200 {"ok":true}`: a wifi sign-in page
    /// answers 200 to everything, and a note acknowledged on its word would
    /// be gone for good.
    public static func classify(_ response: HTTPResponse) -> FeedbackOutcome {
        guard response.status == 200 else { return .unsent(.status(response.status)) }
        struct Answer: Decodable { let ok: Bool }
        // Decoded, not read loosely: `{"ok":1}` is not the site's yes.
        let answer = try? JSONDecoder().decode(Answer.self, from: Data(response.body))
        return answer?.ok == true ? .delivered : .unsent(.unrecognized)
    }

    /// An error the client threw. Only a 400 is the note's own fault: it is
    /// what the site answers an unreadable or empty note, and the app does
    /// not send either. Every other failure is the network's or the site's.
    public static func classify(_ error: any Error) -> FeedbackOutcome {
        guard let error = error as? HTTPError else { return .unsent(.network) }
        switch error {
        case .status(400, _, _, _, _): return .refused
        case .status(let code, _, _, _, _): return .unsent(.status(code))
        case .timedOut: return .unsent(.timeout)
        case .transport: return .unsent(.network)
        case .responseTooLarge, .decoding, .rejected, .reauthenticationFailed, .redirectRefused:
            return .unsent(.unrecognized)
        }
    }
}
