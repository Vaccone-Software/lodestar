import Foundation

/// The door a script comes in by.
///
/// Every verb here has to run inside the *running* instance, and that is
/// not a convenience — it is the only place the work can happen. A fresh
/// `lodestar` process has no window model, no accessibility observers, and
/// no layout; it would have to build all three, ask macOS for a trust grant
/// it does not have, and then throw the lot away. So the CLI is a thin pipe
/// and the app is the interpreter.
///
/// A Unix socket rather than the signal the config reload uses: signals
/// carry no arguments and bring back no answer, and a verb needs both.
///
/// **What this is, plainly.** Any process running as you can drive it. That
/// is a real amplification — such a process may not itself hold
/// Accessibility, and through this it can move your windows using
/// Lodestar's grant. The bound is deliberate: it can go where you can go
/// and arrange what you can arrange, and it can do nothing Lodestar itself
/// cannot. Nothing here runs a command. The draft verbs reach further than
/// arranging, and say so: `draft type` and `draft key` write into the draft,
/// `draft commit` lands its text in the front app the way ⏎ does, and
/// `draft audio <path>` reads a sound file you name and dictates it. So a
/// process running as you can, through this socket, put words into the app
/// in front. The socket is `0600` in your own directory, which is the same
/// protection your ssh keys have, and that is the whole of the bound: it
/// keeps out other users, not your own processes.
public final class ControlSocket {
    /// Where the app listens. Injectable so the protocol can be exercised
    /// against a temporary path rather than the one a live instance owns.
    public static var defaultPath: URL { Paths.data.appendingPathComponent("control.sock") }

    private let path: URL

    /// How long `start` waits for a socket that something is still
    /// listening on, in case it is an instance on its way out (an update
    /// hands over from the old process to the new one within moments).
    private let claimWait: TimeInterval

    public init(path: URL = ControlSocket.defaultPath, claimWait: TimeInterval = 1) {
        self.path = path
        self.claimWait = claimWait
    }

    /// Bigger than any verb and small enough that a wedged or hostile
    /// client cannot make us hold a buffer for it.
    private static let maxRequest = 64 * 1024
    /// A client that connects and then says nothing is a leaked descriptor.
    private static let readTimeout: Int = 2

    /// Runs on the main thread, because everything it touches does.
    public var handle: (([String]) -> [String: Any])?

    private var listener: Int32 = -1
    /// Set once `claim` has recorded this process against the socket.
    /// Only that instance removes the record; one that declined must not.
    private var ownsClaim = false
    private var source: DispatchSourceRead?
    /// Accepting and the blocking read both happen here, never on main: one
    /// slow client must not be able to hold the keyboard.
    private let queue = DispatchQueue(label: "lodestar.control")

    /// Whether this instance owns the socket at the path: only an owner
    /// unlinks it when it stops.
    public var isListening: Bool { listener >= 0 }

    public func start() {
        let path = self.path.path
        // A socket file outlives a crash, so unlinking it first is what
        // makes a restart after one work rather than fail to bind forever.
        // But a file with something listening behind it is not a leftover:
        // a second instance used to unlink it anyway, and the first went on
        // running with a socket nobody could reach. On macOS a full listen
        // backlog refuses connect the same way a dead socket does, so ask,
        // and check the owner, before taking it.
        guard Self.claim(path, waiting: claimWait) else {
            Log.error("control", ["socket": "another instance is listening on \(path) — left alone, no control socket here"])
            return
        }
        // `claim` has recorded our pid. Any return before the listener is
        // up has to take that back, or this process would look like the
        // owner of a socket it never bound.
        var releaseClaim = true
        defer { if releaseClaim { Self.relinquish(path) } }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            Log.error("control", ["socket": "path too long for a unix socket"])
            return
        }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                strncpy(buffer, path, capacity - 1)
            }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Log.error("control", ["socket": "could not open (\(errno))"])
            return
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            Log.error("control", ["socket": "could not bind (\(errno))"])
            close(fd)
            return
        }
        // Before anyone can connect. Bind creates the node with the process
        // umask, which on a permissive umask would be group and world
        // writable — and this is a door.
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            Log.error("control", ["socket": "could not listen (\(errno))"])
            close(fd)
            unlink(path)
            return
        }
        listener = fd
        ownsClaim = true
        releaseClaim = false
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in self?.serveOne() }
        reader.setCancelHandler { close(fd) }
        reader.resume()
        source = reader
        Log.info("control", ["socket": path])
    }

    public func stop() {
        source?.cancel()
        source = nil
        // Only the instance that bound the socket removes it; one that
        // declined to take it over must not unlink the live owner's.
        // The node goes first and the owner record second: a peer that
        // probes in between still sees a live pid and waits, rather than
        // binding the path we just gave up.
        if listener >= 0 { unlink(path.path) }
        listener = -1
        if ownsClaim {
            Self.relinquish(path.path)
            ownsClaim = false
        }
    }

    /// Clears the way to bind at `path`: true when nothing is there or
    /// what is there is a leftover (and is now unlinked), false when a
    /// process is accepting connections on it. A live one is given
    /// `waiting` seconds to go away before it is believed.
    static func claim(_ path: String, waiting: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(waiting)
        while true {
            if isListening(at: path) {
                guard Date() < deadline else { return false }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            // Vacant, or refused. Record ourselves before unlinking so a
            // second starter that loses the race sees a live owner and
            // waits, instead of deleting the socket we are about to bind.
            guard takeOwnership(path) else {
                guard Date() < deadline else { return false }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            // The record now names us, so `isListening` would report the
            // path as alive even when nothing has answered. Look at the
            // socket itself before removing it.
            if answers(at: path) {
                relinquish(path)
                guard Date() < deadline else { return false }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            unlink(path)
            return true
        }
    }

    /// Whether a connect at `path` reached a listener.
    ///
    /// `ECONNREFUSED` means the connect did not get through. It does not
    /// mean the socket is a leftover. macOS returns it when the listen
    /// queue is full — `listen(2)` says a client may be refused, and
    /// `unp_connect` returns it when `sonewconn` fails — and the queue
    /// here is 8, with an accept loop that can sit in a read for
    /// `readTimeout` seconds. A socket file whose process has died fails
    /// the same way. `isListening` tells those apart with the owner record.
    ///
    /// A connection that only connects and hangs up is not a polite probe:
    /// the listener accepts it after the peer is gone, where setting
    /// SO_NOSIGPIPE can fail and the reply's `send` then raises SIGPIPE in
    /// the process being probed. So the probe says something the listener
    /// answers harmlessly (a request with no verb, refused as such) and
    /// leaves only once the answer is in, or a second has passed.
    private static func answers(at path: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return false }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                strncpy(buffer, path, capacity - 1)
            }
        }
        // Not a socket at all (a stray file at the path) cannot be listening.
        var node = stat()
        guard lstat(path, &node) == 0, node.st_mode & S_IFMT == S_IFSOCK else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard result == 0 else {
            return errno != ECONNREFUSED && errno != ENOENT
        }
        let request = Array("{\"args\":[]}\n".utf8)
        guard send(fd, request, request.count, 0) == request.count else { return true }
        var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        _ = poll(&ready, 1, probeWait)
        var buffer = [UInt8](repeating: 0, count: 256)
        _ = read(fd, &buffer, buffer.count)
        return true
    }

    /// Whether `path` must be left alone: something answered, or a live
    /// process still owns it. A refused connect with a dead owner is a
    /// leftover; the same refusal with a live owner is a full backlog.
    private static func isListening(at path: String) -> Bool {
        answers(at: path) || ownerIsAlive(path)
    }

    /// The pid of the process that last claimed the socket, beside it.
    /// A clean stop removes it. A crash leaves a pid `kill` will not find,
    /// which is how the next launch tells a leftover from a busy instance.
    static func ownerRecordPath(for socketPath: String) -> String {
        socketPath + ".pid"
    }

    private static func readOwner(_ socketPath: String) -> Int32? {
        let fd = open(ownerRecordPath(for: socketPath), O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = Darwin.read(fd, &buffer, buffer.count)
        guard count > 0,
              let text = String(bytes: buffer.prefix(count), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0 else { return nil }
        return pid
    }

    /// `kill(pid, 0)` reports a process we may not signal as `EPERM`. It
    /// is still there, so the socket it owns is not ours to take.
    private static func processIsAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func ownerIsAlive(_ socketPath: String) -> Bool {
        guard let pid = readOwner(socketPath) else { return false }
        return processIsAlive(pid)
    }

    /// Records this process as the owner when no live one holds the record.
    /// The lock only serializes two starters. The pid is what a later
    /// launch checks: a crash leaves the file, and `kill` on that pid fails.
    private static func takeOwnership(_ socketPath: String) -> Bool {
        if ownerIsAlive(socketPath) { return false }
        let file = ownerRecordPath(for: socketPath)
        let fd = open(file, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        // Under the lock: a peer that won it has already written a live
        // pid. Same-process flock does not exclude us, which is why a
        // live pid that is not ours still declines.
        if let pid = readOwner(socketPath), pid != getpid(), processIsAlive(pid) {
            return false
        }
        guard fchmod(fd, 0o600) == 0, ftruncate(fd, 0) == 0, lseek(fd, 0, SEEK_SET) == 0 else {
            return false
        }
        let record = Array("\(getpid())\n".utf8)
        let written = record.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        guard written == record.count else {
            _ = ftruncate(fd, 0)
            return false
        }
        return true
    }

    /// Drops the record when it still names this process. A successor that
    /// has already written its own pid is left in place.
    private static func relinquish(_ socketPath: String) {
        guard readOwner(socketPath) == getpid() else { return }
        unlink(ownerRecordPath(for: socketPath))
    }

    /// How long a probe waits for the listener's answer, in milliseconds.
    static var probeWait: Int32 = 1_000

    private func serveOne() {
        let client = accept(listener, nil, nil)
        guard client >= 0 else { return }
        var timeout = timeval(tv_sec: Self.readTimeout, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
        // A client that hangs up mid-reply must be an error code, never a
        // signal: the default for a write to a closed socket is SIGPIPE,
        // and the default disposition of SIGPIPE is to end the process.
        // Lodestar is a menu-bar app that has to outlive an impatient ⌃C.
        var noSignal: Int32 = 1
        // A peer that has already gone refuses the option, and a reply to
        // it would then raise the signal: such a client is simply dropped.
        guard setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(client)
            return
        }

        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.count < Self.maxRequest {
            let read = Darwin.read(client, &buffer, buffer.count)
            guard read > 0 else { break }
            request.append(contentsOf: buffer[0..<read])
            if request.last == 0x0A { break } // one line, one request
        }

        guard let arguments = Self.arguments(from: request) else {
            reply(["ok": false, "error": "could not read the request"], to: client)
            return
        }
        // The verb itself on main, the reply back out here — so a verb that
        // takes a moment (a breath restoring six windows) never blocks the
        // accept loop, and a client that has gone away costs nothing.
        DispatchQueue.main.async { [weak self] in
            let answer = self?.handle?(arguments)
                ?? ["ok": false, "error": "lodestar is still starting up"]
            self?.queue.async { self?.reply(answer, to: client) }
        }
    }

    public static func arguments(from request: Data) -> [String]? {
        guard !request.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: request),
              let envelope = object as? [String: Any],
              let arguments = envelope["args"] as? [String] else { return nil }
        return arguments
    }

    private func reply(_ answer: [String: Any], to client: Int32) {
        defer { close(client) }
        guard var data = try? JSONSerialization.data(withJSONObject: answer,
                                                     options: [.sortedKeys]) else {
            return
        }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let wrote = send(client, raw.baseAddress!.advanced(by: sent),
                                 raw.count - sent, 0)
                guard wrote > 0 else { return }
                sent += wrote
            }
        }
    }

    /// The client half. Here rather than in the CLI so that both ends of
    /// the protocol are one file: a framing rule written down twice is a
    /// framing rule that will eventually be written down differently.
    public static func ask(_ arguments: [String], at path: URL = defaultPath,
                           timeout: Int = 15) -> [String: Any]? {
        let path = path.path
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return nil }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { field in
            field.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                strncpy(buffer, path, capacity - 1)
            }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let joined = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard joined == 0 else { return nil }
        var window = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &window,
                   socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &window,
                   socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                   socklen_t(MemoryLayout<Int32>.size))

        guard var request = try? JSONSerialization.data(
            withJSONObject: ["args": arguments]) else { return nil }
        request.append(0x0A)
        let written = request.withUnsafeBytes { raw -> Int in
            var sent = 0
            while sent < raw.count {
                let wrote = send(fd, raw.baseAddress!.advanced(by: sent),
                                 raw.count - sent, 0)
                guard wrote > 0 else { return sent }
                sent += wrote
            }
            return sent
        }
        guard written == request.count else { return nil }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let read = Darwin.read(fd, &buffer, buffer.count)
            guard read > 0 else { break }
            response.append(contentsOf: buffer[0..<read])
            if response.last == 0x0A { break }
        }
        guard let object = try? JSONSerialization.jsonObject(with: response) else { return nil }
        return object as? [String: Any]
    }
}
