import Foundation
import LodestarCore
import LodestarEars
import MLX

/// What the models service runs its requests on: MLX, in its process.
/// `ModelsService` takes the lane (`MLXGate.shared`) before language-model
/// work, `clearCache` and `check`; the ear takes the same lane itself.
public struct MLXModelsEngine: ModelsEngine {
    public init() {}

    public func loadLanguageModel(_ spec: LanguageModelSpec) async throws -> any ServedLanguageModel {
        try await MLXLanguageModels.load(spec)
    }

    public func loadEar(_ spec: EarSpec) async throws -> any ServedEar {
        guard QwenEarFiles.manifest(for: spec.name) != nil else {
            throw ModelsFailure.failed("no MLX ear called \(spec.name)")
        }
        let ear = QwenEar(name: spec.name, folder: URL(fileURLWithPath: spec.directory, isDirectory: true))
        try await ear.load()
        return ServedQwenEar(ear: ear)
    }

    public func clearCache() {
        Memory.clearCache()
    }

    public func memory() -> (activeMB: Int, cacheMB: Int)? {
        MLXCap.reading()
    }

    /// Four squares summed on the GPU: the device made and a kernel found
    /// in the bundle's `mlx-swift_Cmlx.bundle`. Without the kernels MLX
    /// cannot evaluate and the service ends, which the asker hears.
    public func check() throws -> String {
        MLXCap.apply()
        let values = MLXArray([1, 2, 3, 4] as [Float])
        let sum = (values * values).sum().item(Float.self)
        return "sum of squares \(Int(sum)) on \(GPU.deviceInfo().architecture)"
    }
}

private struct ServedQwenEar: ServedEar {
    let ear: QwenEar

    func transcribe(_ samples: [Float], context: [String]) async throws -> Heard {
        try await ear.transcribe(samples, context: context)
    }

    func unload() {
        ear.unload()
    }
}
