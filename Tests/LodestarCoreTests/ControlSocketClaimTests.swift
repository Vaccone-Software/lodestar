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
        unlink(ControlSocket.ownerRecordPath(for: path.path))
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

    func testASecondInstanceDoesNotStealALiveSocket() throws {
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
        let owner = ControlSocket.ownerRecordPath(for: path.path)
        let mode = try FileManager.default.attributesOfItem(atPath: owner)[.posixPermissions]
        XCTAssertEqual(mode as? NSNumber, 0o600, "the owner record is as private as the socket")

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
        let owner = ControlSocket.ownerRecordPath(for: path.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: owner))
        make().stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: owner),
                      "a bystander does not drop the owner's record")
        XCTAssertEqual(ask(["x"])?["message"] as? String, "first")
    }

    /// macOS reports a full listen backlog as `ECONNREFUSED`, the same error
    /// a dead listener's socket file produces. A live owner's pid is what
    /// keeps the second instance from unlinking the first.
    func testARefusedSocketWithALiveOwnerIsLeftAlone() {
        bindClosedSocket()
        writeOwner(getpid())

        var lines: [String] = []
        Log.listener = { lines.append($0) }
        defer { Log.listener = nil }
        let second = make()
        second.handle = { _ in ["ok": true, "message": "second"] }
        second.start()
        XCTAssertFalse(second.isListening, "a live owner is not a leftover")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), "the socket node stays")
        XCTAssertTrue(lines.contains { $0.contains("another instance is listening") })

        // The process that owned it is gone: the record names a pid that
        // is not running, and the next launch may take the leftover.
        writeOwner(unusedPid())
        let next = make()
        next.handle = { _ in ["ok": true, "message": "next"] }
        next.start()
        XCTAssertTrue(next.isListening, "a dead owner's socket is still cleaned up")
        XCTAssertEqual(ask(["x"])?["message"] as? String, "next")
    }

    /// A crash leaves the socket node and a pid that no longer answers.
    /// That must not pin the path forever.
    func testADeadOwnersRefusedSocketIsTakenOver() {
        bindClosedSocket()
        writeOwner(unusedPid())
        let socket = make()
        socket.handle = { _ in ["ok": true, "message": "fresh"] }
        socket.start()
        XCTAssertTrue(socket.isListening)
        XCTAssertEqual(ask(["x"])?["message"] as? String, "fresh")
    }

    /// The accept loop reads a client before it accepts the next, and that
    /// read waits up to its timeout. Fill the queue while it is stuck and
    /// a second instance must not treat the refused connect as a dead socket.
    func testAFullListenQueueDoesNotYieldTheSocket() {
        let first = make()
        first.handle = { _ in ["ok": true, "message": "first"] }
        first.start()
        XCTAssertTrue(first.isListening)

        // One client that never writes keeps the accept loop inside its
        // read, so further connects sit in the backlog of 8 until it refuses.
        var held: [Int32] = []
        defer { held.forEach { close($0) } }
        let blocker = connectNonblocking()
        XCTAssertGreaterThanOrEqual(blocker.fd, 0, "the blocking client connected")
        held.append(blocker.fd)
        Thread.sleep(forTimeInterval: 0.05)

        var refused = false
        for _ in 0..<64 {
            let attempt = connectNonblocking()
            if attempt.fd >= 0 {
                held.append(attempt.fd)
                continue
            }
            if attempt.error == ECONNREFUSED || attempt.error == EAGAIN || attempt.error == EWOULDBLOCK {
                refused = true
                break
            }
            XCTFail("connect failed with \(attempt.error)")
            return
        }
        // Accepting the blocker frees one slot. Top the queue back up so
        // the probe inside `claim` is refused too, not merely queued.
        if refused {
            for _ in 0..<16 {
                let attempt = connectNonblocking()
                if attempt.fd >= 0 {
                    held.append(attempt.fd)
                    continue
                }
                break
            }
        }
        XCTAssertTrue(refused, "the listen queue never filled")
        let stillRefused = connectNonblocking()
        if stillRefused.fd >= 0 { held.append(stillRefused.fd) }
        XCTAssertLessThan(stillRefused.fd, 0, "a slot opened before the second instance could probe")
        XCTAssertTrue(stillRefused.error == ECONNREFUSED
                      || stillRefused.error == EAGAIN
                      || stillRefused.error == EWOULDBLOCK)

        let second = make()
        second.handle = { _ in ["ok": true, "message": "second"] }
        startAway(second)
        XCTAssertFalse(second.isListening, "a full queue is not a dead socket")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))

        held.forEach { close($0) }
        held.removeAll()
        // Closing the queued clients unblocks the accept loop; the reply
        // can land a moment after that drain.
        var message: String?
        let answered = expectation(description: "first still answers")
        DispatchQueue.global().async {
            let end = Date().addingTimeInterval(4)
            while Date() < end {
                if let text = ControlSocket.ask(["x"], at: self.path, timeout: 2)?["message"] as? String {
                    message = text
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            answered.fulfill()
        }
        wait(for: [answered], timeout: 6)
        XCTAssertEqual(message, "first", "the busy instance still owns the socket")
    }

    /// Bind and close without unlinking: the file a crash leaves, which
    /// `connect` refuses because nothing is listening on it.
    private func bindClosedSocket() {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: capacity) { strncpy($0, path.path, capacity - 1) }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        close(fd)
    }

    private func writeOwner(_ pid: Int32) {
        let file = ControlSocket.ownerRecordPath(for: path.path)
        let record = Array("\(pid)\n".utf8)
        let fd = open(file, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        let written = record.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        XCTAssertEqual(written, record.count)
        close(fd)
    }

    /// A pid `kill` reports as gone, so the owner record does not look live.
    private func unusedPid() -> Int32 {
        var pid = Int32(1 << 22)
        let limit = pid + 10_000
        while kill(pid, 0) == 0 || errno != ESRCH {
            pid += 1
            XCTAssertLessThan(pid, limit, "no unused pid in range")
        }
        return pid
    }

    /// A non-blocking connect. `fd` is non-negative when the connection is
    /// queued or established; the caller owns it. `error` is set when it is not.
    private func connectNonblocking() -> (fd: Int32, error: Int32) {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return (-1, errno) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: capacity) { strncpy($0, path.path, capacity - 1) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 || errno == EINPROGRESS { return (fd, 0) }
        let error = errno
        close(fd)
        return (-1, error)
    }
}
