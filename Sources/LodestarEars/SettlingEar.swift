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

/// Which settling ear a Mac runs, smallest first.
public enum EarTier: String, CaseIterable, Sendable {
    /// No second ear: Apple's recognizer and the draft's pipeline.
    case apple
    /// Parakeet TDT 0.6B v2 on the Neural Engine: about 0.5 GB, 0.1 s.
    case standard
    /// Qwen3-ASR 1.7B, 8-bit, on MLX: about 2.5 GB on disk, 4 GB while
    /// it works, 0.6 s.
    case full
}

extension EarTier {
    /// The engine each tier runs, by its `EarFactory` name.
    public var engine: String? {
        switch self {
        case .apple: return nil
        case .standard: return "parakeet-v2"
        case .full: return "qwen3-asr-1.7b"
        }
    }

    /// The model files a tier downloads, pinned.
    public var manifest: EarManifest? {
        switch self {
        case .apple: return nil
        case .standard: return ParakeetEar.manifestV2
        case .full: return QwenEar.manifest1_7B
        }
    }

    /// The memory a tier asks of the Mac, in GB.
    public var memoryNeeded: Double {
        switch self {
        case .apple: return 0
        case .standard: return 8
        case .full: return 24
        }
    }

    /// The tier a setting names, or for an empty one the largest this Mac
    /// suits; a tier the Mac cannot run, or whose model is not on disk,
    /// falls back to the next smaller.
    public static func resolved(_ named: String, memoryGB: Double, hasModel: (EarTier) -> Bool) -> EarTier {
        let wanted = EarTier(rawValue: named) ?? .full
        let order: [EarTier] = [.full, .standard, .apple]
        let start = order.firstIndex(of: wanted) ?? 0
        for tier in order[start...] where tier == .apple || (memoryGB >= tier.memoryNeeded - 1 && hasModel(tier)) {
            return tier
        }
        return .apple
    }
}
