import Stoic
import StoicHTTP
import StoicTesting
import Synchronization
import Testing
import XCTest
@testable import LodestarCore

/// The feed fetch as a Stoic operation over `HTTPClient`: what it retries,
/// for how long, what it refuses to read, and what it says when it gives up.
/// The transport is scripted and the clock is the simulation's, so a
/// quarter-hour of waiting takes no time.
final class UpdateFeedTests: XCTestCase {
    private typealias Step = ScriptedTransport.Step

    private static let feedURL = URL(string: "https://feed.test/releases")!

    /// The instant the pinned wall clock reads: 2026-11-09 12:00:00 UTC, a
    /// Monday, which is what the HTTP dates below are counted from.
    private static let now = Date(timeIntervalSince1970: 1_794_225_600)

    /// A transport that plays a script, counts what reached it, and can begin
    /// with a failure the way the system hands one back: an `NSError` of its
    /// domain, which is what a real `URLSession` throws.
    private final class Rig: HTTPTransport, Sendable {
        let scripted = ScriptedTransport()
        private let nsErrorFirst: Int?
        private let calls = Mutex(0)

        init(nsErrorFirst: Int? = nil) { self.nsErrorFirst = nsErrorFirst }

        var requests: Int { calls.withLock { $0 } }

        func send(_ request: HTTPRequest, maxResponseBytes: Int) async throws -> HTTPResponse {
            let index = calls.withLock { n -> Int in defer { n += 1 }; return n }
            if index == 0, let code = nsErrorFirst { throw NSError(domain: NSURLErrorDomain, code: code) }
            return try await scripted.send(request, maxResponseBytes: maxResponseBytes)
        }
    }

    private struct Outcome: Sendable {
        var data: Data?
        var problem: String?
        var requests: Int
        var elapsed: Duration
        var sent: [HTTPRequest]
    }

    /// One fetch at `urgency` against `steps`, on virtual time. `others` are
    /// further routes (where a redirect leads).
    private func fetch(_ steps: [Step], urgency: Urgency = .background, url: URL = feedURL,
                       others: [(URL, [Step])] = [], nsErrorFirst: Int? = nil) async throws -> Outcome {
        // Uniform, without early timers: what is measured is how long the
        // operation waits, and a schedule that lets virtual time pass while a
        // woken task has not run yet would put its own time in the answer.
        try await simulate(schedule: .uniform) { context in
            let rig = Rig(nsErrorFirst: nsErrorFirst)
            rig.scripted.on(.get(url), respond: steps)
            for (other, otherSteps) in others { rig.scripted.on(.get(other), respond: otherSteps) }
            let client = UpdateFeed.client(transport: rig, wallClock: { UpdateFeedTests.now })
            var outcome = Outcome(data: nil, problem: nil, requests: 0, elapsed: .zero, sent: [])
            do {
                outcome.data = try await withUrgency(urgency) {
                    try await UpdateFeed.data(from: url, client: client)
                }
            } catch {
                outcome.problem = UpdateFeed.problem(error)
            }
            outcome.requests = rig.requests
            outcome.elapsed = context.clock.now.offset
            outcome.sent = rig.scripted.requests
            return outcome
        }.value
    }

    private static let feed = Step.status(200, body: "feed")

    // MARK: - What it has always done

    func testAnAnswerIsTheFeedAndCostsOneRequest() async throws {
        let outcome = try await fetch([Self.feed])
        XCTAssertEqual(outcome.data, Data("feed".utf8))
        XCTAssertEqual(outcome.requests, 1)
        XCTAssertEqual(outcome.elapsed, .zero)
    }

    func testAServerThatIsBusyIsAskedAgainAfterABackoff() async throws {
        let outcome = try await fetch([.status(503), Self.feed])
        XCTAssertEqual(outcome.data, Data("feed".utf8))
        XCTAssertEqual(outcome.requests, 2)
        XCTAssertGreaterThan(outcome.elapsed, .zero, "it waited, on the clock, rather than asking at once")
        XCTAssertLessThan(outcome.elapsed, .seconds(2))
    }

    func testARateLimitIsNotAskedAgainInSecondsWhateverTheUrgency() async throws {
        for urgency in [Urgency.background, .userInitiated] {
            for status in [403, 429] {
                let outcome = try await fetch([.status(status), Self.feed], urgency: urgency)
                XCTAssertNil(outcome.data, "\(status) at \(urgency)")
                XCTAssertEqual(outcome.requests, 1, "\(status) at \(urgency)")
                XCTAssertEqual(outcome.problem, "HTTP \(status), GitHub's rate limit")
            }
        }
    }

    func testARetryAfterIsWaitedOutOnTheClock() async throws {
        let outcome = try await fetch([.status(429, headers: ["Retry-After": "120"]), Self.feed])
        XCTAssertEqual(outcome.data, Data("feed".utf8))
        XCTAssertEqual(outcome.requests, 2)
        XCTAssertGreaterThanOrEqual(outcome.elapsed, .seconds(120), "the server's word, not the schedule's")
    }

    func testAnAnswerThatIsNotFoundIsAFailureAtOnceWithItsStatus() async throws {
        let outcome = try await fetch([.status(404)])
        XCTAssertEqual(outcome.requests, 1)
        XCTAssertEqual(outcome.problem, "HTTP 404")
    }

    func testAConnectionThatKeepsFailingGivesUpAfterTheAttemptsItsUrgencyAllows() async throws {
        for urgency in [Urgency.userInitiated, .background] {
            let attempts = UpdateFeed.fetch.policy(at: urgency).schedule.maximumAttempts
            let outcome = try await fetch([.failure(.timedOut)], urgency: urgency)
            XCTAssertEqual(outcome.requests, attempts, "\(urgency)")
            XCTAssertTrue(outcome.problem?.contains("NSURLErrorDomain") == true, "the transport's own error: \(outcome.problem ?? "nil")")
        }
        XCTAssertLessThan(UpdateFeed.fetch.policy(at: .userInitiated).schedule.maximumAttempts,
                          UpdateFeed.fetch.policy(at: .background).schedule.maximumAttempts,
                          "a pressed menu item gives up sooner than the daily check")
        XCTAssertEqual(UpdateFeed.fetch.policy(at: .userInitiated).deadline, .seconds(30),
                       "the menu item is held to the thirty seconds the single request had")
    }

    /// Erased to `any Error`, which is all `URLSession` hands back, a
    /// URLError is an NSError on this platform. Stoic reads it as the Swift
    /// value it stands for, so StoicFoundation's table applies to it.
    func testARefusedCertificateIsNotAskedAgainHoweverItArrives() async throws {
        let direct = try await fetch([.failure(.serverCertificateUntrusted), Self.feed])
        XCTAssertNil(direct.data)
        XCTAssertEqual(direct.requests, 1)
        let bridged = try await fetch([Self.feed], nsErrorFirst: NSURLErrorServerCertificateUntrusted)
        XCTAssertNil(bridged.data)
        XCTAssertEqual(bridged.requests, 1, "an NSError of the URL domain is the same refusal")
    }

    func testATimeoutIsAskedAgainAndTheErrorIsPrintedAsThrown() async throws {
        let again = try await fetch([.failure(.timedOut), Self.feed])
        XCTAssertEqual(again.data, Data("feed".utf8))
        XCTAssertEqual(again.requests, 2)
        let refused = try await fetch([.failure(.serverCertificateUntrusted)])
        XCTAssertEqual(refused.problem, String(describing: URLError(.serverCertificateUntrusted) as any Error))
    }

    func testALostConnectionIsAskedAgainHoweverItArrives() async throws {
        let outcome = try await fetch([Self.feed], nsErrorFirst: NSURLErrorNetworkConnectionLost)
        XCTAssertEqual(outcome.data, Data("feed".utf8))
        XCTAssertEqual(outcome.requests, 2)
    }

    func testNoNetworkIsAskedAgainUntilTheAttemptsRunOut() async throws {
        let again = try await fetch([.failure(.notConnectedToInternet), Self.feed])
        XCTAssertEqual(again.data, Data("feed".utf8))
        XCTAssertEqual(again.requests, 2)
        let attempts = UpdateFeed.fetch.policy(at: .background).schedule.maximumAttempts
        let offline = try await fetch([.failure(.notConnectedToInternet)])
        XCTAssertNil(offline.data)
        XCTAssertEqual(offline.requests, attempts)
        XCTAssertEqual(offline.problem, String(describing: URLError(.notConnectedToInternet) as any Error))
    }

    // MARK: - Every status, as the hand-written reading had it

    /// What the hand-written fetch made of each status, kept as it was: the
    /// retried ones, on the schedule, and the ones that are final. A
    /// `Retry-After` in seconds is waited for on a 429 and a 503 and is
    /// read by nothing else.
    func testEveryStatusIsFinalOrRetriedAsItWas() async throws {
        let retried: Set<Int> = [408, 500, 502, 503, 504]
        let statuses = [300, 301, 304, 400, 401, 403, 404, 408, 410, 418, 429, 451, 500, 501, 502, 503, 504, 505]
        for urgency in [Urgency.background, .userInitiated] {
            for status in statuses {
                let outcome = try await fetch([.status(status), Self.feed], urgency: urgency)
                if retried.contains(status) {
                    XCTAssertEqual(outcome.data, Data("feed".utf8), "\(status) at \(urgency) is asked again")
                    XCTAssertEqual(outcome.requests, 2, "\(status) at \(urgency)")
                    XCTAssertLessThan(outcome.elapsed, .seconds(2), "\(status) on the schedule's backoff")
                } else {
                    XCTAssertNil(outcome.data, "\(status) at \(urgency) is final")
                    XCTAssertEqual(outcome.requests, 1, "\(status) at \(urgency)")
                    XCTAssertEqual(outcome.problem, Updater.httpProblem(status: status), "\(status)")
                }
            }
        }
    }

    func testARetryAfterInSecondsIsReadForA429AndA503AndNothingElse() async throws {
        let waits: Set<Int> = [429, 503]
        let retried: Set<Int> = [408, 429, 500, 502, 503, 504]
        for status in [400, 403, 404, 408, 429, 500, 502, 503, 504] {
            let outcome = try await fetch([.status(status, headers: ["Retry-After": "30"]), Self.feed])
            if retried.contains(status) {
                XCTAssertEqual(outcome.requests, 2, "\(status)")
                if waits.contains(status) {
                    XCTAssertGreaterThanOrEqual(outcome.elapsed, .seconds(30), "\(status) waits as told")
                } else {
                    XCTAssertLessThan(outcome.elapsed, .seconds(2), "\(status) is asked again on the schedule")
                }
            } else {
                XCTAssertEqual(outcome.requests, 1, "\(status) is final whatever the server says")
            }
        }
    }

    // MARK: - The rate limit GitHub answers with

    /// GitHub's limit is a 403, and without a `Retry-After` it is final: the
    /// next check is the retry. StoicHTTP's own reading of a 403 agrees, and
    /// is pinned here so that a library that changed it would be heard.
    func testA403WithoutARetryAfterIsFinalAndSaysItIsTheRateLimit() async throws {
        for urgency in [Urgency.background, .userInitiated] {
            let outcome = try await fetch([.status(403, body: #"{"message":"API rate limit exceeded"}"#), Self.feed],
                                          urgency: urgency)
            XCTAssertNil(outcome.data, "\(urgency)")
            XCTAssertEqual(outcome.requests, 1, "\(urgency)")
            XCTAssertEqual(outcome.problem, "HTTP 403, GitHub's rate limit")
        }
        XCTAssertEqual(HTTPError.status(403, excerpt: "", retryAfter: nil, attempts: 1).retryDecision, .stop)
    }

    func testA403EvenWithARetryAfterIsFinal() async throws {
        let outcome = try await fetch([.status(403, headers: ["Retry-After": "30"]), Self.feed])
        XCTAssertNil(outcome.data)
        XCTAssertEqual(outcome.requests, 1)
    }

    /// Why the updater reads a status itself: `HTTPError` retries a 429 that
    /// names no time, which is the limit the updater leaves to the next check.
    func testTheLibrariesOwnReadingOfABare429IsNotTheUpdaters() async throws {
        XCTAssertEqual(HTTPError.status(429, excerpt: "", retryAfter: nil, attempts: 1).retryDecision, .retry)
        let outcome = try await fetch([.status(429), Self.feed])
        XCTAssertEqual(outcome.requests, 1)
    }

    func testARetryAfterThatIsAnHTTPDateIsWaitedOutOnA429AndA503() async throws {
        let dates = ["Mon, 09 Nov 2026 12:02:00 GMT",          // IMF-fixdate
                     "Monday, 09-Nov-26 12:02:00 GMT",         // RFC 850
                     "Mon Nov  9 12:02:00 2026"]               // asctime
        for status in [429, 503] {
            for date in dates {
                let outcome = try await fetch([.status(status, headers: ["Retry-After": date]), Self.feed])
                XCTAssertEqual(outcome.data, Data("feed".utf8), "\(status) \(date)")
                XCTAssertEqual(outcome.requests, 2, "\(status) \(date)")
                XCTAssertGreaterThanOrEqual(outcome.elapsed, .seconds(120), "\(status) \(date): the server's word")
                XCTAssertLessThan(outcome.elapsed, .seconds(122), "\(status) \(date): and no more")
            }
        }
    }

    func testARetryAfterThatCannotBeReadIsAsGoodAsNone() async throws {
        let rateLimited = try await fetch([.status(429, headers: ["Retry-After": "soon"]), Self.feed])
        XCTAssertEqual(rateLimited.requests, 1, "a 429 that names no time we can read is final")
        let busy = try await fetch([.status(503, headers: ["Retry-After": "soon"]), Self.feed])
        XCTAssertEqual(busy.requests, 2)
        XCTAssertLessThan(busy.elapsed, .seconds(2), "and a 503 is asked again on the schedule")
    }

    // MARK: - What it will not read

    func testAnAnswerLargerThanTheLimitIsRefusedAndNotAskedAgain() async throws {
        let outcome = try await fetch([.oversized(UpdateFeed.byteLimit + 1), Self.feed])
        XCTAssertNil(outcome.data)
        XCTAssertEqual(outcome.requests, 1, "a body that is too large is as large the next time")
        XCTAssertTrue(outcome.problem?.contains("larger than \(UpdateFeed.byteLimit) bytes") == true,
                      outcome.problem ?? "nil")
    }

    func testAnAnswerThatNeverEndsIsRefusedAtTheLimit() async throws {
        let outcome = try await fetch([.oversized(2 << 30), Self.feed])
        XCTAssertNil(outcome.data)
        XCTAssertEqual(outcome.requests, 1)
    }

    func testAnAnswerAsLargeAsTheLimitIsRead() async throws {
        let body = [UInt8](repeating: UInt8(ascii: "x"), count: UpdateFeed.byteLimit)
        let outcome = try await fetch([.bytes(body)])
        XCTAssertEqual(outcome.data?.count, UpdateFeed.byteLimit)
    }

    func testTheLimitHoldsTheLargestListGitHubCanSend() {
        // Ten releases, each with the most notes GitHub keeps (125,000
        // characters) and 20 KB of author, assets and URLs.
        XCTAssertGreaterThan(UpdateFeed.byteLimit, 10 * (125_000 + 20_000))
    }

    // MARK: - Where it will go

    func testARedirectFromHTTPSToHTTPIsRefusedAndNothingIsSentInTheClear() async throws {
        // A route is a host and a path, not a scheme: another path keeps the
        // two apart.
        let plain = URL(string: "http://feed.test/in-the-clear/releases")!
        let outcome = try await fetch([.status(302, headers: ["Location": plain.absoluteString])],
                                      others: [(plain, [Self.feed])])
        XCTAssertNil(outcome.data)
        XCTAssertEqual(outcome.requests, 1, "the http address was never asked")
        XCTAssertTrue(outcome.problem?.contains("redirect not followed (downgrade)") == true, outcome.problem ?? "nil")
        XCTAssertFalse(outcome.sent.contains { $0.url?.scheme == "http" })
    }

    func testARedirectWithinHTTPSIsFollowedWithTheHeaderThatNamesUs() async throws {
        let moved = URL(string: "https://elsewhere.test/releases")!
        let outcome = try await fetch([.status(301, headers: ["Location": moved.absoluteString])],
                                      others: [(moved, [Self.feed])])
        XCTAssertEqual(outcome.data, Data("feed".utf8))
        XCTAssertEqual(outcome.requests, 2)
        XCTAssertEqual(outcome.sent.last?.url, moved)
        XCTAssertEqual(outcome.sent.last?.headers["User-Agent"], "lodestar/\(Lodestar.version)")
    }

    func testTheRequestSaysWhoIsAsking() async throws {
        let outcome = try await fetch([Self.feed])
        XCTAssertEqual(outcome.sent.first?.headers["User-Agent"], "lodestar/\(Lodestar.version)")
        XCTAssertEqual(outcome.sent.first?.method, .get)
    }

    // MARK: - How long it will wait

    /// An attempt that hears nothing is cut at the thirty seconds a request
    /// has always had, at the daily check's urgency (whose own attempt timer
    /// is a minute) and at the menu item's (whose is ten seconds), and asked
    /// again.
    func testAnAttemptThatHearsNothingIsCutAtThirtySecondsAtMost() async throws {
        let daily = try await fetch([.hang, Self.feed], urgency: .background)
        XCTAssertEqual(daily.data, Data("feed".utf8))
        XCTAssertEqual(daily.requests, 2)
        XCTAssertGreaterThanOrEqual(daily.elapsed, .seconds(30))
        XCTAssertLessThan(daily.elapsed, .seconds(32), "cut at thirty seconds, not at the operation's minute")
        let pressed = try await fetch([.hang, Self.feed], urgency: .userInitiated)
        XCTAssertEqual(pressed.requests, 2)
        XCTAssertGreaterThanOrEqual(pressed.elapsed, .seconds(10))
        XCTAssertLessThan(pressed.elapsed, .seconds(12), "the menu item's own ten seconds are the shorter")
    }

    func testTheSessionIsBoundedAsItWas() {
        let configuration = UpdateFeed.sessionConfiguration()
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 180)
        XCTAssertLessThanOrEqual(UpdateFeed.attemptTimeout, .seconds(30))
    }

    // MARK: - What is made of what was fetched

    private func stable(tag: String = "v1.47.1", version: String = "1.47.1", zipURL: String? = nil,
                        digest: String? = nil) -> String {
        let name = "lodestar-\(version).zip"
        let url = zipURL ?? "https://github.com/Vaccone-Software/lodestar/releases/download/\(tag)/\(name)"
        let digestField = digest.map { #", "digest": "\#($0)""# } ?? ""
        return #"{"tag": "\#(tag)", "version": "\#(version)", "zip": {"name": "\#(name)", "url": "\#(url)"\#(digestField)}, "preview": {"tag": "v1.48.0"}}"#
    }

    func testAMalformedAnswerIsTheBytesAndNoReleaseAsItWas() async throws {
        for body in ["not json", "", "<html>Service Unavailable</html>", "{}", "[]", #"{"message": "rate limited"}"#,
                     #"{"tag": "v1.47.1"}"#, "[{\"tag_name\": \"nightly\", \"assets\": []}]"] {
            let outcome = try await fetch([.status(200, body: body)])
            XCTAssertEqual(outcome.data, Data(body.utf8), "a 200 is the feed, whatever it holds: \(body)")
            XCTAssertNil(outcome.problem, body)
            for channel in Updater.Channel.allCases {
                XCTAssertNil(Updater.parse(outcome.data ?? Data(), channel: channel), "\(channel): \(body)")
            }
        }
        let empty = try await fetch([.status(204)])
        XCTAssertEqual(empty.data, Data())
        XCTAssertNil(Updater.parse(empty.data ?? Data(), channel: .stable))
    }

    func testThePointerIsStillBelievedOnlyOnItsOwnTerms() async throws {
        let good = try await fetch([.status(200, body: stable(digest: "sha256:abc123"))])
        let release = Updater.parse(try XCTUnwrap(good.data), channel: .stable)
        XCTAssertEqual(release?.tag, "v1.47.1")
        XCTAssertEqual(release?.zipURL,
                       "https://github.com/Vaccone-Software/lodestar/releases/download/v1.47.1/lodestar-1.47.1.zip")
        XCTAssertEqual(release?.zipDigest, "sha256:abc123", "the digest the site names rides along")
        for bad in [stable(zipURL: "https://example.com/lodestar-1.47.1.zip"),
                    stable(zipURL: "http://github.com/Vaccone-Software/lodestar/releases/download/v1.47.1/lodestar-1.47.1.zip"),
                    stable(tag: "v1.47.2"),
                    stable(version: "1.47.x")] {
            let outcome = try await fetch([.status(200, body: bad)])
            XCTAssertNil(Updater.parse(try XCTUnwrap(outcome.data), channel: .stable), bad)
        }
    }

    func testThePreviewListIsStillReadFromWhatWasFetched() async throws {
        let list = """
        [{"tag_name": "v1.48.0", "draft": false, "assets": [
            {"name": "lodestar-1.48.0.zip", "browser_download_url": "https://example.com/48.zip",
             "digest": "sha256:def456"}]}]
        """
        let outcome = try await fetch([.json(list)])
        let release = Updater.parse(try XCTUnwrap(outcome.data), channel: .preview)
        XCTAssertEqual(release?.tag, "v1.48.0")
        XCTAssertEqual(release?.zipDigest, "sha256:def456")
    }
}
