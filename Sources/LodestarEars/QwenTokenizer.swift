import Foundation
import Hub
import Tokenizers

/// Qwen's byte-level BPE, from the files the MLX repos ship.
///
/// mlx-community's Qwen3-ASR folders carry vocab.json and merges.txt but no
/// tokenizer.json, which swift-transformers loads from. The rest of a
/// Qwen2 tokenizer.json is fixed (NFC, the Qwen split pattern, byte-level
/// pre-tokenizer and decoder), so it is written here and the vocabulary
/// and merges are read from the folder. Special tokens never pass through
/// it: the ear writes their ids itself (`QwenPrompt`).
enum QwenTokenizer {
    static func load(_ folder: URL) throws -> Tokenizer {
        let configURL = folder.appendingPathComponent("tokenizer_config.json")
        guard let configData = try? Data(contentsOf: configURL),
              let config = try JSONSerialization.jsonObject(with: configData) as? [NSString: Any]
        else { throw QwenEarError.missing("tokenizer_config.json") }

        let ready = folder.appendingPathComponent("tokenizer.json")
        if let data = try? Data(contentsOf: ready),
           let json = try JSONSerialization.jsonObject(with: data) as? [NSString: Any] {
            return try PreTrainedTokenizer(tokenizerConfig: Config(config), tokenizerData: Config(json))
        }

        guard let vocabData = try? Data(contentsOf: folder.appendingPathComponent("vocab.json")),
              let vocab = try JSONSerialization.jsonObject(with: vocabData) as? [NSString: Any]
        else { throw QwenEarError.missing("vocab.json") }
        guard let mergesText = try? String(contentsOf: folder.appendingPathComponent("merges.txt"), encoding: .utf8)
        else { throw QwenEarError.missing("merges.txt") }
        let merges = mergesText.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.hasPrefix("#version") }
            .map { String($0) }

        var added: [[String: Any]] = []
        if let decoder = config["added_tokens_decoder"] as? [String: [String: Any]] {
            for (id, token) in decoder {
                guard let n = Int(id), let content = token["content"] as? String else { continue }
                added.append(["id": n, "content": content, "special": token["special"] as? Bool ?? false,
                              "lstrip": false, "rstrip": false, "normalized": false, "single_word": false])
            }
            added.sort { ($0["id"] as! Int) < ($1["id"] as! Int) }
        }

        let data: [NSString: Any] = [
            "added_tokens": added,
            "normalizer": ["type": "NFC"],
            "pre_tokenizer": [
                "type": "Sequence",
                "pretokenizers": [
                    ["type": "Split", "pattern": ["Regex": splitPattern], "behavior": "Isolated", "invert": false],
                    ["type": "ByteLevel", "add_prefix_space": false, "trim_offsets": true, "use_regex": false],
                ],
            ],
            "decoder": ["type": "ByteLevel", "add_prefix_space": true, "trim_offsets": true, "use_regex": true],
            "model": [
                "type": "BPE", "vocab": vocab, "merges": merges,
                "continuing_subword_prefix": "", "end_of_word_suffix": "",
                "fuse_unk": false, "byte_fallback": false, "ignore_merges": false,
            ],
        ]
        return try PreTrainedTokenizer(tokenizerConfig: Config(config), tokenizerData: Config(data))
    }

    /// Qwen2's pre-tokenizer split, as its tokenizer.json writes it.
    static let splitPattern =
        #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#
}
