import Foundation
import LodestarCore

/// A second recognizer that re-hears what was said.
///
/// Apple's recognizer writes the draft's words live; a settling ear hears
/// each phrase again, from audio the draft holds, while the speaker keeps
/// talking, and its words replace the live ones in place. Measured on the
/// maker's own voice: Apple alone 11.8% error and 77% of names exact
/// after the draft's pipeline; Parakeet 7.7% and 87%; Qwen3-ASR 1.7B with
/// a short list of names 6.2% and 97%.
///
/// Which ear a Mac gets is a tier, as the editor's models are: a smaller
/// Mac gets the smaller ear (`EarTier`).
public protocol SettlingEar: AnyObject, Sendable {
    /// Which ear this is, for the log and the record.
    var name: String { get }
    var isLoaded: Bool { get }
    /// Load the model from its folder. Off the main thread; may take
    /// seconds the first time (Core ML compiles for the Neural Engine).
    func load() async throws
    /// One phrase of 16 kHz mono samples, heard again. `context` is a
    /// short list of the speaker's terms to lean toward; an ear that
    /// cannot use it ignores it. Word times are seconds into `samples`.
    func transcribe(_ samples: [Float], context: [String]) async throws -> Heard
    /// Let the model's memory go.
    func unload()
}

/// What a Mac runs to hear the draft again, smallest first. Not a choice
/// anyone makes: the draft sizes it by the Mac's memory (`resolved`), and
/// `draft.model` names one only to force it for a measurement.
///
/// Every setup but Apple's has Parakeet in front, the ear ⏎ waits for (a
/// tenth of a second), and the larger ones Qwen3-ASR behind it, heard after
/// Parakeet and never waited for. Measured on the maker's long dictations:
/// Parakeet alone 9.0% of words wrong and 90% of names, Parakeet with
/// Qwen3-ASR 1.7B behind 7.1% and 97%, each landing at once.
public enum EarTier: String, CaseIterable, Sendable {
    /// No second ear: Apple's recognizer and the draft's pipeline.
    case apple
    /// Parakeet alone: about 0.5 GB on disk, 50 MB in memory, no language
    /// model. From 8 GB.
    case small
    /// Parakeet, Qwen3-ASR 0.6B behind it (1.2 GB) and Gemma 4 E2B to
    /// write what was meant. From 16 GB.
    case standard
    /// Parakeet, Qwen3-ASR 1.7B behind it (2.5 GB on disk, 4 GB while it
    /// works) and Gemma 4 E2B. From 24 GB.
    case full
    /// Parakeet, Qwen3-ASR 1.7B, and Qwen3.6 35B-A3B to write what was
    /// meant: 20 GB more while you dictate. From 64 GB.
    case max
}

extension EarTier {
    /// The setup as the log and the status line name it.
    public var name: String {
        switch self {
        case .apple: return "Apple only"
        case .small: return "Small"
        case .standard: return "Standard"
        case .full: return "Full"
        case .max: return "Max"
        }
    }

    /// The ear ⏎ waits for, by its `EarFactory` name.
    public var engine: String? {
        self == .apple ? nil : ParakeetEar.Variant.v2.name
    }

    /// The ear that hears again behind it, never waited for.
    public var backgroundEngine: String? {
        switch self {
        case .apple, .small: return nil
        case .standard: return "qwen3-asr-0.6b"
        case .full, .max: return "qwen3-asr-1.7b"
        }
    }

    /// Every ear the setup hears again with, in the order they are fetched:
    /// the one that hears first.
    public var engines: [String] { [engine, backgroundEngine].compactMap { $0 } }

    /// The live recognizer, Nemotron, in place of Apple's: fetched before
    /// the ears (it is what the words on the draft are), and not part of
    /// whether the setup is whole, since Apple's recognizer stands in for
    /// it until it is here. 280 MB in memory, so every setup has it.
    public var liveEngine: String? { self == .apple ? nil : EarEngines.nemotron }

    /// The memory a setup asks of the Mac, in GB.
    public var memoryNeeded: Double {
        switch self {
        case .apple: return 0
        case .small: return 8
        case .standard: return 16
        case .full: return 24
        case .max: return 64
        }
    }

    /// The setup a setting names, or for an empty one the largest this Mac
    /// suits; a setup the Mac cannot run, or whose models are not all on
    /// disk, falls back to the next smaller.
    public static func resolved(_ named: String, memoryGB: Double, hasModel: (EarTier) -> Bool) -> EarTier {
        let wanted = EarTier(rawValue: named) ?? .max
        let order: [EarTier] = [.max, .full, .standard, .small, .apple]
        let start = order.firstIndex(of: wanted) ?? 0
        for tier in order[start...] where tier == .apple || (memoryGB >= tier.memoryNeeded - 1 && hasModel(tier)) {
            return tier
        }
        return .apple
    }
}

/// The ears by engine name: their pinned files.
public enum EarEngines {
    /// Nemotron Speech Streaming 0.6B, English, 560 ms chunks.
    public static let nemotron = "nemotron-en-560"

    public static func manifest(_ engine: String) -> EarManifest? {
        switch engine {
        case nemotron: return NemotronStream.manifest
        case ParakeetEar.Variant.v2.name: return ParakeetEar.manifestV2
        case ParakeetEar.Variant.v3.name: return ParakeetEar.manifestV3
        default: return QwenEarFiles.manifest(for: engine)
        }
    }

    /// How an engine is named where a person reads it.
    public static func displayName(_ engine: String) -> String {
        if engine == nemotron { return "Nemotron" }
        if engine.hasPrefix("parakeet") { return "Parakeet" }
        if engine == "qwen3-asr-0.6b" { return "Qwen3-ASR 0.6B" }
        if engine.hasPrefix("qwen3-asr") { return "Qwen3-ASR" }
        return engine
    }

    /// Every engine any setup runs.
    public static var all: [String] {
        var seen: [String] = []
        for engine in EarTier.allCases.flatMap({ [$0.liveEngine].compactMap { $0 } + $0.engines })
            where !seen.contains(engine) { seen.append(engine) }
        return seen
    }
}
