import Accelerate
import Foundation

// Nemotron's log-mel front-end, computed here rather than by a Core ML model.
//
// Derived from FluidAudio (https://github.com/FluidInference/FluidAudio,
// commit 16780f0: `Shared/AudioMelSpectrogram.swift`, the center-padded
// `computeFlatTransposed` path, and `NemotronMelExtractor.swift`), Copyright
// FluidInference, licensed under the Apache License, Version 2.0
// (http://www.apache.org/licenses/LICENSE-2.0). Only the one configuration
// Nemotron uses is kept; the arithmetic and its order are kept exactly, so
// the features are FluidAudio's to the bit and the words come out the same.

/// NeMo's `AudioToMelSpectrogramPreprocessor` as configured for
/// nvidia/nemotron-speech-streaming-en-0.6b: 16 kHz, `n_fft` 512, a 400
/// sample symmetric Hann window every 160 samples, 128 Slaney mel bins,
/// pre-emphasis 0.97, `log(x + 2^-24)`, and no normalization. Each chunk is
/// heard on its own: zero-padded by 256 samples on each side, its
/// pre-emphasis started from silence.
///
/// Holds its FFT buffers, so it is not for two threads at once; the stream
/// owns one.
final class NemotronMel {
    static let sampleRate = 16_000
    static let nFFT = 512
    static let hop = 160
    static let window = 400
    static let preemphasis: Float = 0.97
    static let logGuard: Float = powf(2, -24)

    let mels: Int
    let hann: [Float]
    /// `[mels, nFFT / 2 + 1]`, row-major.
    let filterbank: [Float]
    private let fft: vDSP_DFT_Setup?

    private var realIn: [Float]
    private var imagIn: [Float]
    private var realOut: [Float]
    private var imagOut: [Float]
    private var power: [Float]
    private var imagSquared: [Float]
    private var frame: [Float]

    init(mels: Int = 128) {
        self.mels = mels
        self.hann = Self.hannWindow(length: Self.window)
        self.filterbank = Self.slaneyFilterbank(mels: mels)
        self.fft = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.nFFT), .FORWARD)
        let bins = Self.nFFT / 2 + 1
        realIn = [Float](repeating: 0, count: Self.nFFT)
        imagIn = [Float](repeating: 0, count: Self.nFFT)
        realOut = [Float](repeating: 0, count: Self.nFFT)
        imagOut = [Float](repeating: 0, count: Self.nFFT)
        power = [Float](repeating: 0, count: bins)
        imagSquared = [Float](repeating: 0, count: bins)
        frame = [Float](repeating: 0, count: Self.nFFT)
    }

    deinit {
        if let fft { vDSP_DFT_DestroySetup(fft) }
    }

    /// How many frames `count` samples make: `1 + (count + nFFT - window) / hop`.
    static func frames(for count: Int) -> Int {
        1 + (count + nFFT - window) / hop
    }

    /// The log-mel of one chunk, `[mels, frames]` row-major (element
    /// `[m, t]` at `m * frames + t`), as the encoder's `mel` input wants it.
    func logMel(_ samples: [Float]) -> (values: [Float], frames: Int) {
        let flat = timeMajor(samples)
        var values = [Float](repeating: 0, count: flat.values.count)
        let frames = flat.frames
        for t in 0..<frames {
            let base = t * mels
            for m in 0..<mels { values[m * frames + t] = flat.values[base + m] }
        }
        return (values, frames)
    }

    /// The log-mel `[frames, mels]` row-major, as FluidAudio computes it.
    func timeMajor(_ samples: [Float]) -> (values: [Float], frames: Int) {
        let count = samples.count
        guard let first = samples.first else { return ([Float](repeating: 0, count: mels), 1) }
        let pad = Self.nFFT / 2
        let paddedCount = count + 2 * pad
        let frames = 1 + (paddedCount - Self.window) / Self.hop

        // Pre-emphasis, y[n] = x[n] - 0.97 x[n-1], written into the padded
        // buffer; the sample before the chunk is taken as silence.
        var padded = [Float](repeating: 0, count: paddedCount)
        padded[pad] = first
        if count > 1 {
            padded.withUnsafeMutableBufferPointer { dst in
                samples.withUnsafeBufferPointer { src in
                    var negative = -Self.preemphasis
                    vDSP_vsma(src.baseAddress!, 1, &negative, src.baseAddress! + 1, 1,
                              dst.baseAddress! + pad + 1, 1, vDSP_Length(count - 1))
                }
            }
        }

        var out = [Float](repeating: 0, count: mels * frames)
        let bins = Self.nFFT / 2 + 1
        let offset = (Self.nFFT - Self.window) / 2
        var melFrame = [Float](repeating: 0, count: mels)
        for index in 0..<frames {
            vDSP_vclr(&frame, 1, vDSP_Length(Self.nFFT))
            let start = index * Self.hop + offset
            let available = min(Self.window, paddedCount - start)
            if available > 0 {
                padded.withUnsafeBufferPointer { src in
                    hann.withUnsafeBufferPointer { window in
                        frame.withUnsafeMutableBufferPointer { dst in
                            vDSP_vmul(src.baseAddress! + start, 1, window.baseAddress!, 1,
                                      dst.baseAddress! + offset, 1, vDSP_Length(available))
                        }
                    }
                }
            }
            powerSpectrum()
            filterbank.withUnsafeBufferPointer { bank in
                power.withUnsafeBufferPointer { spectrum in
                    melFrame.withUnsafeMutableBufferPointer { dst in
                        vDSP_mmul(bank.baseAddress!, 1, spectrum.baseAddress!, 1, dst.baseAddress!, 1,
                                  vDSP_Length(mels), 1, vDSP_Length(bins))
                    }
                }
            }
            for m in 0..<mels { out[index * mels + m] = log(melFrame[m] + Self.logGuard) }
        }
        return (out, frames)
    }

    /// `|FFT(frame)|²` for the first `nFFT / 2 + 1` bins, into `power`.
    private func powerSpectrum() {
        guard let fft else { return }
        frame.withUnsafeBufferPointer { src in
            realIn.withUnsafeMutableBufferPointer { dst in
                _ = memcpy(dst.baseAddress!, src.baseAddress!, Self.nFFT * MemoryLayout<Float>.size)
            }
        }
        vDSP_vclr(&imagIn, 1, vDSP_Length(Self.nFFT))
        vDSP_DFT_Execute(fft, realIn, imagIn, &realOut, &imagOut)
        let bins = vDSP_Length(Self.nFFT / 2 + 1)
        vDSP_vsq(realOut, 1, &power, 1, bins)
        vDSP_vsq(imagOut, 1, &imagSquared, 1, bins)
        vDSP_vadd(power, 1, imagSquared, 1, &power, 1, bins)
    }

    /// NeMo's symmetric Hann window: `0.5 (1 - cos(2π i / (n - 1)))`.
    static func hannWindow(length: Int) -> [Float] {
        let divisor = Float(length - 1)
        return (0..<length).map { i in 0.5 * (1.0 - cos(2.0 * Float.pi * Float(i) / divisor)) }
    }

    /// Slaney-scale triangles from 0 Hz to Nyquist, each scaled by
    /// `2 / (right - left)` (librosa's default), `[mels, bins]` row-major.
    static func slaneyFilterbank(mels: Int) -> [Float] {
        let bins = nFFT / 2 + 1
        let linear: Float = 200.0 / 3.0
        let logHz: Float = 1000.0
        let logMel: Float = logHz / linear
        let logStep: Float = log(6.4) / 27.0
        func hzToMel(_ hz: Float) -> Float { hz >= logHz ? logMel + log(hz / logHz) / logStep : hz / linear }
        func melToHz(_ mel: Float) -> Float { mel >= logMel ? logHz * exp(logStep * (mel - logMel)) : linear * mel }

        let low = hzToMel(0), high = hzToMel(Float(sampleRate) / 2.0)
        let points = (0..<(mels + 2)).map { i in melToHz(low + Float(i) * (high - low) / Float(mels + 1)) }
        let frequencies = (0..<bins).map { Float($0) * Float(sampleRate) / Float(nFFT) }
        var bank = [Float](repeating: 0, count: mels * bins)
        for m in 0..<mels {
            let left = points[m], center = points[m + 1], right = points[m + 2]
            let norm = 2.0 / (right - left)
            for (f, frequency) in frequencies.enumerated() {
                if frequency >= left && frequency < center {
                    bank[m * bins + f] = norm * (frequency - left) / (center - left)
                } else if frequency >= center && frequency <= right {
                    bank[m * bins + f] = norm * (right - frequency) / (right - center)
                }
            }
        }
        return bank
    }
}
