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
actor DraftModel {
    typealias Loader = @Sendable (CleanupModel) async throws -> any EditorBackend
    let model: CleanupModel
    private var backend: (any EditorBackend)?
    private var loading: Task<(any EditorBackend)?, Never>?
    private var warmed: Set<IntentPass.Prompt> = []
    private let loader: Loader
    private let clearCache: @Sendable () -> Void

    init(model: CleanupModel, loader: @escaping Loader = DraftModel.load,
         clearCache: @escaping @Sendable () -> Void = { MLX.Memory.clearCache() }) {
        self.model = model
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
        if backend != nil { return }
        if let loading { _ = await loading.value; return }
        let began = Date()
        let model = self.model
        let loader = self.loader
        let task = Task { () -> (any EditorBackend)? in
            do { return try await loader(model) } catch {
                Log.info("intent", ["model": model.rawValue, "load failed": "\(error)"])
                return nil
            }
        }
        loading = task
        backend = await task.value
        loading = nil
        if backend != nil {
            Log.info("intent", ["model": model.rawValue, "loaded ms": Int(Date().timeIntervalSince(began) * 1000)])
        }
    }

    /// As `EditorModel.rewrite`: never a load, the prompt's beginning read
    /// once with no deadline, then the answer under one.
    func rewrite(_ text: String, prompt: IntentPass.Prompt) async -> String? {
        guard let backend else { return nil }
        if !warmed.contains(prompt) {
            do { try await backend.warm(prompt) } catch { return nil }
            warmed.insert(prompt)
            guard self.backend != nil else { return nil }
        }
        let began = Date()
        let answer = await EditorModel.within(EditorModel.rewriteDeadline) {
            try? await backend.rewrite(text, prompt: prompt)
        }
        Log.info("intent", ["asked": text.count, "answered": answer != nil,
                            "ms": Int(Date().timeIntervalSince(began) * 1000), "engine": model.rawValue])
        return answer
    }

    func release() {
        guard backend != nil else { return }
        backend = nil
        warmed = []
        clearCache()
        Log.info("intent", ["model": model.rawValue, "released": true])
    }
}
