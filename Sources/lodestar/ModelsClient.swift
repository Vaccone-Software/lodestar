import Foundation
import LodestarCore
import LodestarEars
import Stoic
import StoicXPC
import Synchronization

/// Why a request to the models service has no answer, besides the
/// service's own reasons (`ModelsFailure`): `ModelsClient.mapped` says which
/// of the transport's failures (`XPCCallError`) is which.
enum ModelsError: Error, CustomStringConvertible {
    /// The service ended (it crashed, was ended, or launchd let it go)
    /// before it answered.
    case interrupted
    /// It answered something this build cannot read, or refused a request
    /// this build sent: a bug, not a state.
    case unreadable
    /// It did not answer in time.
    case timedOut(String)
    /// No service could be had: it is not in the bundle, did not start, or
    /// would not exit; or it is another build than this app.
    case unavailable(String)

    var description: String {
        switch self {
        case .interrupted: return "the models service ended before it answered"
        case .unreadable: return "the models service answered something unreadable"
        case .timedOut(let what): return what
        case .unavailable(let why): return "the models service is unavailable: \(why)"
        }
    }
}

/// The app's side of the models service (LodestarModels, in
/// Contents/XPCServices): every model that evaluates on MLX is asked here,
/// and runs there.
///
/// The transport is an `XPCPeer` (StoicXPC, design/25): it starts the
/// service when a call needs it, never sends to a process that is exiting,
/// waits out one that is, repeats a call by its method's declared repeat
/// safety, ends the service when a request its caller gave up on stays
/// unanswered (`ModelsAPI`'s `ifStuck`), and fails every call waiting on a
/// run the moment the run is lost. What is left here is what is Lodestar's:
///
/// - What the app has loaded in the service. A service may end at any
///   moment and holds nothing of what it had, so each model and the ear is
///   remembered with the run of the service that holds it (the peer's run
///   number), and is lost once that is no longer the live run: its owner
///   lets it go and loads again at the next request. A request for a handle
///   the service no longer holds answers `notLoaded`, which says the same
///   when the app could not tell. (The peer will keep state a service holds
///   and load it again when its run is lost, once `PeerResident` exists;
///   this is shaped to move there: a table of what is held, by run.)
/// - What a failure means to the editor and dictation (`mapped`).
/// - That a reading of the service's memory never starts it.
final class ModelsClient: Sendable {
    static let shared = ModelsClient()

    /// The one peer of the models service in this process (design/25,
    /// rule 2). Tests make their own, over a simulated service.
    let peer: XPCPeer

    /// What this app has loaded in the service, and on which run.
    private struct Resident {
        var handles: [String: Int] = [:]
        var ear: Int?
    }

    private let resident = Mutex(Resident())

    init(peer: XPCPeer = XPCPeer(service: Models.serviceName, build: Build.id)) {
        self.peer = peer
    }

    /// The live run's number: what a model or the ear was loaded on, or no
    /// longer is. Nil while there is no run (never started, or lost and not
    /// yet started again).
    var run: Int? { peer.run?.number }

    /// Does the service hold anything this app loaded? Nothing asks a
    /// service that holds nothing, so a reading never starts one.
    var holds: Bool {
        guard let live = run else { return false }
        return resident.withLock { $0.handles.values.contains(live) || $0.ear == live }
    }

    // MARK: Language models

    func loadLanguageModel(_ spec: LanguageModelSpec) async throws -> ServiceLanguageModel {
        let handle = try await call(ModelsAPI.loadLanguageModel, spec)
        // The run that answered. Were it lost between its reply and here,
        // this is nil or a later run's, and the model's first request is
        // answered `notLoaded`, which makes the same decision.
        let run = self.run
        resident.withLock { resident in
            guard let run else { return }
            resident.handles = resident.handles.filter { $0.value == run }
            resident.handles[handle] = run
        }
        return ServiceLanguageModel(client: self, handle: handle, run: run, label: spec.label)
    }

    func respond(_ handle: String, to sentence: String, instructions: String) async throws -> String {
        try await call(ModelsAPI.respond, ModelsGenerate(
            handle: handle, text: sentence, prompt: IntentPass.Prompt(instructions: instructions, examples: [])))
    }

    func rewrite(_ handle: String, _ text: String, prompt: IntentPass.Prompt) async throws -> String {
        try await call(ModelsAPI.rewrite, ModelsGenerate(handle: handle, text: text, prompt: prompt))
    }

    func warm(_ handle: String, prompt: IntentPass.Prompt) async throws {
        _ = try await call(ModelsAPI.warm, ModelsGenerate(handle: handle, text: "", prompt: prompt))
    }

    /// The service lets the model go, if it is the service that holds it: a
    /// release never starts a service.
    func release(_ handle: String, run: Int?) {
        let held = resident.withLock { $0.handles.removeValue(forKey: handle) != nil }
        guard held, let run, run == self.run else { return }
        let peer = self.peer
        releasing.withLock { $0 += 1 }
        Task { [self] in
            await Log.attempt("models: could not tell the service to release a language model") {
                try await peer.call(ModelsAPI.releaseLanguageModel, handle, ifRunning: true)
            }
            releasing.withLock { $0 -= 1 }
        }
    }

    /// Releases sent and not yet answered. A release is sent from a task of
    /// its own, since a model lets go in its deinit, so this is the one way
    /// to know it is over: a test waits for it before moving its clock.
    var releasesInFlight: Int { releasing.withLock { $0 } }
    private let releasing = Mutex(0)

    // MARK: The ear

    /// Loads the ear; the run it was loaded on, nil if that run was lost
    /// before the answer was read.
    func loadEar(_ spec: EarSpec) async throws -> Int? {
        _ = try await call(ModelsAPI.loadEar, spec)
        let run = self.run
        resident.withLock { resident in resident.ear = run }
        return run
    }

    func transcribe(_ samples: [Float], context: [String]) async throws -> Heard {
        try await call(ModelsAPI.transcribe, EarTranscribe(samples: Models.bytes(samples), context: context))
    }

    func unloadEar() {
        let run = resident.withLock { resident -> Int? in
            defer { resident.ear = nil }
            return resident.ear
        }
        guard let run, run == self.run else { return }
        let peer = self.peer
        Task {
            await Log.attempt("models: could not tell the service to unload the ear") {
                try await peer.call(ModelsAPI.unloadEar, XPCEmpty(), ifRunning: true)
            }
        }
    }

    // MARK: Asking about it

    /// What the service holds, for the memory line: nil, at once, when it
    /// holds nothing of ours, and nil after `timeout` when it does not say.
    /// Blocks the calling thread, so never call it on main.
    func memoryReading(timeout: TimeInterval = 1) -> ModelsStats? {
        guard holds else { return nil }
        let answer = Mailbox<ModelsStats?>()
        Task {
            answer.put(try? await withTimeout(.seconds(timeout)) { try await self.stats(ifRunning: true) })
        }
        return answer.take(within: timeout + 1) ?? nil
    }

    /// The same, starting the service if it must (`ifRunning` false): for
    /// `editor check`.
    func stats(ifRunning: Bool = false) async throws -> ModelsStats {
        try await call(ModelsAPI.stats, XPCEmpty(), ifRunning: ifRunning)
    }

    /// The service started, and evaluated on the GPU with the kernels its
    /// bundle carries: the self-test's question. It is also the first call
    /// of the signed bundle, so the build handshake has passed if it answers.
    func check() async throws -> ModelsCheck {
        try await call(ModelsAPI.check, XPCEmpty())
    }

    // MARK: The call

    private func call<Request, Reply, Failure>(
        _ method: XPCMethod<Request, Reply, Failure>, _ request: Request, ifRunning: Bool = false
    ) async throws -> Reply {
        do throws(OperationError<XPCCallError<Failure>>) {
            return try await peer.call(method, request, ifRunning: ifRunning)
        } catch {
            throw Self.mapped(error)
        }
    }

    /// What a failed call is to the editor and dictation, which already
    /// know four things: the service said it holds no such model
    /// (`ModelsFailure.notLoaded`, which means load again); the caller gave
    /// up (`CancellationError`); the service ended before it answered
    /// (`ModelsError.interrupted`: whatever was loaded in it is lost, which
    /// `run` says); and it did not answer in time.
    static func mapped<Failure: Error & Sendable>(_ error: OperationError<XPCCallError<Failure>>) -> any Error {
        switch error.stop {
        case .cancelled:
            return CancellationError()
        case .rejected(let rejection):
            return rejection.reason == .deadlineExceeded
                ? ModelsError.timedOut("the models service did not answer in time")
                : ModelsError.unavailable("\(rejection)")
        case .failed(let call):
            switch call {
            case .failed(let failure):
                if let failure = failure as? ModelsFailure {
                    return failure == .cancelled ? CancellationError() : failure
                }
                return failure
            case .lost, .ended:
                return ModelsError.interrupted
            case .cancelled:
                return CancellationError()
            case .notRunning:
                return ModelsError.unavailable("it is not running")
            case .buildMismatch(let expected, let found):
                return ModelsError.unavailable("it is build \(found) and this app is build \(expected): restart Lodestar")
            case .unavailable(let why):
                return ModelsError.unavailable("\(why)")
            case .refused, .protocolViolation:
                return ModelsError.unreadable
            }
        }
    }

    /// A value handed from a task to a thread that waits for it.
    private final class Mailbox<Value: Sendable>: Sendable {
        private let value = Mutex<Value?>(nil)
        private let ready = DispatchSemaphore(value: 0)
        func put(_ value: Value) {
            self.value.withLock { $0 = value }
            ready.signal()
        }
        func take(within timeout: TimeInterval) -> Value? {
            guard ready.wait(timeout: .now() + timeout) == .success else { return nil }
            return value.withLock { $0 }
        }
    }
}

/// A language model loaded in the models service, asked through it: the
/// editor's and the draft's backend for Standard and Full. Letting the last
/// reference go lets the model go in the service.
final class ServiceLanguageModel: EditorBackend, Sendable {
    let client: ModelsClient
    let handle: String
    /// The run of the service that holds it, nil if that run was lost
    /// before its load's answer was read.
    let run: Int?
    let label: String
    private let refused = Mutex(false)

    init(client: ModelsClient, handle: String, run: Int?, label: String) {
        self.client = client
        self.handle = handle
        self.run = run
        self.label = label
    }

    /// The service it was loaded in has ended, or said it no longer holds it.
    var isLost: Bool { refused.withLock { $0 } || run == nil || client.run != run }

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
            refused.withLock { $0 = true }
            throw ModelsFailure.notLoaded
        }
    }

    deinit { client.release(handle, run: run) }
}

/// The Qwen3-ASR ear, heard in the models service. Each load and phrase
/// takes the app's MLX lane first, as the ear took it in the app, so the
/// editor's sentence never counts an ear's phrase against its own
/// deadline; in the service the ear takes the service's lane too. A phrase
/// or load that does not come back in time is cancelled in the service, and
/// the service is ended if it does not stop (`ModelsAPI.transcribe`'s
/// `ifStuck`): the only way a stuck evaluation stops. After the service
/// ended, the ear is no longer loaded, and the next phrase loads it again
/// first.
final class ServiceEar: SettlingEar, Sendable {
    let name: String
    let folder: URL
    private let client: ModelsClient
    private let gate: MLXGate
    /// The slowest phrase logged took nine seconds, a cold load a few.
    let loadDeadline: TimeInterval
    let phraseDeadline: TimeInterval
    /// Loaded and not unloaded since: a phrase may load it again.
    private struct Loading {
        var wanted = false
        var loadedRun: Int?
    }
    private let loading = Mutex(Loading())

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
        let loaded = loading.withLock { $0.loadedRun }
        return loaded != nil && loaded == client.run
    }

    func load() async throws {
        loading.withLock { $0.wanted = true }
        let spec = EarSpec(name: name, directory: folder.path)
        let run = try await laned(loadDeadline, "the ear did not load") { try await self.client.loadEar(spec) }
        loading.withLock { if $0.wanted { $0.loadedRun = run } }
    }

    func transcribe(_ samples: [Float], context: [String]) async throws -> Heard {
        if !isLoaded {
            guard loading.withLock({ $0.wanted }) else { throw ModelsFailure.notLoaded }
            Log.info("draft", ["ear": name, "loading again": "the models service started afresh"])
            try await load()
        }
        do {
            return try await laned(phraseDeadline, "the ear did not hear a phrase") {
                try await self.client.transcribe(samples, context: context)
            }
        } catch ModelsFailure.notLoaded {
            loading.withLock { $0.loadedRun = nil }
            throw ModelsFailure.notLoaded
        }
    }

    func unload() {
        loading.withLock {
            $0.wanted = false
            $0.loadedRun = nil
        }
        client.unloadEar()
    }

    /// `work` holding the app's lane, under `deadline`.
    private func laned<T: Sendable>(_ deadline: TimeInterval, _ what: String,
                                    _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let permit = await gate.acquire() else { throw CancellationError() }
        defer { gate.release(permit) }
        do {
            return try await withTimeout(.seconds(deadline)) { try await work() }
        } catch ModelsError.timedOut {
            let why = "\(what) in \(Int(deadline)) s"
            Log.error("draft: \(why)")
            throw ModelsError.timedOut(why)
        }
    }
}
