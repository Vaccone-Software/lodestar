import Foundation
import StoicXPC
import Synchronization

// The models service's side: the handlers `XPCHost` runs for the methods
// `ModelsAPI` declares, over an engine (MLX in the service, a fake in the
// tests).
//
// What the library decides is not decided here: each request runs in its
// own task under the deadline its caller had left, a cancel stops it, a
// request the caller cancelled first is never run, a handler that ignores
// its cancellation ends the process (the host's watchdog), and a service
// that holds nothing and is asked nothing ends itself (`idleExit`). What is
// Lodestar's own stays: the process's one MLX lane, which every language
// model request and the ear's own evaluations pass through so MLX never
// evaluates on two threads at once, and what the service keeps loaded.
//
// A loaded model or ear is a reason the host is held for (`hold`/`release`),
// so a service that holds one never idles out under it, and one that holds
// nothing ends itself and takes every page MLX and Metal held with it. There
// is one app per service process, so what the service holds is what that
// app loaded, and it goes with the process.

/// The object the models service exports, one for the process.
public final class ModelsService: Sendable {
    private let engine: any ModelsEngine
    private let gate: MLXGate
    private weak let host: XPCHost?

    private struct State {
        var models: [String: any ServedLanguageModel] = [:]
        var ear: (any ServedEar)?
        var earSpec: EarSpec?
        /// Moves at every unload, so a load the unload overtook is let go
        /// when it lands instead of holding its memory for no one.
        var earGeneration = 0
    }

    private let state = Mutex(State())

    /// Registers every method of `ModelsAPI` on `host`.
    public init(host: XPCHost, engine: any ModelsEngine, gate: MLXGate = .shared) {
        self.engine = engine
        self.gate = gate
        self.host = host
        host.handle(ModelsAPI.loadLanguageModel) { [self] spec, _ throws(ModelsFailure) in try await loadLanguageModel(spec) }
        host.handle(ModelsAPI.respond) { [self] request, _ throws(ModelsFailure) in
            try await generate(request) { model, request in
                try await model.respond(to: request.text, instructions: request.prompt.instructions)
            }
        }
        host.handle(ModelsAPI.rewrite) { [self] request, _ throws(ModelsFailure) in
            try await generate(request) { model, request in try await model.rewrite(request.text, prompt: request.prompt) }
        }
        host.handle(ModelsAPI.warm) { [self] request, _ throws(ModelsFailure) in
            try await generate(request) { model, request in
                try await model.warm(request.prompt)
                return XPCEmpty()
            }
        }
        host.handle(ModelsAPI.releaseLanguageModel) { [self] handle, _ in
            releaseLanguageModel(handle)
            return XPCEmpty()
        }
        host.handle(ModelsAPI.loadEar) { [self] spec, _ throws(ModelsFailure) in try await loadEar(spec) }
        host.handle(ModelsAPI.transcribe) { [self] request, _ throws(ModelsFailure) in try await transcribe(request) }
        host.handle(ModelsAPI.unloadEar) { [self] _, _ in
            unloadEar()
            return XPCEmpty()
        }
        host.handle(ModelsAPI.stats) { [self] _, _ in stats() }
        host.handle(ModelsAPI.check) { [self] _, _ throws(ModelsFailure) in
            let engine = self.engine
            return try await onLane(gated: true) { ModelsCheck(pid: getpid(), answer: try engine.check()) }
        }
    }

    // MARK: Language models

    private func loadLanguageModel(_ spec: LanguageModelSpec) async throws(ModelsFailure) -> String {
        try await onLane(gated: true) { [self] () async throws -> String in
            let started = ContinuousClock.now
            let model = try await engine.loadLanguageModel(spec)
            // Given up on while it loaded: nobody will ask it anything.
            guard !Task.isCancelled else {
                engine.clearCache()
                throw CancellationError()
            }
            let handle = UUID().uuidString
            state.withLock { $0.models[handle] = model }
            host?.hold(Self.reason(handle))
            Log.info("models", ["loaded": spec.label, "ms": Int(started.secondsElapsed * 1000)])
            return handle
        }
    }

    private func generate<T: Sendable>(
        _ request: ModelsGenerate, _ work: @escaping @Sendable (any ServedLanguageModel, ModelsGenerate) async throws -> T
    ) async throws(ModelsFailure) -> T {
        try await onLane(gated: true) { [self] () async throws -> T in
            guard let model = state.withLock({ $0.models[request.handle] }) else { throw ModelsFailure.notLoaded }
            return try await work(model, request)
        }
    }

    /// Lets the model go. A generation still running on it keeps it until
    /// it stops; the buffers MLX kept are cleared on the lane.
    private func releaseLanguageModel(_ handle: String) {
        let gone = state.withLock { $0.models.removeValue(forKey: handle) }
        guard gone != nil else { return }
        clearSoon()
        Log.info("models", ["released": true, "held": state.withLock { $0.models.count }])
        host?.release(Self.reason(handle))
    }

    private func clearSoon() {
        let engine = self.engine
        let gate = self.gate
        Task { _ = await gate.run { engine.clearCache() } }
    }

    private static func reason(_ handle: String) -> String { "language model \(handle)" }
    private static let earReason = "ear"

    // MARK: The ear

    private func loadEar(_ spec: EarSpec) async throws(ModelsFailure) -> XPCEmpty {
        let generation = state.withLock { $0.earGeneration }
        return try await onLane(gated: false) { [self] () async throws -> XPCEmpty in
            if state.withLock({ $0.ear != nil && $0.earSpec == spec }) { return XPCEmpty() }
            let ear = try await engine.loadEar(spec)
            let (kept, old) = state.withLock { state -> (Bool, (any ServedEar)?) in
                guard state.earGeneration == generation else { return (false, nil) }
                defer {
                    state.ear = ear
                    state.earSpec = spec
                }
                return (true, state.ear)
            }
            old?.unload()
            guard kept else {
                ear.unload()
                throw ModelsFailure.cancelled
            }
            host?.hold(Self.earReason)
            return XPCEmpty()
        }
    }

    private func transcribe(_ request: EarTranscribe) async throws(ModelsFailure) -> Heard {
        try await onLane(gated: false) { [self] () async throws -> Heard in
            guard let ear = state.withLock({ $0.ear }) else { throw ModelsFailure.notLoaded }
            return try await ear.transcribe(Models.samples(request.samples), context: request.context)
        }
    }

    private func unloadEar() {
        let ear = state.withLock { state -> (any ServedEar)? in
            defer {
                state.ear = nil
                state.earSpec = nil
                state.earGeneration += 1
            }
            return state.ear
        }
        ear?.unload()
        host?.release(Self.earReason)
    }

    // MARK: Asking about it

    private func stats() -> ModelsStats {
        let (models, ear) = state.withLock { ($0.models.count, $0.ear != nil) }
        let memory = engine.memory()
        return ModelsStats(pid: getpid(), footprintMB: MemoryReport.ownFootprintMB().now,
                           mlxActiveMB: memory?.activeMB, mlxCacheMB: memory?.cacheMB,
                           languageModels: models, ear: ear)
    }

    // MARK: The lane

    /// Runs `work`, holding the process's MLX lane when `gated`, and says
    /// why there is no answer in the library's one failure type: the work's
    /// own `ModelsFailure`, or the words of the error. A cancelled request
    /// the host answers itself, whatever this throws.
    private func onLane<T: Sendable>(
        gated: Bool, _ work: @Sendable () async throws -> T
    ) async throws(ModelsFailure) -> T {
        var permit: MLXGate.Permit?
        if gated {
            permit = await gate.acquire()
            guard permit != nil else { throw .cancelled }
        }
        defer { if let permit { gate.release(permit) } }
        do {
            try Task.checkCancellation()
            return try await work()
        } catch let failure as ModelsFailure {
            throw failure
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .failed("\(error)")
        }
    }
}
