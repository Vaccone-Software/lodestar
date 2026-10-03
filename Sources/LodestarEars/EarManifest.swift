import Foundation

/// An ear's model files, pinned: one Hugging Face repo at one commit, and
/// every file the ear reads with its size and SHA-256, so a download can
/// be checked byte for byte before the ear loads it. The same shape as the
/// editor's manifest, kept here so the ears carry their own.
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
    public let files: [File]

    public init(repo: String, revision: String, files: [File]) {
        self.repo = repo; self.revision = revision; self.files = files
    }

    public var total: Int64 { files.reduce(0) { $0 + $1.size } }
    /// The folder the model lives in under the models root.
    public var folder: String { repo.split(separator: "/").last.map(String.init) ?? repo }

    public func url(for file: File) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")!
    }
}

extension QwenEar {
    /// The ear's pinned files by its factory name.
    public static func manifest(for name: String) -> EarManifest? {
        switch name {
        case "qwen3-asr-1.7b": return manifest1_7B
        case "qwen3-asr-0.6b": return manifest0_6B
        default: return nil
        }
    }

    // Revisions read from https://huggingface.co/api/models/<repo> on
    // 2026-10-03; sizes and hashes computed from the downloaded files and
    // checked against the repo tree (LFS SHA-256, git blob ids). Only the
    // files the ear reads: no chat template, preprocessor or generation
    // config, since their contents are written into the ear.

    /// Qwen3-ASR 1.7B, 8-bit decoder, bf16 audio tower: 2.47 GB.
    public static let manifest1_7B = EarManifest(
        repo: "mlx-community/Qwen3-ASR-1.7B-8bit", revision: "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
        files: [
            .init(path: "config.json", size: 7188,
                  sha256: "1b76b3b6c655fc54595da025f7a96474ad9fa86363303fbdd61a7d8483ccfaf7"),
            .init(path: "merges.txt", size: 1_671_853,
                  sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
            .init(path: "model.safetensors", size: 2_463_307_541,
                  sha256: "bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c"),
            .init(path: "tokenizer_config.json", size: 12487,
                  sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
            .init(path: "vocab.json", size: 2_776_833,
                  sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
        ])

    /// Qwen3-ASR 0.6B, 8-bit decoder, bf16 audio tower: 1.01 GB.
    public static let manifest0_6B = EarManifest(
        repo: "mlx-community/Qwen3-ASR-0.6B-8bit", revision: "89e96d92ba34aca20b3e29fb10cc284097d1219f",
        files: [
            .init(path: "config.json", size: 7187,
                  sha256: "5d104a945fed08728ab010f12bf3ce5ab4d0794bba276d81bff5bd83ae9d2be0"),
            .init(path: "merges.txt", size: 1_671_853,
                  sha256: "8831e4f1a044471340f7c0a83d7bd71306a5b867e95fd870f74d0c5308a904d5"),
            .init(path: "model.safetensors", size: 1_006_229_426,
                  sha256: "b5bfe4abc1b4c6e58b633096682ec2b6297298add1527119936107d211adf0e8"),
            .init(path: "tokenizer_config.json", size: 12487,
                  sha256: "4942d005604266809309cabc9f4e9cb89ce855d59b14681fdc0e1cc62ea26c4c"),
            .init(path: "vocab.json", size: 2_776_833,
                  sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
        ])
}
