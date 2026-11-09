import Foundation
import MLX
import MLXFast
import MLXNN

// Qwen3-ASR's ear: the log-mel front end and the audio encoder.
//
// Ported from mlx-audio's qwen3_asr.py (MIT, Prince Canuma and
// contributors) and checked against soniqo/speech-swift's
// Sources/Qwen3ASR (Apache-2.0, Copyright soniqo): the encoder's chunking,
// windowed attention and output lengths follow those two references.
// Unlike speech-swift's front end, which zero-pads each frame to a
// 512-point FFT, this one takes the 400-point transform Whisper's feature
// extractor takes, so the features are the ones the model was trained on.

/// Whisper's 128-bin log-mel spectrogram, as Qwen3-ASR's processor makes it:
/// 25 ms Hann windows every 10 ms over 16 kHz audio, centered (reflect
/// padded), power spectrum, Slaney mel filters to 8 kHz, log10, floored 8
/// below the loudest bin, then scaled to about -1…1. No padding to 30 s.
enum QwenMel {
    static let sampleRate = 16_000
    static let fftSize = 400
    static let hop = 160
    static let bins = 128

    /// How many frames `count` samples make: the extractor drops the last.
    static func frames(samples count: Int) -> Int { count / hop }

    /// The features as [bins, frames], float32.
    static func features(_ samples: [Float]) -> MLXArray {
        let frames = frames(samples: samples.count)
        precondition(samples.count > fftSize / 2, "the ear pads short audio before the front end")
        let pad = fftSize / 2
        // numpy "reflect": the edge sample is not repeated.
        var signal = [Float](repeating: 0, count: samples.count + 2 * pad)
        for i in 0 ..< samples.count { signal[pad + i] = samples[i] }
        for i in 0 ..< pad {
            signal[i] = samples[pad - i]
            signal[pad + samples.count + i] = samples[samples.count - 2 - i]
        }
        var framed = [Float](repeating: 0, count: frames * fftSize)
        let window = hann
        signal.withUnsafeBufferPointer { s in
            framed.withUnsafeMutableBufferPointer { f in
                for t in 0 ..< frames {
                    let start = t * hop, out = t * fftSize
                    for i in 0 ..< fftSize { f[out + i] = s[start + i] * window[i] }
                }
            }
        }
        let spectrum = rfft(MLXArray(framed, [frames, fftSize]), axis: -1)   // [frames, 201]
        let power = square(abs(spectrum))
        let mel = matmul(power, filters)                                      // [frames, 128]
        var logMel = log10(maximum(mel, MLXArray(Float(1e-10))))
        logMel = maximum(logMel, logMel.max() - 8)
        return ((logMel + 4) / 4).transposed(1, 0)
    }

    /// Periodic Hann, as `window_function(400, "hann")`.
    static let hann: [Float] = (0 ..< fftSize).map { i in
        Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(fftSize)))
    }

    /// Slaney-scale, Slaney-normalised triangles, [201, 128], as
    /// transformers' `mel_filter_bank(norm="slaney", mel_scale="slaney")`.
    static let filters: MLXArray = MLXArray(filterValues, [fftSize / 2 + 1, bins])

    static let filterValues: [Float] = {
        let count = fftSize / 2 + 1
        func toMel(_ hz: Double) -> Double {
            hz < 1000 ? 3 * hz / 200 : 15 + log(hz / 1000) * 27 / log(6.4)
        }
        func toHz(_ mel: Double) -> Double {
            mel < 15 ? 200 * mel / 3 : 1000 * exp(log(6.4) / 27 * (mel - 15))
        }
        let low = toMel(0), high = toMel(Double(sampleRate) / 2)
        let edges = (0 ..< bins + 2).map { toHz(low + (high - low) * Double($0) / Double(bins + 1)) }
        let fftHz = (0 ..< count).map { Double(sampleRate / 2) * Double($0) / Double(count - 1) }
        var out = [Float](repeating: 0, count: count * bins)
        for m in 0 ..< bins {
            let norm = 2 / (edges[m + 2] - edges[m])
            for k in 0 ..< count {
                let down = (fftHz[k] - edges[m]) / (edges[m + 1] - edges[m])
                let up = (edges[m + 2] - fftHz[k]) / (edges[m + 2] - edges[m + 1])
                out[k * bins + m] = Float(max(0, min(down, up)) * norm)
            }
        }
        return out
    }()
}

/// The audio tower's shape, from the model's config.json.
struct QwenAudioConfig: Equatable {
    var width: Int            // d_model
    var layers: Int
    var heads: Int
    var ffn: Int
    var outputWidth: Int      // the decoder's hidden size
    var melBins = 128
    var downsampleWidth = 480
    var window = 50           // n_window: chunks are 2 × this many frames
    var windowInfer = 800     // n_window_infer: attention spans this many frames

    init(width: Int, layers: Int, heads: Int, ffn: Int, outputWidth: Int) {
        self.width = width; self.layers = layers; self.heads = heads; self.ffn = ffn
        self.outputWidth = outputWidth
    }

    init(_ json: [String: Any]) throws {
        func int(_ key: String) throws -> Int {
            guard let v = json[key] as? Int else { throw QwenEarError.badConfig(key) }
            return v
        }
        self.init(width: try int("d_model"), layers: try int("encoder_layers"),
                  heads: try int("encoder_attention_heads"), ffn: try int("encoder_ffn_dim"),
                  outputWidth: try int("output_dim"))
        melBins = (json["num_mel_bins"] as? Int) ?? melBins
        downsampleWidth = (json["downsample_hidden_size"] as? Int) ?? downsampleWidth
        window = (json["n_window"] as? Int) ?? window
        windowInfer = (json["n_window_infer"] as? Int) ?? windowInfer
    }
}

/// Python's floor division, which the length formula depends on at zero.
@inline(__always) func floorDiv(_ a: Int, _ b: Int) -> Int {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
}

/// How many audio tokens `frames` mel frames become: 13 per full 100-frame
/// chunk, and the three stride-2 convolutions' length for the rest.
func qwenAudioTokens(frames: Int, chunk: Int = 100) -> Int {
    let rest = frames % chunk
    let a = floorDiv(rest - 1, 2) + 1
    let b = floorDiv(a - 1, 2) + 1
    return floorDiv(b - 1, 2) + 1 + (frames / chunk) * 13
}

final class QwenAudioAttention: Module {
    let heads: Int
    let scaling: Float
    @ModuleInfo(key: "q_proj") var q: Linear
    @ModuleInfo(key: "k_proj") var k: Linear
    @ModuleInfo(key: "v_proj") var v: Linear
    @ModuleInfo(key: "out_proj") var out: Linear

    init(width: Int, heads: Int) {
        self.heads = heads
        scaling = pow(Float(width / heads), -0.5)
        _q.wrappedValue = Linear(width, width)
        _k.wrappedValue = Linear(width, width)
        _v.wrappedValue = Linear(width, width)
        _out.wrappedValue = Linear(width, width)
    }

    func callAsFunction(_ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode) -> MLXArray {
        let (b, n, width) = (x.dim(0), x.dim(1), x.dim(2))
        func split(_ t: MLXArray) -> MLXArray { t.reshaped(b, n, heads, -1).transposed(0, 2, 1, 3) }
        let attended = MLXFast.scaledDotProductAttention(
            queries: split(q(x) * scaling), keys: split(k(x)), values: split(v(x)), scale: 1, mask: mask)
        return out(attended.transposed(0, 2, 1, 3).reshaped(b, n, width))
    }
}

final class QwenAudioLayer: Module {
    @ModuleInfo(key: "self_attn") var attention: QwenAudioAttention
    @ModuleInfo(key: "self_attn_layer_norm") var attentionNorm: LayerNorm
    @ModuleInfo var fc1: Linear
    @ModuleInfo var fc2: Linear
    @ModuleInfo(key: "final_layer_norm") var finalNorm: LayerNorm

    init(_ c: QwenAudioConfig) {
        _attention.wrappedValue = QwenAudioAttention(width: c.width, heads: c.heads)
        _attentionNorm.wrappedValue = LayerNorm(dimensions: c.width)
        _fc1.wrappedValue = Linear(c.width, c.ffn)
        _fc2.wrappedValue = Linear(c.ffn, c.width)
        _finalNorm.wrappedValue = LayerNorm(dimensions: c.width)
    }

    func callAsFunction(_ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode) -> MLXArray {
        let h = x + attention(attentionNorm(x), mask: mask)
        return h + fc2(gelu(fc1(finalNorm(h))))
    }
}

/// The audio tower: three stride-2 convolutions over 100-frame chunks
/// (13 tokens a second), a transformer whose attention stays inside
/// 8-second windows, and a projection to the decoder's width.
final class QwenAudioEncoder: Module {
    let config: QwenAudioConfig
    @ModuleInfo var conv2d1: Conv2d
    @ModuleInfo var conv2d2: Conv2d
    @ModuleInfo var conv2d3: Conv2d
    @ModuleInfo(key: "conv_out") var convOut: Linear
    @ModuleInfo var layers: [QwenAudioLayer]
    @ModuleInfo(key: "ln_post") var lnPost: LayerNorm
    @ModuleInfo var proj1: Linear
    @ModuleInfo var proj2: Linear

    init(_ c: QwenAudioConfig) {
        config = c
        let d = c.downsampleWidth
        _conv2d1.wrappedValue = Conv2d(inputChannels: 1, outputChannels: d, kernelSize: 3, stride: 2, padding: 1)
        _conv2d2.wrappedValue = Conv2d(inputChannels: d, outputChannels: d, kernelSize: 3, stride: 2, padding: 1)
        _conv2d3.wrappedValue = Conv2d(inputChannels: d, outputChannels: d, kernelSize: 3, stride: 2, padding: 1)
        let freq = (((c.melBins + 1) / 2 + 1) / 2 + 1) / 2
        _convOut.wrappedValue = Linear(d * freq, c.width, bias: false)
        _layers.wrappedValue = (0 ..< c.layers).map { _ in QwenAudioLayer(c) }
        _lnPost.wrappedValue = LayerNorm(dimensions: c.width)
        _proj1.wrappedValue = Linear(c.width, c.width)
        _proj2.wrappedValue = Linear(c.width, c.outputWidth)
    }

    /// Sinusoidal positions, [sin | cos], restarting in every chunk.
    static func positions(_ count: Int, width: Int) -> MLXArray {
        let half = width / 2
        let step = log(10_000.0) / Double(half - 1)
        let inverse = exp(MLXArray(0 ..< half).asType(.float32) * Float(-step))
        let time = MLXArray(0 ..< count).asType(.float32).expandedDimensions(axis: 1) * inverse.expandedDimensions(axis: 0)
        return concatenated([sin(time), cos(time)], axis: 1)
    }

    /// Mel [bins, frames] in, [tokens, outputWidth] out.
    func callAsFunction(_ mel: MLXArray) -> MLXArray {
        let frames = mel.dim(1)
        let chunk = config.window * 2
        let count = (frames + chunk - 1) / chunk
        let lengths = (0 ..< count).map { i in i == count - 1 && frames % chunk != 0 ? frames % chunk : chunk }
        let longest = lengths.max() ?? chunk
        var pieces: [MLXArray] = []
        var at = 0
        for length in lengths {
            var piece = mel[0..., at ..< at + length]
            if length < longest { piece = padded(piece, widths: [0, .init((0, longest - length))]) }
            pieces.append(piece)
            at += length
        }
        var x = stacked(pieces, axis: 0).expandedDimensions(axis: -1)   // [chunks, bins, time, 1]
        x = gelu(conv2d1(x))
        x = gelu(conv2d2(x))
        x = gelu(conv2d3(x))
        let (b, f, t, c) = (x.dim(0), x.dim(1), x.dim(2), x.dim(3))
        x = convOut(x.transposed(0, 2, 3, 1).reshaped(b, t, c * f))
        x = x + Self.positions(t, width: config.width).asType(x.dtype)

        let valid = lengths.map { qwenAudioTokens(frames: $0, chunk: chunk) }
        var h = concatenated((0 ..< b).map { x[$0, 0 ..< valid[$0]] }, axis: 0)

        // Attention windows: windowInfer frames each, counted after the CNN.
        let total = qwenAudioTokens(frames: frames, chunk: chunk)
        let span = (valid.max() ?? 13) * (config.windowInfer / chunk)
        var bounds = [0]
        while bounds.last! < total { bounds.append(min(bounds.last! + span, total)) }
        let mask: MLXFast.ScaledDotProductAttentionMaskMode
        if bounds.count <= 2 {
            mask = .none
        } else {
            var block = [Int32](repeating: 0, count: total)
            for w in 0 ..< bounds.count - 1 { for i in bounds[w] ..< bounds[w + 1] { block[i] = Int32(w) } }
            let ids = MLXArray(block)
            let same = ids.expandedDimensions(axis: 1) .== ids.expandedDimensions(axis: 0)
            mask = .array(MLX.where(same, MLXArray(Float(0)), MLXArray(Float(-1e9))).asType(h.dtype))
        }
        h = h.expandedDimensions(axis: 0)
        for layer in layers { h = layer(h, mask: mask) }
        h = lnPost(h.squeezed(axis: 0))
        return proj2(gelu(proj1(h)))
    }
}
