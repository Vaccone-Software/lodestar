import Foundation
import LodestarCore
import LodestarEars

/// Why a request to the models service has no answer, besides the
/// service's own reasons (`ModelsFailure`).
enum ModelsError: Error, CustomStringConvertible {
    /// The service ended (it crashed, was ended, or launchd let it go)
    /// before it answered, or could not be reached.
    case interrupted
    /// It answered something this build cannot read.
    case unreadable
    /// It did not answer in time, and was ended for it.
    case timedOut(String)

    var description: String {
        switch self {
        case .interrupted: return "the models service ended before it answered"
        case .unreadable: return "the models service answered something unreadable"
        case .timedOut(let what): return what
        }
    }
}

/// The app's side of the models service (LodestarModels, in
/// Contents/XPCServices): every model that evaluates on MLX is asked here,
/// and runs there.
///
/// launchd starts the service at the first message and may end it at any
/// moment, so nothing here assumes it is the same process as last time. A
/// connection only interrupted stays usable: the next message starts a
/// fresh service. Each interruption, invalidation or ending moves `epoch`,
/// and a model or ear loaded in an earlier epoch is lost (`isLost`): its
/// owner lets it go and loads again at the next request. A load is sent
/// again once when the service ended under it, since a load holds nothing
/// yet.
///
/// The app ends a service whose generation stopped answering (`end`): it
/// asks the service to exit, which it does on a queue no generation holds,
/// and lets the connection go. The service ends itself, too, a few seconds
/// after it holds nothing.
final class ModelsClient: @unchecked Sendable {
    static let shared = ModelsClient()
    /// How long an ended service's connection is kept, so its exit is
    /// delivered before the connection is let go.
    static let endGrace: TimeInterval = 2

    private let connect: () -> NSXPCConnection
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    /// A service asked to end, until its process has gone. There is one
    /// service process for the app: a connection made before it has gone
    /// reaches the process that is ending, and what it loads goes with it
    /// (a model loaded, then lost, then loaded again). Requests wait for
    /// it, at most `endGrace`, when the connection is invalidated anyway.
    private var ending: NSXPCConnection?
    private var endingWaiters: [CheckedContinuation<Void, Never>] = []
    private var currentEpoch = 0
    private var nextID: Int64 = 0
    /// Handles loaded in this epoch and not yet released, and the ear.
    private var handles: Set<String> = []
    private var earHeld = false

    init(connect: @escaping () -> NSXPCConnection = { NSXPCConnection(serviceName: Models.serviceName) }) {
        self.connect = connect
    }

    var epoch: Int { lock.withLock { currentEpoch } }

    /// Does the service hold anything this app loaded? Nothing asks a
    /// service that holds nothing, so a reading never starts one.
    var holds: Bool { lock.withLock { !handles.isEmpty || earHeld } }

    // MARK: Language models

    func loadLanguageModel(_ spec: LanguageModelSpec) async throws -> ServiceLanguageModel {
        let (handle, epoch): (String, Int) = try await call(retryingOnce: true) { proxy, id, reply in
            proxy.loadLanguageModel(Models.encode(LanguageModelLoad(id: id, spec: spec)) ?? Data(), reply: reply)
        }
        lock.withLock { if currentEpoch == epoch { handles.insert(handle) } }
        return ServiceLanguageModel(client: self, handle: handle, epoch: epoch, label: spec.label)
    }

    func respond(_ handle: String, to sentence: String, instructions: String) async throws -> String {
        try await generate(handle, sentence, IntentPass.Prompt(instructions: instructions, examples: [])) {
            $0.respond($1, reply: $2)
        }
    }

    func rewrite(_ handle: String, _ text: String, prompt: IntentPass.Prompt) async throws -> String {
        try await generate(handle, text, prompt) { $0.rewrite($1, reply: $2) }
    }

    func warm(_ handle: String, prompt: IntentPass.Prompt) async throws {
        let _: Bool = try await generate(handle, "", prompt) { $0.warm($1, reply: $2) }
    }

    private func generate<T: Codable & Sendable>(
        _ handle: String, _ text: String, _ prompt: IntentPass.Prompt,
        _ send: @escaping (ModelsXPC, Data, @escaping @Sendable (Data?) -> Void) -> Void
    ) async throws -> T {
        try await call { proxy, id, reply in
            send(proxy, Models.encode(ModelsGenerate(id: id, handle: handle, text: text, prompt: prompt)) ?? Data(), reply)
        }.0
    }

    /// The service lets the model go, unless it is not the service that
    /// loaded it: a release never starts a service.
    func release(_ handle: String, epoch: Int) {
        let connection = lock.withLock { () -> NSXPCConnection? in
            guard currentEpoch == epoch, handles.remove(handle) != nil else { return nil }
            return self.connection
        }
        (connection?.remoteObjectProxy as? ModelsXPC)?.releaseLanguageModel(handle)
    }

    // MARK: The ear

    /// Loads the ear; the epoch it was loaded in.
    func loadEar(_ spec: EarSpec) async throws -> Int {
        let (_, epoch): (Bool, Int) = try await call(retryingOnce: true) { proxy, id, reply in
            proxy.loadEar(Models.encode(EarLoad(id: id, spec: spec)) ?? Data(), reply: reply)
        }
        lock.withLock { if currentEpoch == epoch { earHeld = true } }
        return epoch
    }

    func transcribe(_ samples: [Float], context: [String]) async throws -> Heard {
        let bytes = Models.bytes(samples)
        return try await call { proxy, id, reply in
            proxy.transcribe(Models.encode(EarTranscribe(id: id, samples: bytes, context: context)) ?? Data(), reply: reply)
        }.0
    }

    func unloadEar() {
        let connection = lock.withLock { () -> NSXPCConnection? in
            guard earHeld else { return nil }
            earHeld = false
            return self.connection
        }
        (connection?.remoteObjectProxy as? ModelsXPC)?.unloadEar()
    }

    // MARK: Asking about it

    /// What the service holds, for the memory line: nil, at once, when it
    /// holds nothing of ours, and nil after `timeout` when it does not say.
    /// Blocks the calling thread, so never call it on main.
    func memoryReading(timeout: TimeInterval = 1) -> ModelsStats? {
        let connection = lock.withLock { !handles.isEmpty || earHeld ? self.connection : nil }
        guard let connection else { return nil }
        let answer = Answer<ModelsStats>()
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in answer.give(nil) } as? ModelsXPC
        proxy?.stats { answer.give(Models.decode(ModelsStats.self, from: $0)) }
        return answer.wait(timeout)
    }

    /// The same, starting the service if it must: for `editor check`.
    func stats() async throws -> ModelsStats {
        let connection = lock.withLock { live() }
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in once.resume(throwing: ModelsError.interrupted) }
                as? ModelsXPC
            proxy?.stats { data in
                guard let stats = Models.decode(ModelsStats.self, from: data) else {
                    return once.resume(throwing: ModelsError.unreadable)
                }
                once.resume(returning: stats)
            }
        }
    }

    /// The service started, and evaluated on the GPU with the kernels its
    /// bundle carries: the self-test's question.
    func check() async throws -> ModelsCheck {
        try await call(retryingOnce: true) { proxy, _, reply in proxy.check(reply: reply) }.0
    }

    /// Ends the service: a generation that stopped answering is not stopped
    /// any other way. Everything it held is lost, and the next request
    /// starts a fresh one. Does nothing when no service is connected.
    func end(reason: String) {
        let ended = lock.withLock { () -> NSXPCConnection? in
            guard let connection else { return nil }
            self.connection = nil
            ending = connection
            lostLocked()
            return connection
        }
        guard let ended else { return }
        Log.info("models", ["ending": reason])
        (ended.remoteObjectProxy as? ModelsXPC)?.exit(reason)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.endGrace) { ended.invalidate() }
    }

    // MARK: The connection

    /// Returns once no ended service is still going away.
    private func endingSettled() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waits = lock.withLock { () -> Bool in
                guard ending != nil else { return false }
                endingWaiters.append(continuation)
                return true
            }
            if !waits { continuation.resume() }
        }
    }

    /// The connection, made when first needed and again after it was let
    /// go. Call holding the lock.
    private func live() -> NSXPCConnection {
        if let connection { return connection }
        let made = connect()
        made.remoteObjectInterface = NSXPCInterface(with: ModelsXPC.self)
        made.interruptionHandler = { [weak self, weak made] in self?.lost(made, "interrupted", drop: false) }
        made.invalidationHandler = { [weak self, weak made] in self?.lost(made, "invalidated", drop: true) }
        made.resume()
        connection = made
        return made
    }

    private func lost(_ made: NSXPCConnection?, _ how: String, drop: Bool) {
        // The ended service's process has gone: whoever waited may connect.
        let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            guard let made, ending === made else { return [] }
            ending = nil
            defer { endingWaiters = [] }
            return endingWaiters
        }
        released.forEach { $0.resume() }
        let current = lock.withLock { () -> Bool in
            guard let made, connection === made else { return false }
            if drop { connection = nil }
            lostLocked()
            return true
        }
        if current { Log.info("models", ["service": how]) }
    }

    private func lostLocked() {
        currentEpoch += 1
        handles = []
        earHeld = false
    }

    /// One request and its answer, with the epoch it was sent in. A task
    /// cancelled while it waits asks the service to stop the request.
    private func call<T: Codable & Sendable>(
        retryingOnce: Bool = false,
        _ send: @escaping (ModelsXPC, Int64, @escaping @Sendable (Data?) -> Void) -> Void
    ) async throws -> (T, Int) {
        do {
            return try await callOnce(send)
        } catch ModelsError.interrupted where retryingOnce && !Task.isCancelled {
            return try await callOnce(send)
        }
    }

    private func callOnce<T: Codable & Sendable>(
        _ send: @escaping (ModelsXPC, Int64, @escaping @Sendable (Data?) -> Void) -> Void
    ) async throws -> (T, Int) {
        await endingSettled()
        let (id, epoch, connection) = lock.withLock { () -> (Int64, Int, NSXPCConnection) in
            nextID += 1
            return (nextID, currentEpoch, live())
        }
        let request = Request()
        let data: Data? = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let once = Once(continuation)
                guard request.send() else { return once.resume(throwing: CancellationError()) }
                let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self, weak connection] error in
                    // An invalid connection is dead: let go of it here, before
                    // the request is sent again, so the resend makes a new one
                    // whenever the invalidation handler's own call arrives.
                    // An interrupted one stays: its next message starts a
                    // fresh service.
                    if (error as NSError).code == NSXPCConnectionInvalid, let connection {
                        self?.lost(connection, "invalidated", drop: true)
                    }
                    once.resume(throwing: ModelsError.interrupted)
                } as? ModelsXPC
                guard let proxy else { return once.resume(throwing: ModelsError.interrupted) }
                send(proxy, id) { once.resume(returning: $0) }
            }
        } onCancel: {
            if request.cancel() { (connection.remoteObjectProxy as? ModelsXPC)?.cancel(id) }
        }
        guard let reply = Models.decode(ModelsReply<T>.self, from: data) else { throw ModelsError.unreadable }
        if let failure = reply.failure {
            throw failure == .cancelled ? CancellationError() : failure
        }
        guard let value = reply.value else { throw ModelsError.unreadable }
        return (value, epoch)
    }

    /// A request is sent once, and cancelled only once sent: a cancel that
    /// comes first keeps it from being sent at all.
    private final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var sent = false
        private var cancelled = false
        func send() -> Bool {
            lock.withLock {
                guard !cancelled else { return false }
                sent = true
                return true
            }
        }
        func cancel() -> Bool { lock.withLock { cancelled = true; return sent } }
    }

    /// Resumes a continuation once: XPC calls exactly one of the reply and
    /// the error handler, and this makes sure of it.
    private final class Once<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
        func resume(returning value: Value) { take()?.resume(returning: value) }
        func resume(throwing error: Error) { take()?.resume(throwing: error) }
        private func take() -> CheckedContinuation<Value, Error>? {
            lock.withLock { defer { continuation = nil }; return continuation }
        }
    }

    private final class Answer<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var value: Value?
        private var given = false
        func give(_ value: Value?) {
            let first = lock.withLock { () -> Bool in
                guard !given else { return false }
                given = true
                self.value = value
                return true
            }
            if first { done.signal() }
        }
        func wait(_ timeout: TimeInterval) -> Value? {
            guard done.wait(timeout: .now() + timeout) == .success else { return nil }
            return lock.withLock { value }
        }
    }
}

/// A language model loaded in the models service, asked through it: the
/// editor's and the draft's backend for Standard and Full. Letting the last
/// reference go lets the model go in the service.
final class ServiceLanguageModel: EditorBackend, @unchecked Sendable {
    let client: ModelsClient
    let handle: String
    let epoch: Int
    let label: String
    private let lock = NSLock()
    private var refused = false

    init(client: ModelsClient, handle: String, epoch: Int, label: String) {
        self.client = client
        self.handle = handle
        self.epoch = epoch
        self.label = label
    }

    /// The service it was loaded in has ended, or said it no longer holds it.
    var isLost: Bool { lock.withLock { refused } || client.epoch != epoch }

    func respond(to sentence: String, instructions: String) async throws -> String {
        try await asked { try await self.client.respond(self.handle, to: sentence, instructions: instructions) }
    }

    func rewrite(_ text: String, prompt: IntentPass.Prompt) async throws -> String {
        try await asked { try await self.client.rewrite(self.handle, text, prompt: prompt) }
    }

    func warm(_ prompt: IntentPass.Prompt) async throws {
        try await asked { try await self.client.warm(self.handle, prompt: prompt) }
    }

    private func asked<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch ModelsFailure.notLoaded {
            lock.withLock { refused = true }
            throw ModelsFailure.notLoaded
        }
    }

    deinit { client.release(handle, epoch: epoch) }
}

/// The Qwen3-ASR ear, heard in the models service. Each load and phrase
/// takes the app's MLX lane first, as the ear took it in the app, so the
/// editor's sentence never counts an ear's phrase against its own
/// deadline; in the service the ear takes the service's lane too. A phrase
/// or load that does not come back in time ends the service, which is the
/// only way a stuck evaluation stops. After the service ended, the ear is
/// no longer loaded, and the next phrase loads it again first.
final class ServiceEar: SettlingEar, @unchecked Sendable {
    let name: String
    let folder: URL
    private let client: ModelsClient
    private let gate: MLXGate
    /// The slowest phrase logged took nine seconds, a cold load a few.
    let loadDeadline: TimeInterval
    let phraseDeadline: TimeInterval
    private let lock = NSLock()
    /// Loaded and not unloaded since: a phrase may load it again.
    private var wanted = false
    private var loadedEpoch: Int?

    init(name: String, folder: URL, client: ModelsClient = .shared, gate: MLXGate = .shared,
         loadDeadline: TimeInterval = 120, phraseDeadline: TimeInterval = 30) {
        self.name = name
        self.folder = folder
        self.client = client
        self.gate = gate
        self.loadDeadline = loadDeadline
        self.phraseDeadline = phraseDeadline
    }

    var isLoaded: Bool {
        let loaded = lock.withLock { loadedEpoch }
        return loaded != nil && loaded == client.epoch
    }

    func load() async throws {
        lock.withLock { wanted = true }
        let spec = EarSpec(name: name, directory: folder.path)
        let epoch = try await laned(loadDeadline, "the ear did not load") { try await self.client.loadEar(spec) }
        lock.withLock { if wanted { loadedEpoch = epoch } }
    }

    func transcribe(_ samples: [Float], context: [String]) async throws -> Heard {
        if !isLoaded {
            guard lock.withLock({ wanted }) else { throw ModelsFailure.notLoaded }
            Log.info("draft", ["ear": name, "loading again": "the models service started afresh"])
            try await load()
        }
        do {
            return try await laned(phraseDeadline, "the ear did not hear a phrase") {
                try await self.client.transcribe(samples, context: context)
            }
        } catch ModelsFailure.notLoaded {
            lock.withLock { loadedEpoch = nil }
            throw ModelsFailure.notLoaded
        }
    }

    func unload() {
        lock.withLock {
            wanted = false
            loadedEpoch = nil
        }
        client.unloadEar()
    }

    /// `work` holding the app's lane, and the service ended if it has not
    /// answered by `deadline`.
    private func laned<T: Sendable>(_ deadline: TimeInterval, _ what: String,
                                    _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let permit = await gate.acquire() else { throw CancellationError() }
        defer { gate.release(permit) }
        let client = self.client
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(deadline))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let answer = first else {
                let why = "\(what) in \(Int(deadline)) s"
                Log.error("draft: \(why)")
                client.end(reason: why)
                throw ModelsError.timedOut(why)
            }
            return answer
        }
    }
}
