import Foundation

/// An ear's model files, pinned: the revision measured, each file's size
/// and SHA-256. A download is these bytes or it is nothing, the way the
/// editor's models are (`EditorManifest`).
public struct EarManifest: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        public let path: String
        public let size: Int64
        public let sha256: String

        public init(path: String, size: Int64, sha256: String) {
            self.path = path; self.size = size; self.sha256 = sha256
        }
    }

    public let repo: String
    public let revision: String
    /// What the files may be used under, for the app's acknowledgements.
    public let license: String
    public let files: [File]
    public var total: Int64 { files.reduce(0) { $0 + $1.size } }
    /// The folder the model lives in under the models root.
    public var folder: String { repo.split(separator: "/").last.map(String.init) ?? repo }

    public func url(for file: File) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")!
    }
}

extension ParakeetEar {
    /// Parakeet TDT 0.6B v2, FluidInference's Core ML conversion: the four
    /// compiled models and the vocabulary, 464 MB (the encoder is 6-bit
    /// palettized). Checked 2026-10-03 against the Hugging Face tree API:
    /// every size and hash below matches the revision.
    ///
    /// Download as compiled `.mlmodelc` folders. The first `MLModel` load
    /// compiles them for the Neural Engine (about 30 s on an M1 Max) and
    /// Core ML keeps the result in `~/Library/Caches/<bundle id>/
    /// com.apple.e5rt.e5bundlecache`; later loads take a fraction of a
    /// second. An OS update can invalidate it. So warm the ear in the
    /// background after the download, never on the first dictation.
    public static let manifestV2 = EarManifest(
        repo: "FluidInference/parakeet-tdt-0.6b-v2-coreml", revision: "ee09c569f73759e6d44c9bd16766f477b2b36d39",
        license: "CC-BY-4.0 (NVIDIA parakeet-tdt-0.6b-v2; Core ML conversion by FluidInference)",
        files: [
            .init(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243,
                  sha256: "46de1a6fe2e49d19a2125bc91acf020df7f2aea84ba821532aade8427a440b05"),
            .init(path: "Decoder.mlmodelc/coremldata.bin", size: 554,
                  sha256: "d200ca07694a347f6d02a3886a062ae839831e094e443222f2e48a14945966a8"),
            .init(path: "Decoder.mlmodelc/metadata.json", size: 3427,
                  sha256: "90a279b822496316458febc0ce761ab05954fadd9d66aa97bea077a35fc8f2b2"),
            .init(path: "Decoder.mlmodelc/model.mil", size: 13106,
                  sha256: "7b95a5a6b672c652000348a67b6d4d92bb8e176b978c6666fe73c28a4d7ec579"),
            .init(path: "Decoder.mlmodelc/weights/weight.bin", size: 14_429_952,
                  sha256: "27d26890221d82322c1092fd99d7b40578e435d5cf4b83c887c42603caf97aba"),
            .init(path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243,
                  sha256: "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
            .init(path: "Encoder.mlmodelc/coremldata.bin", size: 485,
                  sha256: "4def7aa848599ad0e17a8b9a982edcdbf33cf92e1f4b798de32e2ca0bc74b030"),
            .init(path: "Encoder.mlmodelc/metadata.json", size: 2926,
                  sha256: "58222fbc48c13c49d9715567803cd50cb9c23e4360462e0f8ffcea59a2c73c63"),
            .init(path: "Encoder.mlmodelc/model.mil", size: 959_769,
                  sha256: "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
            .init(path: "Encoder.mlmodelc/weights/weight.bin", size: 445_187_200,
                  sha256: "4adc7ad44f9d05e1bffeb2b06d3bb02861a5c7602dff63a6b494aed3bf8a6c3e"),
            .init(path: "JointDecision.mlmodelc/analytics/coremldata.bin", size: 243,
                  sha256: "f1183ba213bb94a918c8d2cad19ab045320618f97f6ca662245b3936d7b090f7"),
            .init(path: "JointDecision.mlmodelc/coremldata.bin", size: 534,
                  sha256: "e2c6752f1c8cf2d3f6f26ec93195c9bfa759ad59edf9f806696a138154f96f11"),
            .init(path: "JointDecision.mlmodelc/metadata.json", size: 2936,
                  sha256: "ba8d309417b9acd4a175fdb15687de6a941db2f5b06666a60e7cf3cc8e2d3c3c"),
            .init(path: "JointDecision.mlmodelc/model.mil", size: 9722,
                  sha256: "93bf82042235127cb81ab537dcae47a1c2e7e242ce4ffdaf772981b45eedc4f0"),
            .init(path: "JointDecision.mlmodelc/weights/weight.bin", size: 3_453_388,
                  sha256: "ca22a65903a05e64137677da608077578a8606090a598abf4875fa6199aaa19d"),
            .init(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243,
                  sha256: "03ab3c1327a054c54c07a40325db967ec574f2c91dcc8192bfa44aa561bcf2d8"),
            .init(path: "Preprocessor.mlmodelc/coremldata.bin", size: 494,
                  sha256: "d88ea1fc349459c9e100d6a96688c5b29a1f0d865f544be103001724b986b6d6"),
            .init(path: "Preprocessor.mlmodelc/metadata.json", size: 2974,
                  sha256: "fb16c581ff5e1b962e7cb2181ed892cd32f9f84c12b6e80ff3e089f28e35bcbb"),
            .init(path: "Preprocessor.mlmodelc/model.mil", size: 27166,
                  sha256: "3e06d16fd061294c8a75be68c43a3b1ed1f593d4a9c35249e9cdbccadc59721e"),
            .init(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 298_880,
                  sha256: "a5f7df6c7f47147ae9486fe18cc7792f9a44d093ec3c6a11e91ef2dc363c48dc"),
            .init(path: "parakeet_vocab.json", size: 18762,
                  sha256: "57019fe3c745772ca83a1b048a4bb951cd51329504ea33d4d83316b96e279a97"),
        ])

    /// Parakeet TDT 0.6B v3 (25 European languages), the same layout with
    /// the top-K joint, 483 MB. Checked the same way, 2026-10-03.
    public static let manifestV3 = EarManifest(
        repo: "FluidInference/parakeet-tdt-0.6b-v3-coreml", revision: "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
        license: "CC-BY-4.0 (NVIDIA parakeet-tdt-0.6b-v3; Core ML conversion by FluidInference)",
        files: [
            .init(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243,
                  sha256: "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
            .init(path: "Decoder.mlmodelc/coremldata.bin", size: 554,
                  sha256: "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
            .init(path: "Decoder.mlmodelc/metadata.json", size: 3427,
                  sha256: "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9"),
            .init(path: "Decoder.mlmodelc/model.mil", size: 13110,
                  sha256: "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"),
            .init(path: "Decoder.mlmodelc/weights/weight.bin", size: 23_604_992,
                  sha256: "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
            .init(path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243,
                  sha256: "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
            .init(path: "Encoder.mlmodelc/coremldata.bin", size: 485,
                  sha256: "d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86"),
            .init(path: "Encoder.mlmodelc/metadata.json", size: 2921,
                  sha256: "da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9"),
            .init(path: "Encoder.mlmodelc/model.mil", size: 959_769,
                  sha256: "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
            .init(path: "Encoder.mlmodelc/weights/weight.bin", size: 445_187_200,
                  sha256: "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421"),
            .init(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", size: 243,
                  sha256: "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
            .init(path: "JointDecisionv3.mlmodelc/coremldata.bin", size: 521,
                  sha256: "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
            .init(path: "JointDecisionv3.mlmodelc/metadata.json", size: 3453,
                  sha256: "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f"),
            .init(path: "JointDecisionv3.mlmodelc/model.mil", size: 11775,
                  sha256: "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"),
            .init(path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 12_642_764,
                  sha256: "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
            .init(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243,
                  sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
            .init(path: "Preprocessor.mlmodelc/coremldata.bin", size: 486,
                  sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
            .init(path: "Preprocessor.mlmodelc/metadata.json", size: 2841,
                  sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
            .init(path: "Preprocessor.mlmodelc/model.mil", size: 28181,
                  sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
            .init(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 491_072,
                  sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
            .init(path: "parakeet_vocab.json", size: 151_122,
                  sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
        ])
}
