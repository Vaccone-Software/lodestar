import Foundation

/// The ears by name, for the app's tiers and the probe.
public enum EarFactory {
    /// The ear called `name` ("parakeet-v2", "qwen3-asr-1.7b", …), its
    /// model files in `folder`; nil for a name not built.
    public static func make(_ name: String, folder: URL) -> SettlingEar? {
        switch name {
        default: return nil
        }
    }
}
