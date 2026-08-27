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
/// cannot. Nothing here reads a file, runs a command, or types into an app.
/// The socket is `0600` in your own directory, which is the same protection
/// your ssh keys have.
public final class ControlSocket {
    /// Where the app listens. Injectable so the protocol can be exercised
    /// against a temporary path rather than the one a live instance owns.
    public static var defaultPath: URL { Paths.data.appendingPathComponent("control.sock") }

    private let path: URL

    public init(path: URL = ControlSocket.defaultPath) {
        self.path = path
    }

    /// Bigger than any verb and small enough that a wedged or hostile
    /// client cannot make us hold a buffer for it.
    private static let maxRequest = 64 * 1024
    /// A client that connects and then says nothing is a leaked descriptor.
    private static let readTimeout: Int = 2

    /// Runs on the main thread, because everything it touches does.
    public var handle: (([String]) -> [String: Any])?

    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    /// Accepting and the blocking read both happen here, never on main: one
    /// slow client must not be able to hold the keyboard.
    private let queue = DispatchQueue(label: "lodestar.control")

    public func start() {
        let path = self.path.path
        // A socket file outlives a crash. Unlinking first is what makes a
        // restart after one work rather than fail to bind forever.
        unlink(path)
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
        listener = -1
        unlink(path.path)
    }

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
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                   socklen_t(MemoryLayout<Int32>.size))

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
