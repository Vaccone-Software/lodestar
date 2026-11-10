import Foundation
import LodestarCore
import MLX
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// The editor's and dictation's language models on MLX, as the models
/// service (LodestarModels) runs them. The app never links this: it asks
/// the service, by the model's folder (`LanguageModelSpec`).
public enum MLXLanguageModels {
    /// Collapse MLX's global random key into a value.
    ///
    /// Building a model's layers draws their placeholder weights from the
    /// global key before the real weights replace them, and each draw
    /// swaps the key for an unevaluated split of the one before
    /// (`RandomState.next`). Nothing ever evaluates it, so every load
    /// lengthened a chain the process could not free: 1,084 links for one
    /// load of the full model, 17,344 after a morning, about 2.3 KB each,
    /// surviving every release. Measured: 20,000 links held 45 MB and one
    /// evaluation, 478 ms of it, let all but 1 MB go. Settled once per
    /// load, the chain never grows past one load's worth.
    public static func settleRandomState() {
        eval(MLXRandom.globalState)
    }

    /// A pinned model's weights from its folder.
    public static func load(_ spec: LanguageModelSpec) async throws -> MLXLanguageModel {
        MLXCap.apply()
        let container = try await LLMModelFactory.shared.loadContainer(
            from: URL(fileURLWithPath: spec.directory, isDirectory: true), using: #huggingFaceTokenizerLoader())
        settleRandomState()
        let context: [String: any Sendable]? = spec.context.isEmpty ? nil : spec.context.mapValues { $0 }
        return MLXLanguageModel(container: container, label: spec.label, additionalContext: context,
                                cachesInstructions: spec.cachesInstructions)
    }
}

/// Weights MLX loaded, with the instructions read once.
///
/// Every question starts with the same proofreader instructions, and a
/// model reading them afresh each time is most of a short sentence's cost.
/// So the prompt's shared beginning — the instructions and the user turn's
/// header, found as the common tokens of two rendered prompts — is run
/// through the model once, and each sentence starts from a copy of that
/// state and reads only its own words. A prompt that does not begin with
/// those tokens (a template that moved) is answered the whole way, as
/// before. The draft's intent pass reads its own instructions and worked
/// examples the same way, so a few prompts are held at once and neither
/// reader throws out the other's.
// stoic:allow(unchecked-sendable): `prefixes` and `prefixTried` are touched only by `ensurePrefix` and the cache lookup, both called only inside `container.perform`, which runs one closure at a time (ModelContainer keeps its context in a SerialAccessContainer); every other stored property is a `let`
public final class MLXLanguageModel: ServedLanguageModel, @unchecked Sendable {
    let container: ModelContainer
    let label: String
    let additionalContext: [String: any Sendable]?
    let cachesInstructions: Bool
    /// Each prompt's shared beginning and the model's state after reading
    /// it, the newest last. Built on a prompt's first question; touched
    /// only inside `container.perform`, which serializes access.
    private var prefixes: [(prompt: IntentPass.Prompt, tokens: [Int], cache: [KVCache])] = []
    /// The editor's instructions (one per spelling region) and the intent
    /// pass's (one per vocabulary): four covers a change of either.
    static let prefixesKept = 4
    /// Built once per prompt, or found not to fit once: never retried per
    /// question.
    private var prefixTried: Set<IntentPass.Prompt> = []

    init(container: ModelContainer, label: String, additionalContext: [String: any Sendable]?,
         cachesInstructions: Bool = true) {
        self.container = container
        self.label = label
        self.additionalContext = additionalContext
        self.cachesInstructions = cachesInstructions
    }

    private func parameters(for sentence: String) -> GenerateParameters {
        GenerateParameters(maxTokens: max(24, sentence.count / 2 + 16), temperature: 0)
    }

    public func respond(to sentence: String, instructions: String) async throws -> String {
        guard cachesInstructions else {
            let session = ChatSession(container, instructions: instructions,
                                      generateParameters: parameters(for: sentence),
                                      additionalContext: additionalContext)
            return try await session.respond(to: sentence)
        }
        let parameters = self.parameters(for: sentence)
        return try await answer(sentence, prompt: IntentPass.Prompt(instructions: instructions, examples: []),
                                parameters: { _ in parameters })
    }

    public func warm(_ prompt: IntentPass.Prompt) async throws {
        guard cachesInstructions else { return }
        let additional = additionalContext
        try await container.perform { (context: ModelContext) async throws in
            try await self.ensurePrefix(prompt, context: context, additional: additional,
                                        parameters: GenerateParameters(maxTokens: 24, temperature: 0))
        }
    }

    public func rewrite(_ text: String, prompt: IntentPass.Prompt) async throws -> String {
        try await answer(text, prompt: prompt, parameters: { count in
            GenerateParameters(maxTokens: IntentPass.maxTokens(forInputTokens: count), temperature: 0)
        })
    }

    /// The prompt's answer to `text`, from the cached state after its
    /// shared beginning when there is one. `parameters` is given the
    /// text's own length in tokens.
    private func answer(_ text: String, prompt: IntentPass.Prompt,
                        parameters: @escaping @Sendable (Int) -> GenerateParameters) async throws -> String {
        let additional = additionalContext
        let caching = cachesInstructions
        return try await container.perform { (context: ModelContext) async throws -> String in
            let parameters = parameters(context.tokenizer.encode(text: text, addSpecialTokens: false).count)
            let full = try await Self.tokens(text, prompt: prompt, context: context, additional: additional)
            if caching {
                try await self.ensurePrefix(prompt, context: context, additional: additional, parameters: parameters)
            }
            var cache: [KVCache]
            var rest: [Int]
            if caching, let prefix = self.prefixes.last(where: { $0.prompt == prompt }),
               full.count > prefix.tokens.count, Array(full.prefix(prefix.tokens.count)) == prefix.tokens {
                cache = prefix.cache.map { $0.copy() }
                rest = Array(full.dropFirst(prefix.tokens.count))
            } else {
                cache = context.model.newCache(parameters: parameters)
                rest = full
            }
            let stream = try MLXLMCommon.generate(
                input: LMInput(tokens: MLXArray(rest)), cache: cache, parameters: parameters, context: context)
            var text = ""
            for await generation in stream {
                // A generation given up on (its deadline passed, or a
                // new backend replaced this one) stops at the next token,
                // so the GPU is free for whoever is next on the lane. Leaving
                // the loop ends the stream, which stops the generation.
                if Task.isCancelled { break }
                if case .chunk(let chunk) = generation { text += chunk }
            }
            try Task.checkCancellation()
            return text
        }
    }

    /// The prompt rendered by the model's chat template, as tokens.
    private static func tokens(_ text: String, prompt: IntentPass.Prompt, context: ModelContext,
                               additional: [String: any Sendable]?) async throws -> [Int] {
        let chat: [Chat.Message] = [.system(prompt.instructions)]
            + prompt.examples.flatMap { [Chat.Message.user($0.said), .assistant($0.meant)] }
            + [.user(text)]
        let input = try await context.processor.prepare(input: UserInput(chat: chat, additionalContext: additional))
        return input.text.tokens.asArray(Int.self)
    }

    /// The prompt's beginning cached, unless it is or was found not to
    /// fit. Marked tried only once a build has finished: one cut short
    /// (cancelled, or an error) is tried again next time.
    private func ensurePrefix(_ prompt: IntentPass.Prompt, context: ModelContext,
                              additional: [String: any Sendable]?, parameters: GenerateParameters) async throws {
        guard !prefixes.contains(where: { $0.prompt == prompt }), !prefixTried.contains(prompt) else { return }
        let built = try await buildPrefix(context: context, parameters: parameters, tokens: {
            try await Self.tokens($0, prompt: prompt, context: context, additional: additional)
        })
        prefixTried.insert(prompt)
        guard let built else { return }
        prefixes.append((prompt, built.tokens, built.cache))
        if prefixes.count > Self.prefixesKept {
            let gone = prefixes.removeFirst()
            prefixTried.remove(gone.prompt)
        }
    }

    /// The prompt's shared beginning, read through the model once. Two
    /// sentences that share nothing find where the template's own tokens
    /// end; two tokens are left off that end, so a word's first piece that
    /// merges with the header is never in the cache.
    private func buildPrefix(context: ModelContext, parameters: GenerateParameters,
                             tokens: (String) async throws -> [Int]) async throws -> (tokens: [Int], cache: [KVCache])? {
        let a = try await tokens("Alpha."), b = try await tokens("Zulu?")
        var shared = zip(a, b).prefix { $0 == $1 }.map(\.0)
        shared = Array(shared.dropLast(2))
        guard shared.count > 8 else { return nil }
        let cache = context.model.newCache(parameters: parameters)
        switch try context.model.prepare(LMInput(tokens: MLXArray(shared)), cache: cache, windowSize: 512) {
        case .tokens(let remaining):
            // What prepare left for the first step is read too, so the
            // state holds every shared token and nothing after.
            _ = context.model(remaining[text: .newAxis], cache: cache, state: nil)
        case .logits:
            break
        }
        eval(cache)
        // Attention layers count the tokens they hold; a state-space layer
        // (Qwen 3.6's linear attention) keeps a running state and counts
        // none. Every layer that counts must hold exactly the prefix.
        let counted = cache.map(\.offset).filter { $0 > 0 }
        guard !counted.isEmpty, counted.allSatisfy({ $0 == shared.count }) else {
            Log.error("editor: instruction cache holds \(counted) of \(shared.count) tokens; not used")
            return nil
        }
        Log.info("editor", ["instructions-cached": shared.count, "engine": label])
        return (shared, cache)
    }
}
