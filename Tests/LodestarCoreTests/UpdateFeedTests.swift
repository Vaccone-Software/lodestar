import Stoic
import StoicTesting
import Synchronization
import Testing
import XCTest
@testable import LodestarCore

/// The feed fetch as a Stoic operation: what it retries, for how long, and
/// what it says when it gives up. The transport is scripted and the clock
/// is the simulation's, so a quarter-hour of waiting takes no time.
final class UpdateFeedTests: XCTestCase {
    private enum Step {
        case answer(Int, headers: [String: String] = [:])
        case fail(URLError.Code)
        /// The way the system hands a URLError back: an NSError of its domain.
        case failAsNSError(Int)
    }

    /// A transport that plays `steps` in order, then the last one forever,
    /// and counts the requests.
    private final class Script: Sendable {
        private let steps: [Step]
        private let played = Mutex(0)
        init(_ steps: [Step]) { self.steps = steps }
        var requests: Int { played.withLock { $0 } }

        func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
            let index = played.withLock { n -> Int in defer { n += 1 }; return n }
            switch steps[min(index, steps.count - 1)] {
            case .answer(let status, let headers):
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                               headerFields: headers)!
                return (Data("feed".utf8), response)
            case .fail(let code):
                throw URLError(code)
            case .failAsNSError(let code):
                throw NSError(domain: NSURLErrorDomain, code: code)
            }
        }
    }

    private struct Outcome: Sendable {
        var data: Data?
        var problem: String?
        var requests: Int
        var elapsed: Duration
    }

    /// One fetch at `urgency` against `steps`, on virtual time.
    private func fetch(_ steps: [Step], urgency: Urgency) async throws -> Outcome {
        let request = URLRequest(url: URL(string: "https://feed.test/releases")!)
        return try await simulate { context in
            let script = Script(steps)
            var outcome = Outcome(data: nil, problem: nil, requests: 0, elapsed: .zero)
            do {
                outcome.data = try await withUrgency(urgency) {
                    try await UpdateFeed.data(for: request, load: script.load)
                }
            } catch {
                outcome.problem = UpdateFeed.problem(error)
            }
            outcome.requests = script.requests
            outcome.elapsed = context.clock.now.offset
            return outcome
        }.value
    }

    func testAnAnswerIsTheFeedAndCostsOneRequest() async throws {
        let outcome = try await fetch([.answer(200)], urgency: .background)
        XCTAssertEqual(outcome.data, Data("feed".utf8))
        XCTAssertEqual(outcome.requests, 1)
        XCTAssertEqual(outcome.elapsed, .zero)
    }

    func testAServerThatIsBusyIsAskedAgainAfterABackoff() async throws {
        let outcome = try await fetch([.answer(503), .answer(200)], urgency: .background)
        XCTAssertEqual(outcome.data, Data("feed".utf8))
        XCTAssertEqual(outcome.requests, 2)
        XCTAssertGreaterThan(outcome.elapsed, .zero, "it waited, on the clock, rather than asking at once")
        XCTAssertLessThan(outcome.elapsed, .seconds(2))
    }

    func testARateLimitIsNotAskedAgainInSecondsWhateverTheUrgency() async throws {
        for urgency in [Urgency.background, .interactive] {
            for status in [403, 429] {
                let outcome = try await fetch([.answer(status), .answer(200)], urgency: urgency)
                XCTAssertNil(outcome.data, "\(status) at \(urgency)")
                XCTAssertEqual(outcome.requests, 1, "\(status) at \(urgency)")
                XCTAssertEqual(outcome.problem, "HTTP \(status), GitHub's rate limit")
            }
        }
    }

    func testARetryAfterIsWaitedOutOnTheClock() async throws {
        let outcome = try await fetch([.answer(429, headers: ["Retry-After": "120"]), .answer(200)],
                                      urgency: .background)
        XCTAssertEqual(outcome.data, Data("feed".utf8))
        XCTAssertEqual(outcome.requests, 2)
        XCTAssertGreaterThanOrEqual(outcome.elapsed, .seconds(120), "the server's word, not the schedule's")
    }

    func testAnAnswerThatIsNotFoundIsAFailureAtOnceWithItsStatus() async throws {
        let outcome = try await fetch([.answer(404)], urgency: .background)
        XCTAssertEqual(outcome.requests, 1)
        XCTAssertEqual(outcome.problem, "HTTP 404")
    }

    func testAConnectionThatKeepsFailingGivesUpAfterTheAttemptsItsUrgencyAllows() async throws {
        for urgency in [Urgency.interactive, .background] {
            let attempts = UpdateFeed.fetch.policy(at: urgency).schedule.maximumAttempts
            let outcome = try await fetch([.fail(.timedOut)], urgency: urgency)
            XCTAssertEqual(outcome.requests, attempts, "\(urgency)")
            XCTAssertTrue(outcome.problem?.contains("NSURLErrorDomain") == true, "the transport's own error: \(outcome.problem ?? "nil")")
        }
        XCTAssertLessThan(UpdateFeed.fetch.policy(at: .interactive).schedule.maximumAttempts,
                          UpdateFeed.fetch.policy(at: .background).schedule.maximumAttempts,
                          "a pressed menu item gives up sooner than the daily check")
    }

    /// Erased to `any Error` a URLError is an NSError here, and a cast of
    /// that to `Retryable` fails: the classification only reaches it
    /// because the attempt wraps it.
    func testARefusedCertificateIsNotAskedAgainHoweverItArrives() async throws {
        for failure in [Step.fail(.serverCertificateUntrusted), .failAsNSError(NSURLErrorServerCertificateUntrusted)] {
            let outcome = try await fetch([failure, .answer(200)], urgency: .background)
            XCTAssertNil(outcome.data)
            XCTAssertEqual(outcome.requests, 1, "\(failure)")
        }
    }

    func testALostConnectionIsAskedAgainHoweverItArrives() async throws {
        let outcome = try await fetch([.failAsNSError(NSURLErrorNetworkConnectionLost), .answer(200)], urgency: .background)
        XCTAssertEqual(outcome.data, Data("feed".utf8))
        XCTAssertEqual(outcome.requests, 2)
    }
}
