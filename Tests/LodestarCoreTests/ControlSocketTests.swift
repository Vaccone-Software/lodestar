import XCTest
@testable import LodestarCore

/// The protocol, end to end, over a real socket on a temporary path.
///
/// Worth the setup because framing is the part that cannot be reasoned
/// about: a request that arrives in two reads, a reply with no newline, a
/// client that hangs up early. None of that shows up until something is on
/// the other end of an actual file descriptor.
final class ControlSocketTests: XCTestCase {
    private var socket: ControlSocket!
    private var path: URL!

    override func setUp() {
        super.setUp()
        path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lodestar-test-\(UUID().uuidString.prefix(8)).sock")
        socket = ControlSocket(path: path)
    }

    override func tearDown() {
        socket?.stop()
        socket = nil
        super.tearDown()
    }

    /// `ask` blocks, and the handler runs on main — so the call has to
    /// happen off main or the two wait for each other forever. That is also
    /// exactly how the CLI uses it: a separate process entirely.
    private func ask(_ arguments: [String], timeout: TimeInterval = 5) -> [String: Any]? {
        let answered = expectation(description: "reply")
        var reply: [String: Any]?
        DispatchQueue.global().async {
            reply = ControlSocket.ask(arguments, at: self.path, timeout: 2)
            answered.fulfill()
        }
        wait(for: [answered], timeout: timeout)
        return reply
    }

    func testRoundTrip() {
        socket.handle = { args in ["ok": true, "message": args.joined(separator: "+")] }
        socket.start()
        let reply = ask(["go", "g"])
        XCTAssertEqual(reply?["ok"] as? Bool, true)
        XCTAssertEqual(reply?["message"] as? String, "go+g")
    }

    /// The handler decides failure; the transport carries it either way.
    func testFailureIsCarriedNotThrown() {
        socket.handle = { _ in ["ok": false, "error": "no such thing"] }
        socket.start()
        let reply = ask(["go", "nope"])
        XCTAssertEqual(reply?["ok"] as? Bool, false)
        XCTAssertEqual(reply?["error"] as? String, "no such thing")
    }

    func testArgumentsSurviveSpacesAndUnicode() {
        socket.handle = { args in ["ok": true, "result": args] }
        socket.start()
        let reply = ask(["go", "Proton Mail", "→ ⌫"])
        XCTAssertEqual(reply?["result"] as? [String], ["go", "Proton Mail", "→ ⌫"])
    }

    /// Nothing is listening: the client says so rather than hanging.
    func testNoServerIsNilNotAHang() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lodestar-absent-\(UUID().uuidString.prefix(8)).sock")
        XCTAssertNil(ControlSocket.ask(["state"], at: missing, timeout: 1))
    }

    /// A stale socket file from a crash must not stop the next start.
    func testStartUnlinksAStaleNode() throws {
        try Data("not a socket".utf8).write(to: path)
        socket.handle = { _ in ["ok": true, "message": "alive"] }
        socket.start()
        XCTAssertEqual(ask(["state"])?["message"] as? String, "alive")
    }

    func testSocketIsNotReadableByAnyoneElse() throws {
        socket.handle = { _ in ["ok": true] }
        socket.start()
        let mode = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions]
        XCTAssertEqual(mode as? NSNumber, 0o600)
    }

    /// Malformed and hostile inputs are answered, not crashed on.
    func testGarbageIsRefused() {
        XCTAssertNil(ControlSocket.arguments(from: Data()))
        XCTAssertNil(ControlSocket.arguments(from: Data("not json\n".utf8)))
        XCTAssertNil(ControlSocket.arguments(from: Data("[1,2,3]\n".utf8)))
        XCTAssertNil(ControlSocket.arguments(from: Data("{\"args\":\"go\"}\n".utf8)))
        XCTAssertNil(ControlSocket.arguments(from: Data("{\"args\":[1,2]}\n".utf8)))
        XCTAssertEqual(ControlSocket.arguments(from: Data("{\"args\":[\"go\",\"g\"]}\n".utf8)),
                       ["go", "g"])
    }

    /// Two clients in a row on one listener — the accept loop has to keep
    /// serving after it has served.
    func testSerialClients() {
        var seen = 0
        socket.handle = { _ in seen += 1; return ["ok": true, "message": "\(seen)"] }
        socket.start()
        XCTAssertEqual(ask(["state"])?["message"] as? String, "1")
        XCTAssertEqual(ask(["state"])?["message"] as? String, "2")
        XCTAssertEqual(ask(["state"])?["message"] as? String, "3")
    }

    func testStopClosesTheDoorAndTakesTheNodeWithIt() {
        socket.handle = { _ in ["ok": true] }
        socket.start()
        XCTAssertNotNil(ask(["state"]))
        socket.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertNil(ControlSocket.ask(["state"], at: path, timeout: 1))
    }
}
