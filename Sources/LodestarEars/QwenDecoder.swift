import Foundation
import MLX
import MLXFast
import MLXLMCommon
import MLXNN

// Qwen3-ASR's text decoder: a plain Qwen3 (q/k norms, grouped KV heads,
// SwiGLU, tied embeddings) that takes embeddings as well as tokens, since
// the audio arrives as vectors where the prompt holds <|audio_pad|>.
//
// mlx-swift-lm's Qwen3Model is the same network, but it only takes token
// ids and keeps its layers file-private, so the audio could not be put in
// without swapping its embedding module at run time. This copy keeps the
// layer shapes and weight names of that model and of mlx-audio's
// qwen3_asr.py TextModel (MIT), and uses mlx-swift-lm's own KV cache,
// mask and attention routing. Its rotary embedding is the plain one: the
// config names an interleaved multimodal RoPE, but with text and audio on
// one time axis every section gets the same position, which is the plain
// rotation (mlx-audio decodes it that way too).

/// The decoder's shape, from config.json's text_config.
struct QwenTextConfig: Equatable {
    var hidden: Int
    var layers: Int
    var heads: Int
    var kvHeads: Int
    var headDim: Int
    var intermediate: Int
    var vocabulary: Int
    var ropeTheta: Float
    var rmsEps: Float

    init(_ json: [String: Any]) throws {
        func int(_ key: String) throws -> Int {
            guard let v = json[key] as? Int else { throw QwenEarError.badConfig(key) }
            return v
        }
        hidden = try int("hidden_size")
        layers = try int("num_hidden_layers")
        heads = try int("num_attention_heads")
        kvHeads = try int("num_key_value_heads")
        headDim = (json["head_dim"] as? Int) ?? hidden / heads
        intermediate = try int("intermediate_size")
        vocabulary = try int("vocab_size")
        ropeTheta = (json["rope_theta"] as? NSNumber)?.floatValue ?? 1_000_000
        rmsEps = (json["rms_norm_eps"] as? NSNumber)?.floatValue ?? 1e-6
    }
}

final class QwenTextAttention: Module {
    let c: QwenTextConfig
    let scale: Float
    @ModuleInfo(key: "q_proj") var q: Linear
    @ModuleInfo(key: "k_proj") var k: Linear
    @ModuleInfo(key: "v_proj") var v: Linear
    @ModuleInfo(key: "o_proj") var o: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm
    let rope: RoPE

    init(_ c: QwenTextConfig) {
        self.c = c
        scale = pow(Float(c.headDim), -0.5)
        _q.wrappedValue = Linear(c.hidden, c.heads * c.headDim, bias: false)
        _k.wrappedValue = Linear(c.hidden, c.kvHeads * c.headDim, bias: false)
        _v.wrappedValue = Linear(c.hidden, c.kvHeads * c.headDim, bias: false)
        _o.wrappedValue = Linear(c.heads * c.headDim, c.hidden, bias: false)
        _qNorm.wrappedValue = RMSNorm(dimensions: c.headDim, eps: c.rmsEps)
        _kNorm.wrappedValue = RMSNorm(dimensions: c.headDim, eps: c.rmsEps)
        rope = RoPE(dimensions: c.headDim, traditional: false, base: c.ropeTheta)
    }

    func callAsFunction(_ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache) -> MLXArray {
        let (b, n) = (x.dim(0), x.dim(1))
        var queries = qNorm(q(x).reshaped(b, n, c.heads, -1)).transposed(0, 2, 1, 3)
        var keys = kNorm(k(x).reshaped(b, n, c.kvHeads, -1)).transposed(0, 2, 1, 3)
        let values = v(x).reshaped(b, n, c.kvHeads, -1).transposed(0, 2, 1, 3)
        queries = rope(queries, offset: cache.offset)
        keys = rope(keys, offset: cache.offset)
        let out = attentionWithCacheUpdate(
            queries: queries, keys: keys, values: values, cache: cache, scale: scale, mask: mask)
        return o(out.transposed(0, 2, 1, 3).reshaped(b, n, -1))
    }
}

final class QwenTextMLP: Module {
    @ModuleInfo(key: "gate_proj") var gate: Linear
    @ModuleInfo(key: "up_proj") var up: Linear
    @ModuleInfo(key: "down_proj") var down: Linear

    init(_ c: QwenTextConfig) {
        _gate.wrappedValue = Linear(c.hidden, c.intermediate, bias: false)
        _up.wrappedValue = Linear(c.hidden, c.intermediate, bias: false)
        _down.wrappedValue = Linear(c.intermediate, c.hidden, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray { down(silu(gate(x)) * up(x)) }
}

final class QwenTextLayer: Module {
    @ModuleInfo(key: "self_attn") var attention: QwenTextAttention
    @ModuleInfo var mlp: QwenTextMLP
    @ModuleInfo(key: "input_layernorm") var inputNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postNorm: RMSNorm

    init(_ c: QwenTextConfig) {
        _attention.wrappedValue = QwenTextAttention(c)
        _mlp.wrappedValue = QwenTextMLP(c)
        _inputNorm.wrappedValue = RMSNorm(dimensions: c.hidden, eps: c.rmsEps)
        _postNorm.wrappedValue = RMSNorm(dimensions: c.hidden, eps: c.rmsEps)
    }

    func callAsFunction(_ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache) -> MLXArray {
        let h = x + attention(inputNorm(x), mask: mask, cache: cache)
        return h + mlp(postNorm(h))
    }
}

final class QwenTextModel: Module {
    let config: QwenTextConfig
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo var layers: [QwenTextLayer]
    @ModuleInfo var norm: RMSNorm

    init(_ c: QwenTextConfig) {
        config = c
        _embedTokens.wrappedValue = Embedding(embeddingCount: c.vocabulary, dimensions: c.hidden)
        _layers.wrappedValue = (0 ..< c.layers).map { _ in QwenTextLayer(c) }
        _norm.wrappedValue = RMSNorm(dimensions: c.hidden, eps: c.rmsEps)
    }

    func makeCache() -> [KVCache] { (0 ..< config.layers).map { _ in KVCacheSimple() } }

    /// Embeddings [1, n, hidden] in, logits of the last position [vocabulary] out.
    func lastLogits(_ embeddings: MLXArray, cache: [KVCache]) -> MLXArray {
        var h = embeddings
        let mask = createAttentionMask(h: h, cache: cache.first)
        for (layer, c) in zip(layers, cache) { h = layer(h, mask: mask, cache: c) }
        let last = norm(h[0, h.dim(1) - 1])
        return embedTokens.asLinear(last)
    }
}

/// Qwen3-ASR as its weights name it: `audio_tower` and `model`.
final class QwenASRModel: Module {
    @ModuleInfo(key: "audio_tower") var audioTower: QwenAudioEncoder
    @ModuleInfo(key: "model") var model: QwenTextModel

    init(audio: QwenAudioConfig, text: QwenTextConfig) {
        _audioTower.wrappedValue = QwenAudioEncoder(audio)
        _model.wrappedValue = QwenTextModel(text)
    }

    /// The model in `folder`: config.json and its safetensors, quantized
    /// where the weights are (the decoder; the audio tower stays bf16).
    static func load(_ folder: URL) throws -> QwenASRModel {
        let configURL = folder.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw QwenEarError.missing("config.json") }
        let thinker = (json["thinker_config"] as? [String: Any]) ?? json
        guard let audioJSON = thinker["audio_config"] as? [String: Any],
              let textJSON = thinker["text_config"] as? [String: Any]
        else { throw QwenEarError.badConfig("thinker_config") }
        let model = QwenASRModel(audio: try QwenAudioConfig(audioJSON), text: try QwenTextConfig(textJSON))

        let files = (try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "safetensors" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw QwenEarError.missing("model.safetensors") }
        var weights: [String: MLXArray] = [:]
        for file in files {
            for (key, value) in try loadArrays(url: file) {
                let name = key.hasPrefix("thinker.") ? String(key.dropFirst("thinker.".count)) : key
                if name == "lm_head.weight" { continue }       // tied to the embeddings
                weights[name] = value
            }
        }
        let quantization = (json["quantization"] as? [String: Any]) ?? (json["quantization_config"] as? [String: Any])
        if let quantization {
            let groupSize = (quantization["group_size"] as? Int) ?? 64
            let bits = (quantization["bits"] as? Int) ?? 8
            quantize(model: model) { path, _ in
                weights["\(path).scales"] != nil ? (groupSize, bits, .affine) : nil
            }
        }
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        eval(model)
        return model
    }
}
