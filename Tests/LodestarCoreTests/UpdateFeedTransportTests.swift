import Foundation
import Stoic
import StoicHTTP
import XCTest
@testable import LodestarCore

/// The feed through the real transport, `URLSessionTransport` on the session
/// `UpdateFeed` makes, with a stub where the network would be: what the
/// scripted transport cannot say, that the headers, the declared length and
/// the bytes of a real `URLSession` reach the client as it reads them. Every
/// case here ends at once (a final answer or a refusal), so none waits on a
/// clock.
final class UpdateFeedTransportTests: XCTestCase {
    private final class Stub: URLProtocol {
        struct Reply {
            var status = 200
            var headers: [String: String] = [:]
            var body = Data()
        }

        /// By host, so that tests that run together never meet each other's.
        nonisolated(unsafe) static var replies: [String: Reply] = [:]
        nonisolated(unsafe) static var requests: [URLRequest] = []
        static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let (reply, _) = Stub.lock.withLock { () -> (Reply, Void) in
                Stub.requests.append(request)
                return (Stub.replies[request.url?.host ?? ""] ?? Reply(status: 404), ())
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                           headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func answer(_ reply: Stub.Reply, host: String = "stub-\(UUID().uuidString.prefix(8).lowercased()).test",
                        urgency: Urgency = .userInitiated) async -> (data: Data?, problem: String?, host: String) {
        Stub.lock.withLock { Stub.replies[host] = reply }
        let configuration = UpdateFeed.sessionConfiguration()
        configuration.protocolClasses = [Stub.self]
        let client = UpdateFeed.client(transport: URLSessionTransport(configuration: configuration))
        let url = URL(string: "https://\(host)/api/stable")!
        // A registry and budgets of their own, on the real clock: no other
        // test's breaker can be open here.
        return await withAmbient({ $0.backends = BackendRegistry(); $0.budgets = RetryBudgets() }) {
            do {
                let data = try await withUrgency(urgency) { try await UpdateFeed.data(from: url, client: client) }
                return (data, nil, host)
            } catch {
                return (nil, UpdateFeed.problem(error), host)
            }
        }
    }

    private func sent(to host: String) -> [URLRequest] {
        Stub.lock.withLock { Stub.requests.filter { $0.url?.host == host } }
    }

    func testAnAnswerComesThroughTheRealTransportWithWhoIsAsking() async {
        let result = await answer(.init(body: Data(#"{"tag":"v1"}"#.utf8)))
        XCTAssertEqual(result.data, Data(#"{"tag":"v1"}"#.utf8))
        let request = sent(to: result.host).first
        XCTAssertEqual(request?.value(forHTTPHeaderField: "User-Agent"), "lodestar/\(Lodestar.version)")
        XCTAssertEqual(request?.httpMethod, "GET")
    }

    func testALengthDeclaredOverTheLimitIsRefusedBeforeABodyIsRead() async {
        let result = await answer(.init(headers: ["Content-Length": "\(UpdateFeed.byteLimit + 1)"], body: Data("x".utf8)))
        XCTAssertNil(result.data)
        XCTAssertTrue(result.problem?.contains("larger than \(UpdateFeed.byteLimit) bytes") == true, result.problem ?? "nil")
        XCTAssertEqual(sent(to: result.host).count, 1, "and it is not asked again")
    }

    func testABodyThatPassesTheLimitWithoutSayingSoIsStopped() async {
        let result = await answer(.init(body: Data(repeating: UInt8(ascii: "x"), count: UpdateFeed.byteLimit + 1)))
        XCTAssertNil(result.data)
        XCTAssertTrue(result.problem?.contains("larger than \(UpdateFeed.byteLimit) bytes") == true, result.problem ?? "nil")
        XCTAssertEqual(sent(to: result.host).count, 1)
    }

    func testABodyAsLargeAsTheLimitIsRead() async {
        let result = await answer(.init(body: Data(repeating: UInt8(ascii: "x"), count: UpdateFeed.byteLimit)))
        XCTAssertEqual(result.data?.count, UpdateFeed.byteLimit)
    }

    func testARedirectToHTTPIsRefusedAndNeverAsked() async {
        let result = await answer(.init(status: 302, headers: ["Location": "http://elsewhere.test/api/stable"]))
        XCTAssertNil(result.data)
        XCTAssertTrue(result.problem?.contains("redirect not followed (downgrade)") == true, result.problem ?? "nil")
        let all = Stub.lock.withLock { Stub.requests }
        XCTAssertFalse(all.contains { $0.url?.scheme == "http" })
    }

    func testARateLimitIsFinalAndTheRetryAfterHeaderIsRead() async {
        let bare = await answer(.init(status: 403, body: Data(#"{"message":"rate limit"}"#.utf8)))
        XCTAssertNil(bare.data)
        XCTAssertEqual(bare.problem, "HTTP 403, GitHub's rate limit")
        XCTAssertEqual(sent(to: bare.host).count, 1)
        let none = await answer(.init(status: 429))
        XCTAssertEqual(none.problem, "HTTP 429, GitHub's rate limit")
        XCTAssertEqual(sent(to: none.host).count, 1)
        // Named, and longer than the menu item will wait: given up on at
        // once, saying what it was told (the header crossed the transport).
        let told = await answer(.init(status: 429, headers: ["Retry-After": "120"]))
        XCTAssertNil(told.data)
        XCTAssertTrue(told.problem?.contains("retry after 120.0 seconds") == true, told.problem ?? "nil")
        XCTAssertEqual(sent(to: told.host).count, 1)
    }

    func testAnErrorPageIsAFailureWithItsStatus() async {
        let result = await answer(.init(status: 404, body: Data("<html>not found</html>".utf8)))
        XCTAssertNil(result.data)
        XCTAssertEqual(result.problem, "HTTP 404")
        XCTAssertEqual(sent(to: result.host).count, 1)
    }
}
