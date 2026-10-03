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
