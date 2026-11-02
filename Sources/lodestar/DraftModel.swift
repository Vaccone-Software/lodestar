import Foundation
import LodestarCore
import LodestarEars
import MLX

/// The language model dictation asks what was meant (`IntentPass`), one
/// per Speak tier, chosen there and nowhere else: what Write runs never
/// decides it. Measured on the maker's 60 recordings after the full
/// pipeline (6.1% of words wrong), checked: Gemma 4 E2B 4.6%, Qwen3.6 35B
/// 3.9%. Qwen3 1.7B (4.8%) was tried for small Macs and dropped with them:
/// on the hand-written set it got 11 of 28 right against Gemma's 25.
enum CleanupModel: String, CaseIterable {
    case gemma
    case qwen36

    var name: String {
        switch self {
        case .gemma: return "Gemma 4 E2B"
        case .qwen36: return "Qwen3.6 35B"
        }
    }

    var manifest: EditorManifest {
        switch self {
        case .gemma: return .standard
        case .qwen36: return .full
        }
    }

    /// The editor's engine that runs these same weights:
    /// then the two share one copy, on disk and, while both want it, in
    /// memory.
    var editorEngine: EditorEngine {
        switch self {
        case .gemma: return .standard
        case .qwen36: return .full
        }
    }

    /// Qwen thinks unless told not to; a reasoning trace is not a sentence.
    var additionalContext: [String: any Sendable]? {
        self == .gemma ? nil : ["enable_thinking": false]
    }
}

extension EarTier {
    /// The row's line for the tier: the models it runs, so the choice says
    /// what it holds, or the memory this Mac lacks for it.
    func label(memoryGB: Double) -> String {
        guard self != .apple else { return name }
        if memoryGB < memoryNeeded - 1 { return "\(name) · needs \(Int(memoryNeeded)) GB" }
        let ear = self == .standard ? "Parakeet" : "Qwen3-ASR"
        return "\(name) · \(ear) and \(cleanup?.name ?? "")"
    }

    /// The model this tier writes what was meant with. Apple only has none:
    /// the settler's cue rule is all it does.
    var cleanup: CleanupModel? {
        switch self {
        case .apple: return nil
        case .standard, .full: return .gemma
        case .max: return .qwen36
        }
    }
}

/// The draft's own copy of its model, held as the ear is: loaded when
/// dictation starts, let go when the ear rests. Used only when the editor
/// does not already hold the same weights.
///
/// Its loads, readings and rewrites take the process's MLX lane as the
/// editor's do (`ModelCalls`), so neither reads at the same moment as the
/// other or as the ear, and a generation that never comes back is let go of
/// with its backend rather than wedging the intent pass.
actor DraftModel {
    typealias Loader = @Sendable (CleanupModel) async throws -> any EditorBackend
    let model: CleanupModel
    private var backend: (any EditorBackend)?
    private var loading: Task<(any EditorBackend)?, Never>?
    private var warmed: Set<IntentPass.Prompt> = []
    private let loader: Loader
    private let clearCache: @Sendable () -> Void
    private let calls: ModelCalls
    /// A load's own deadline and wait for the GPU, as the editor's.
    let loadDeadline: TimeInterval

    init(model: CleanupModel, loadDeadline: TimeInterval = 60, stuckAfter: TimeInterval = 20,
         gate: MLXGate = .shared, loader: @escaping Loader = DraftModel.load,
         clearCache: @escaping @Sendable () -> Void = { MLX.Memory.clearCache() }) {
        self.model = model
        self.loadDeadline = loadDeadline
        self.calls = ModelCalls(name: "intent.model", gate: gate, stuckAfter: stuckAfter)
        self.loader = loader
        self.clearCache = clearCache
    }

    static let load: Loader = { model in
        guard let directory = EditorModels.directory(for: model.manifest) else {
            throw EditorModelError.unavailable("\(model.name) is not on this Mac")
        }
        return try await EditorModel.load(fromDirectory: directory, label: model.rawValue,
                                          additionalContext: model.additionalContext)
    }

    var isLoaded: Bool { backend != nil }

    /// Dictation started: the weights load now, once.
    func load() async {
        recoverIfStuck()
        if backend != nil { return }
        if let loading { _ = await loading.value; return }
        let began = Date()
        let model = self.model
        let loader = self.loader
        let calls = self.calls
        let clear = self.clearCache
        let deadline = loadDeadline
        let task = Task { () -> (any EditorBackend)? in
            let asked = await calls.ask(deadline: deadline, wait: deadline) { () -> Result<any EditorBackend, Error>? in
                calls.clearIfPending(clear)
                do { return .success(try await loader(model)) } catch { return .failure(error) }
            }
            switch asked {
            case .answer(.success(let backend)): return backend
            case .answer(.failure(let error)):
                Log.info("intent", ["model": model.rawValue, "load failed": "\(error)"])
            case .unanswered, .busy:
                Log.info("intent", ["model": model.rawValue, "load failed": "no answer in \(Int(deadline)) seconds"])
            }
            return nil
        }
        loading = task
        backend = await task.value
        loading = nil
        calls.loadEnded(succeeded: backend != nil)
        if backend != nil {
            calls.backendReplaced()
            Log.info("intent", ["model": model.rawValue, "loaded ms": Int(Date().timeIntervalSince(began) * 1000)])
        }
    }

    /// A generation that overran and has not stopped: its backend goes, and
    /// the next dictation loads another.
    private func recoverIfStuck() {
        let lost = calls.recoverIfStuck()
        guard lost > 0 else { return }
        backend = nil
        warmed = []
        calls.clearCacheSoon(clearCache)
        Log.info("intent", ["model": model.rawValue, "recovered": "the model stopped answering", "generations": lost])
    }

    /// As `EditorModel.rewrite`: never a load, the prompt's beginning read
    /// once with no deadline, then the answer under one.
    func rewrite(_ text: String, prompt: IntentPass.Prompt) async -> String? {
        recoverIfStuck()
        guard let backend else { return nil }
        if !warmed.contains(prompt) {
            let read = await calls.ask(deadline: EditorModel.warmDeadline, wait: EditorModel.warmWait) {
                (try? await backend.warm(prompt)).map { true }
            }
            guard read.value != nil else { return nil }
            warmed.insert(prompt)
            guard self.backend != nil else { return nil }
        }
        let began = Date()
        let answer = await calls.ask(deadline: EditorModel.rewriteDeadline, wait: EditorModel.rewriteWait) {
            try? await backend.rewrite(text, prompt: prompt)
        }.value
        Log.info("intent", ["asked": text.count, "answered": answer != nil,
                            "ms": Int(Date().timeIntervalSince(began) * 1000), "engine": model.rawValue])
        return answer
    }

    func release() {
        guard backend != nil else { return }
        backend = nil
        warmed = []
        calls.clearCacheSoon(clearCache)
        calls.backendReplaced()
        Log.info("intent", ["model": model.rawValue, "released": true])
    }
}
