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
                                lookup: Self.looksUp, parameters: { _ in parameters })
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
    private func answer(_ text: String, prompt: IntentPass.Prompt, lookup: Bool = false,
                        parameters: @escaping @Sendable (Int) -> GenerateParameters) async throws -> String {
        let additional = additionalContext
        let caching = cachesInstructions
        return try await container.perform { (context: ModelContext) async throws -> String in
            let source = context.tokenizer.encode(text: text, addSpecialTokens: false)
            let parameters = parameters(source.count)
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
            // The input as the guess: every layer's state must be able to
            // take back a guess the model refused, which a state-space
            // layer (Full's) cannot, so that model writes token by token.
            if lookup, parameters.temperature == 0, canTrimPromptCache(cache) {
                let tokens = try Self.lookupDecode(rest, source: source, cache: cache,
                                                   maxTokens: parameters.maxTokens ?? 256,
                                                   stops: Self.stopTokens(context), model: context.model)
                return context.tokenizer.decode(tokenIds: tokens)
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

    /// Guess from the input (`PromptLookup`) unless told not to, which the
    /// measurement of the difference needs.
    static let looksUp = ProcessInfo.processInfo.environment["LODESTAR_EDITOR_NO_LOOKUP"] == nil
    /// The most tokens guessed in one step. A sentence's remaining words
    /// fit; a longer guess costs a little more to read when refused.
    static let guessLimit = 24

    /// The greedy answer to `rest`, read from `cache`, with the input
    /// (`source`) guessed ahead (`PromptLookup`). Each step reads the last
    /// token chosen and the guess after it together, keeps the guessed
    /// tokens the model agrees with, takes the model's own token where it
    /// first disagrees, and takes the refused rest of the guess back out of
    /// the cache. A guess is made only where every layer can take that many
    /// back; otherwise the step reads the one token, as plain decoding does.
    static func lookupDecode(_ rest: [Int], source: [Int], cache: [KVCache], maxTokens: Int,
                             stops: Set<Int>, model: any LanguageModel) throws -> [Int] {
        let logits: MLXArray
        switch try model.prepare(LMInput(tokens: MLXArray(rest)), cache: cache, windowSize: 512) {
        case .tokens(let remaining):
            logits = model(remaining[text: .newAxis], cache: cache, state: nil).logits
        case .logits(let result):
            logits = result.logits
        }
        var next = argMax(logits[0, -1], axis: -1).item(Int.self)
        var out: [Int] = []
        while !stops.contains(next) {
            try Task.checkCancellation()
            out.append(next)
            if out.count >= maxTokens { break }
            var guess = PromptLookup.draft(after: out, in: source, limit: min(guessLimit, maxTokens - out.count))
            if let stop = guess.firstIndex(where: stops.contains) { guess = Array(guess[..<stop]) }
            if !canTakeBack(guess.count, of: 1 + guess.count, from: cache) { guess = [] }
            let step = model(LMInput.Text(tokens: MLXArray([next] + guess))[text: .newAxis], cache: cache, state: nil)
            let predicted = argMax(step.logits[0], axis: -1).asType(.int32).asArray(Int32.self).map(Int.init)
            let kept = PromptLookup.accepted(guess, predicted: predicted)
            out += guess[..<kept]
            next = predicted[kept]
            if kept < guess.count { trimPromptCache(cache, numTokens: guess.count - kept) }
            if out.count >= maxTokens { break }
        }
        return out
    }

    /// Can every layer of `cache` take `count` tokens of `adding` back out
    /// once they are read? A sliding window that would roll over loses the
    /// tokens it rolled past, so it must stay inside its size.
    static func canTakeBack(_ count: Int, of adding: Int, from cache: [KVCache]) -> Bool {
        guard count > 0 else { return true }
        return cache.allSatisfy { layer in
            layer.isTrimmable && (layer.maxSize.map { layer.offset + adding < $0 } ?? true)
        }
    }

    /// The tokens that end an answer, gathered as MLX's own generation
    /// gathers them: the model's end tokens, the tokenizer's, the extra
    /// ones its configuration names, and the unknown token.
    static func stopTokens(_ context: ModelContext) -> Set<Int> {
        var stops = context.configuration.eosTokenIds
        if let eos = context.tokenizer.eosTokenId { stops.insert(eos) }
        for token in context.configuration.extraEOSTokens {
            if let id = context.tokenizer.convertTokenToId(token) { stops.insert(id) }
        }
        if let unknown = context.tokenizer.unknownTokenId { stops.insert(unknown) }
        return stops
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
