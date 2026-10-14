import XCTest
@testable import LodestarCore

/// A second instance must not take a live instance's socket; a socket file a
/// crash left behind must still be taken over.
final class ControlSocketClaimTests: XCTestCase {
    private var path: URL!
    private var sockets: [ControlSocket] = []

    override func setUp() {
        path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lodestar-claim-\(UUID().uuidString.prefix(8)).sock")
    }

    override func tearDown() {
        sockets.forEach { $0.stop() }
        unlink(path.path)
    }

    private func make(wait: TimeInterval = 0) -> ControlSocket {
        let socket = ControlSocket(path: path, claimWait: wait)
        sockets.append(socket)
        return socket
    }

    /// A probe of a live socket is answered by that socket's handler on
    /// main, so a test that probes must leave main free to answer.
    private func startAway(_ socket: ControlSocket) {
        let started = expectation(description: "started")
        DispatchQueue.global().async {
            socket.start()
            started.fulfill()
        }
        wait(for: [started], timeout: 5)
    }

    private func ask(_ arguments: [String]) -> [String: Any]? {
        var reply: [String: Any]?
        let answered = expectation(description: "reply")
        DispatchQueue.global().async {
            reply = ControlSocket.ask(arguments, at: self.path, timeout: 2)
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        return reply
    }

    func testASecondInstanceDoesNotStealALiveSocket() {
        let first = make()
        first.handle = { _ in ["ok": true, "message": "first"] }
        first.start()
        XCTAssertTrue(first.isListening)

        var lines: [String] = []
        Log.listener = { lines.append($0) }
        defer { Log.listener = nil }
        let second = make()
        second.handle = { _ in ["ok": true, "message": "second"] }
        startAway(second)
        XCTAssertFalse(second.isListening, "declined")
        XCTAssertTrue(lines.contains { $0.contains("another instance is listening") }, "and said so")

        XCTAssertEqual(ask(["x"])?["message"] as? String, "first", "the live socket still answers")
        second.stop() // must not unlink the first's socket
        XCTAssertEqual(ask(["x"])?["message"] as? String, "first")
    }

    func testALeftoverSocketFileFromACrashIsTakenOver() {
        // Bind and close without unlinking: the file a crash leaves.
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: capacity) { strncpy($0, path.path, capacity - 1) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        close(fd)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))

        let socket = make()
        socket.handle = { _ in ["ok": true, "message": "fresh"] }
        socket.start()
        XCTAssertTrue(socket.isListening)
        XCTAssertEqual(ask(["x"])?["message"] as? String, "fresh")
    }

    func testAnInstanceOnItsWayOutIsWaitedFor() {
        let old = make()
        old.handle = { _ in ["ok": true] }
        old.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { old.stop() }
        let next = make(wait: 2)
        next.handle = { _ in ["ok": true, "message": "next"] }
        startAway(next)
        XCTAssertTrue(next.isListening, "the old one let go within the wait")
        XCTAssertEqual(ask(["x"])?["message"] as? String, "next")
    }

    func testStoppingWithoutEverStartingLeavesAnotherInstancesSocket() {
        let first = make()
        first.handle = { _ in ["ok": true, "message": "first"] }
        first.start()
        make().stop()
        XCTAssertEqual(ask(["x"])?["message"] as? String, "first")
    }
}
