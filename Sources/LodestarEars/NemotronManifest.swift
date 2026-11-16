import Foundation

extension NemotronStream {
    /// The variant the stream runs: 560 ms chunks, the lowest latency the
    /// conversion offers.
    public static let variant = "nemotron_coreml_560ms"

    /// The stream's folder inside the manifest's: the repo holds every
    /// variant in a folder of its own, and the manifest's paths keep that
    /// folder, so a download lands in `<models>/<manifest.folder>/<variant>`.
    public static func folder(inDownload folder: URL) -> URL {
        folder.appendingPathComponent(variant, isDirectory: true)
    }

    /// Nemotron Speech Streaming 0.6B, FluidInference's Core ML conversion,
    /// the 560 ms variant: the int8 encoder, the fused decoder and joint,
    /// the shapes and the vocabulary, 608 MB. Checked 2026-11-15 against the
    /// Hugging Face tree API at this revision: every size, LFS SHA-256 and
    /// git blob id matches the files the hashes below were computed from.
    ///
    /// Not fetched: the separate `decoder.mlmodelc` and `joint.mlmodelc`
    /// (the fused model replaces them, as it does in FluidAudio when both are
    /// present) and `preprocessor.mlmodelc` (the mel is `NemotronMel`).
    public static let manifest = EarManifest(
        repo: "FluidInference/nemotron-speech-streaming-en-0.6b-coreml",
        revision: "e673531caa6d25ab7baf5a8c14c9b99ba1551838",
        license: "NVIDIA Open Model License (nemotron-speech-streaming-en-0.6b by NVIDIA; Core ML conversion by FluidInference)",
        files: [
            .init(path: "nemotron_coreml_560ms/decoder_joint.mlmodelc/analytics/coremldata.bin", size: 243,
                  sha256: "d46ecf790a728d91b8962ec62e597980e288e66c775e45429bf734b54c658ffc"),
            .init(path: "nemotron_coreml_560ms/decoder_joint.mlmodelc/coremldata.bin", size: 514,
                  sha256: "d9a7f7cfece967a69dca59b3fc3cc7d1ecff93ad2815ac3ba6b47e057db22172"),
            .init(path: "nemotron_coreml_560ms/decoder_joint.mlmodelc/model.mil", size: 17146,
                  sha256: "517bb31cf87eb8aa80adaa8c3fee2df0fd7d7dd0c8791e615c5023886c39d572"),
            .init(path: "nemotron_coreml_560ms/decoder_joint.mlmodelc/weights/weight.bin", size: 17_876_866,
                  sha256: "96cac67a1352e45a2418284779dbd5efe5865159b7b92f328247e5ed31485f52"),
            .init(path: "nemotron_coreml_560ms/encoder/encoder_int8.mlmodelc/analytics/coremldata.bin", size: 243,
                  sha256: "ef51dbab5c6ce310ce1a537538a4df6b88f13ad5c45c0acaddca055503896daa"),
            .init(path: "nemotron_coreml_560ms/encoder/encoder_int8.mlmodelc/coremldata.bin", size: 608,
                  sha256: "864a357ae2eb7d6b38ced73d5f23c908096a256516afa498c6730778767ec404"),
            .init(path: "nemotron_coreml_560ms/encoder/encoder_int8.mlmodelc/model.mil", size: 968_920,
                  sha256: "4b903ee4f401d81add07d1252192a486bd07154174818902f03bca38b2f293f6"),
            .init(path: "nemotron_coreml_560ms/encoder/encoder_int8.mlmodelc/weights/weight.bin", size: 589_057_600,
                  sha256: "8ced31411f7903eaec52de85e94c7847228f3e44028d8f0040800e5603943a40"),
            .init(path: "nemotron_coreml_560ms/metadata.json", size: 438,
                  sha256: "e8d93e5afa1e5c87257f6e31a5c336058eeba7d6cacd36ba80fbf9758c3916dc"),
            .init(path: "nemotron_coreml_560ms/tokenizer.json", size: 18374,
                  sha256: "a87b5b8a0e0a989fa7db3121f279ce6af70e337feb55ab553b8d0658db70b9d3"),
        ])
}
