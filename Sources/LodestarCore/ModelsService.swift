import Foundation
import Synchronization

// Lodestar's models service: every evaluation on MLX (the editor's language
// model, dictation's model for what was meant, the Qwen3-ASR ear) runs in an
// XPC service the app carries in Contents/XPCServices, the way Apple keeps
// work an app cannot afford to share its process with out of it. Measured in
// the app's own record before the move: a generation that never ended
// refused every question until the app restarted (42 times, once for 50
// minutes); the app's footprint reached 28.3 GB, 23.4 of it MLX's; and a
// quit crashed with MLX's destructors racing a compile on another thread.
// A service can be ended and started again, its memory goes with it, and
// launchd ends it without running a destructor in the app.
//
// launchd starts the service at the first message and may end it at any
// moment, so the app keeps nothing in it that it could not send again: a
// model is loaded by its folder, and a request for a handle the service no
// longer holds answers `notLoaded`, which tells the app to load again.
//
// Requests and answers cross as property lists of the Codable types below.
// Everything here is plain data and concurrency, so Core owns it; MLX is
// linked only by the service (LodestarMLX), and the tests host this same
// object with a fake engine behind an anonymous listener.

/// The models service's XPC interface.
@objc public protocol ModelsXPC {
    /// `LanguageModelLoad` in, `ModelsReply<String>` out: the handle.
    func loadLanguageModel(_ request: Data, reply: @escaping @Sendable (Data?) -> Void)
    /// `ModelsGenerate` in, `ModelsReply<String>` out: the sentence corrected.
    func respond(_ request: Data, reply: @escaping @Sendable (Data?) -> Void)
    /// `ModelsGenerate` in, `ModelsReply<String>` out: the text as meant.
    func rewrite(_ request: Data, reply: @escaping @Sendable (Data?) -> Void)
    /// `ModelsGenerate` in, `ModelsReply<Bool>` out: the prompt's beginning read.
    func warm(_ request: Data, reply: @escaping @Sendable (Data?) -> Void)
    func releaseLanguageModel(_ handle: String)
    /// `EarLoad` in, `ModelsReply<Bool>` out.
    func loadEar(_ request: Data, reply: @escaping @Sendable (Data?) -> Void)
    /// `EarTranscribe` in, `ModelsReply<Heard>` out.
    func transcribe(_ request: Data, reply: @escaping @Sendable (Data?) -> Void)
    func unloadEar()
    /// Stops the request with this id at its next token. A request not yet
    /// arrived is refused when it does.
    func cancel(_ id: Int64)
    /// `ModelsStats`, read from counters: never waits for the lane.
    func stats(reply: @escaping @Sendable (Data?) -> Void)
    /// `ModelsReply<ModelsCheck>`: a small evaluation on the GPU, proof
    /// that the service started and MLX found its device and its kernels.
    func check(reply: @escaping @Sendable (Data?) -> Void)
    /// Ends the service now, on a queue no generation ever holds.
    func exit(_ reason: String)
}

public enum Models {
    /// The service's bundle identifier, in `Contents/XPCServices`.
    public static let serviceName = "com.vaccone.lodestar.models"

    public static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try? encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        data.flatMap { try? PropertyListDecoder().decode(type, from: $0) }
    }

    /// 16 kHz samples as their bytes, and back.
    public static func bytes(_ samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func samples(_ bytes: Data) -> [Float] {
        bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// A language model by its folder: what a fresh service needs to load it.
public struct LanguageModelSpec: Codable, Sendable, Hashable {
    public var directory: String
    /// For the log.
    public var label: String
    /// The chat template's switches (Qwen's `enable_thinking`).
    public var context: [String: Bool]
    /// Reads each prompt's shared beginning once (off only for a bench).
    public var cachesInstructions: Bool

    public init(directory: String, label: String, context: [String: Bool] = [:], cachesInstructions: Bool = true) {
        self.directory = directory
        self.label = label
        self.context = context
        self.cachesInstructions = cachesInstructions
    }
}

public struct LanguageModelLoad: Codable, Sendable {
    public var id: Int64
    public var spec: LanguageModelSpec
    public init(id: Int64, spec: LanguageModelSpec) {
        self.id = id
        self.spec = spec
    }
}

/// One question to a loaded model. `respond` reads `prompt.instructions`
/// and no examples.
public struct ModelsGenerate: Codable, Sendable {
    public var id: Int64
    public var handle: String
    public var text: String
    public var prompt: IntentPass.Prompt
    public init(id: Int64, handle: String, text: String, prompt: IntentPass.Prompt) {
        self.id = id
        self.handle = handle
        self.text = text
        self.prompt = prompt
    }
}

/// The ear by its factory name and its folder.
public struct EarSpec: Codable, Sendable, Hashable {
    public var name: String
    public var directory: String
    public init(name: String, directory: String) {
        self.name = name
        self.directory = directory
    }
}

public struct EarLoad: Codable, Sendable {
    public var id: Int64
    public var spec: EarSpec
    public init(id: Int64, spec: EarSpec) {
        self.id = id
        self.spec = spec
    }
}

public struct EarTranscribe: Codable, Sendable {
    public var id: Int64
    /// 16 kHz mono Float32, as `Models.bytes` writes it.
    public var samples: Data
    public var context: [String]
    public init(id: Int64, samples: Data, context: [String]) {
        self.id = id
        self.samples = samples
        self.context = context
    }
}

/// Why a request has no answer.
public enum ModelsFailure: Error, Codable, Sendable, Equatable, CustomStringConvertible {
    /// The service holds no model under that handle (or no ear): it was
    /// started afresh since the load. Load again.
    case notLoaded
    /// Cancelled before it answered.
    case cancelled
    case failed(String)

    public var description: String {
        switch self {
        case .notLoaded: return "the models service holds no such model"
        case .cancelled: return "cancelled"
        case .failed(let why): return why
        }
    }
}

public struct ModelsReply<Value: Codable & Sendable>: Codable, Sendable {
    public var value: Value?
    public var failure: ModelsFailure?
    public init(value: Value) { self.value = value }
    public init(failure: ModelsFailure) { self.failure = failure }
}

/// What the service holds, for the app's memory line.
public struct ModelsStats: Codable, Sendable, Equatable {
    public var pid: Int32
    public var footprintMB: Int
    /// What MLX holds, or nil before anything in this run touched MLX.
    public var mlxActiveMB: Int?
    public var mlxCacheMB: Int?
    public var languageModels: Int
    public var ear: Bool

    public init(pid: Int32, footprintMB: Int, mlxActiveMB: Int?, mlxCacheMB: Int?, languageModels: Int, ear: Bool) {
        self.pid = pid
        self.footprintMB = footprintMB
        self.mlxActiveMB = mlxActiveMB
        self.mlxCacheMB = mlxCacheMB
        self.languageModels = languageModels
        self.ear = ear
    }
}

public struct ModelsCheck: Codable, Sendable, Equatable {
    public var pid: Int32
    /// What the evaluation said, with the device it ran on.
    public var answer: String
    public init(pid: Int32, answer: String) {
        self.pid = pid
        self.answer = answer
    }
}

// MARK: - The engine the service drives

/// A language model the service loaded.
public protocol ServedLanguageModel: Sendable {
    func respond(to sentence: String, instructions: String) async throws -> String
    func rewrite(_ text: String, prompt: IntentPass.Prompt) async throws -> String
    func warm(_ prompt: IntentPass.Prompt) async throws
}

/// The ear the service loaded. It takes the MLX lane itself (`QwenEar`).
public protocol ServedEar: Sendable {
    func transcribe(_ samples: [Float], context: [String]) async throws -> Heard
    func unload()
}

/// What runs the models: MLX in the service (`MLXModelsEngine`), a fake in
/// the tests. Language-model work and `clearCache` and `check` are called
/// holding the lane.
public protocol ModelsEngine: Sendable {
    func loadLanguageModel(_ spec: LanguageModelSpec) async throws -> any ServedLanguageModel
    func loadEar(_ spec: EarSpec) async throws -> any ServedEar
    func clearCache()
    /// MLX's active and cached memory in MB, or nil before MLX was touched.
    func memory() -> (activeMB: Int, cacheMB: Int)?
    func check() throws -> String
}

// MARK: - The service

/// The object the models service exports, one for the process, whatever
/// connections reach it.
///
/// Nothing here ever blocks the connection's queue: each request becomes a
/// task, so `cancel` and `exit` are heard while a generation runs. Every
/// language-model request takes the process's MLX lane (`MLXGate.shared` in
/// the service), which the ear's own evaluations take too, so MLX never
/// evaluates on two threads at once. The lane is not timed here: the app
/// times its questions from the moment it holds its own lane, and a
/// generation that has stopped answering is the app's to end, by `exit`.
///
/// A service that holds nothing ends itself after `endsWhenEmptyAfter`:
/// every page MLX and Metal held goes with the process, which letting a
/// model go cannot promise, and launchd starts it again at the next load.
public final class ModelsService: NSObject, ModelsXPC, @unchecked Sendable {
    public static let endsWhenEmptyAfter: TimeInterval = 10

    private let engine: any ModelsEngine
    private let gate: MLXGate
    private let endsWhenEmptyAfter: TimeInterval?
    private let onExit: @Sendable (String) -> Void
    /// `exit` runs here and nowhere else, so nothing a generation holds
    /// stands in front of it.
    private let exitQueue = DispatchQueue(label: "com.vaccone.lodestar.models.exit")

    private struct Loaded {
        let model: any ServedLanguageModel
        let owner: ObjectIdentifier?
    }

    private struct State {
        var models: [String: Loaded] = [:]
        var ear: (any ServedEar)?
        var earSpec: EarSpec?
        var earOwner: ObjectIdentifier?
        /// Moves at every unload, so a load the unload overtook is let go
        /// when it lands instead of holding its memory for no one.
        var earGeneration = 0
        var tasks: [Int64: Task<Void, Never>] = [:]
        /// Cancels that came before their request.
        var cancelledEarly: [Int64] = []
        var inFlight = 0
        var emptyTicket = 0
        var ended = false
    }

    private let state = Mutex(State())

    /// `onExit` ends the process: `_exit`, so no destructor of MLX's runs
    /// against a thread still inside it.
    public init(engine: any ModelsEngine, gate: MLXGate = .shared,
                endsWhenEmptyAfter: TimeInterval? = ModelsService.endsWhenEmptyAfter,
                onExit: @escaping @Sendable (String) -> Void = { reason in
                    Log.info("models", ["ended": reason])
                    _exit(0)
                }) {
        self.engine = engine
        self.gate = gate
        self.endsWhenEmptyAfter = endsWhenEmptyAfter
        self.onExit = onExit
    }

    // MARK: Language models

    public func loadLanguageModel(_ request: Data, reply: @escaping @Sendable (Data?) -> Void) {
        guard let request = Models.decode(LanguageModelLoad.self, from: request) else {
            return reply(Models.encode(ModelsReply<String>(failure: .failed("unreadable request"))))
        }
        let owner = NSXPCConnection.current().map(ObjectIdentifier.init)
        let engine = self.engine
        run(request.id, gated: true, reply: reply) { [self] () -> String in
            let started = Date()
            let model = try await engine.loadLanguageModel(request.spec)
            // Given up on while it loaded: nobody will ask it anything.
            guard !Task.isCancelled else {
                engine.clearCache()
                throw CancellationError()
            }
            let handle = UUID().uuidString
            state.withLock { $0.models[handle] = Loaded(model: model, owner: owner) }
            Log.info("models", ["loaded": request.spec.label, "ms": Int(Date().timeIntervalSince(started) * 1000)])
            return handle
        }
    }

    public func respond(_ request: Data, reply: @escaping @Sendable (Data?) -> Void) {
        generate(request, reply: reply) { model, request in
            try await model.respond(to: request.text, instructions: request.prompt.instructions)
        }
    }

    public func rewrite(_ request: Data, reply: @escaping @Sendable (Data?) -> Void) {
        generate(request, reply: reply) { model, request in
            try await model.rewrite(request.text, prompt: request.prompt)
        }
    }

    public func warm(_ request: Data, reply: @escaping @Sendable (Data?) -> Void) {
        generate(request, reply: reply) { model, request in
            try await model.warm(request.prompt)
            return true
        }
    }

    private func generate<T: Codable & Sendable>(
        _ body: Data, reply: @escaping @Sendable (Data?) -> Void,
        _ work: @escaping @Sendable (any ServedLanguageModel, ModelsGenerate) async throws -> T
    ) {
        guard let request = Models.decode(ModelsGenerate.self, from: body) else {
            return reply(Models.encode(ModelsReply<T>(failure: .failed("unreadable request"))))
        }
        run(request.id, gated: true, reply: reply) { [self] () -> T in
            guard let model = state.withLock({ $0.models[request.handle]?.model }) else {
                throw ModelsFailure.notLoaded
            }
            return try await work(model, request)
        }
    }

    /// Lets the model go. A generation still running on it keeps it until
    /// it stops; the buffers MLX kept are cleared on the lane.
    public func releaseLanguageModel(_ handle: String) {
        let gone = state.withLock { $0.models.removeValue(forKey: handle) }
        guard gone != nil else { return }
        clearSoon()
        Log.info("models", ["released": true, "held": state.withLock { $0.models.count }])
        settle()
    }

    private func clearSoon() {
        let engine = self.engine
        let gate = self.gate
        Task { _ = await gate.run { engine.clearCache() } }
    }

    // MARK: The ear

    public func loadEar(_ request: Data, reply: @escaping @Sendable (Data?) -> Void) {
        guard let request = Models.decode(EarLoad.self, from: request) else {
            return reply(Models.encode(ModelsReply<Bool>(failure: .failed("unreadable request"))))
        }
        let owner = NSXPCConnection.current().map(ObjectIdentifier.init)
        let engine = self.engine
        let generation = state.withLock { $0.earGeneration }
        run(request.id, gated: false, reply: reply) { [self] () -> Bool in
            if state.withLock({ $0.ear != nil && $0.earSpec == request.spec }) { return true }
            let ear = try await engine.loadEar(request.spec)
            let (kept, old) = state.withLock { state -> (Bool, (any ServedEar)?) in
                guard state.earGeneration == generation else { return (false, nil) }
                defer {
                    state.ear = ear
                    state.earSpec = request.spec
                    state.earOwner = owner
                }
                return (true, state.ear)
            }
            old?.unload()
            guard kept else {
                ear.unload()
                throw ModelsFailure.cancelled
            }
            return true
        }
    }

    public func transcribe(_ request: Data, reply: @escaping @Sendable (Data?) -> Void) {
        guard let request = Models.decode(EarTranscribe.self, from: request) else {
            return reply(Models.encode(ModelsReply<Heard>(failure: .failed("unreadable request"))))
        }
        run(request.id, gated: false, reply: reply) { [self] () -> Heard in
            guard let ear = state.withLock({ $0.ear }) else { throw ModelsFailure.notLoaded }
            return try await ear.transcribe(Models.samples(request.samples), context: request.context)
        }
    }

    public func unloadEar() {
        let ear = state.withLock { state -> (any ServedEar)? in
            defer {
                state.ear = nil
                state.earSpec = nil
                state.earOwner = nil
                state.earGeneration += 1
            }
            return state.ear
        }
        ear?.unload()
        settle()
    }

    // MARK: Asking about it

    public func cancel(_ id: Int64) {
        let task = state.withLock { state -> Task<Void, Never>? in
            if let task = state.tasks[id] { return task }
            state.cancelledEarly.append(id)
            if state.cancelledEarly.count > 64 { state.cancelledEarly.removeFirst() }
            return nil
        }
        task?.cancel()
    }

    public func stats(reply: @escaping @Sendable (Data?) -> Void) {
        let (models, ear) = state.withLock { ($0.models.count, $0.ear != nil) }
        let memory = engine.memory()
        reply(Models.encode(ModelsStats(pid: getpid(), footprintMB: MemoryReport.ownFootprintMB().now,
                                        mlxActiveMB: memory?.activeMB, mlxCacheMB: memory?.cacheMB,
                                        languageModels: models, ear: ear)))
    }

    public func check(reply: @escaping @Sendable (Data?) -> Void) {
        let engine = self.engine
        run(nil, gated: true, reply: reply) { () -> ModelsCheck in
            ModelsCheck(pid: getpid(), answer: try engine.check())
        }
    }

    public func exit(_ reason: String) {
        let onExit = self.onExit
        exitQueue.async { onExit(reason) }
    }

    /// A connection ended (its app quit, or let it go): what it loaded goes.
    public func connectionEnded(_ connection: NSXPCConnection) {
        let owner = ObjectIdentifier(connection)
        let (models, ear) = state.withLock { state -> (Int, (any ServedEar)?) in
            let mine = state.models.filter { $0.value.owner == owner }.map(\.key)
            for handle in mine { state.models.removeValue(forKey: handle) }
            var ear: (any ServedEar)?
            if state.earOwner == owner {
                ear = state.ear
                state.ear = nil
                state.earSpec = nil
                state.earOwner = nil
            }
            return (mine.count, ear)
        }
        ear?.unload()
        if models > 0 { clearSoon() }
        settle()
    }

    // MARK: The work

    /// Runs `work` as a task of its own, holding the lane when `gated`, and
    /// replies once with its answer or why there is none. A request whose
    /// cancel came first is refused without running.
    private func run<T: Codable & Sendable>(_ id: Int64?, gated: Bool, reply: @escaping @Sendable (Data?) -> Void,
                                            _ work: @escaping @Sendable () async throws -> T) {
        let gate = self.gate
        let refused = state.withLock { state -> Bool in
            if let id, let index = state.cancelledEarly.firstIndex(of: id) {
                state.cancelledEarly.remove(at: index)
                return true
            }
            state.inFlight += 1
            state.emptyTicket += 1
            return false
        }
        if refused { return reply(Models.encode(ModelsReply<T>(failure: .cancelled))) }
        // Made and filed under the lock, so it cannot finish, and unfile
        // itself, before it is filed.
        state.withLock { state in
            let task = Task { [self] in
                defer { finished(id) }
                var permit: MLXGate.Permit?
                if gated {
                    permit = await gate.acquire()
                    guard permit != nil else {
                        return reply(Models.encode(ModelsReply<T>(failure: .cancelled)))
                    }
                }
                let answer: ModelsReply<T>
                do {
                    try Task.checkCancellation()
                    answer = ModelsReply(value: try await work())
                } catch let failure as ModelsFailure {
                    answer = ModelsReply(failure: failure)
                } catch {
                    answer = ModelsReply(failure: Task.isCancelled || error is CancellationError
                                         ? .cancelled : .failed("\(error)"))
                }
                if let permit { gate.release(permit) }
                reply(Models.encode(answer))
            }
            if let id { state.tasks[id] = task }
        }
    }

    private func finished(_ id: Int64?) {
        state.withLock { state in
            if let id { state.tasks.removeValue(forKey: id) }
            state.inFlight -= 1
        }
        settle()
    }

    /// Holding nothing and asked nothing: end after a while, unless asked
    /// something meanwhile.
    private func settle() {
        guard let after = endsWhenEmptyAfter else { return }
        let ticket = state.withLock { state -> Int? in
            guard state.models.isEmpty, state.ear == nil, state.inFlight == 0, !state.ended else { return nil }
            state.emptyTicket += 1
            return state.emptyTicket
        }
        guard let ticket else { return }
        let onExit = self.onExit
        exitQueue.asyncAfter(deadline: .now() + after) { [self] in
            let still = state.withLock { state -> Bool in
                guard state.emptyTicket == ticket, state.models.isEmpty, state.ear == nil,
                      state.inFlight == 0, !state.ended else { return false }
                state.ended = true
                return true
            }
            if still { onExit("holds nothing") }
        }
    }
}
