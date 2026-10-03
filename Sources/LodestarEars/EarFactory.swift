import Foundation

/// The ears by name, for the app's tiers and the probe.
public enum EarFactory {
    /// The ear called `name` ("parakeet-v2", "qwen3-asr-1.7b", …), its
    /// model files in `folder`; nil for a name not built.
    public static func make(_ name: String, folder: URL) -> SettlingEar? {
        switch name {
        case ParakeetEar.Variant.v2.name: return ParakeetEar(.v2, folder: folder)
        case ParakeetEar.Variant.v3.name: return ParakeetEar(.v3, folder: folder)
        case "qwen3-asr-1.7b", "qwen3-asr-0.6b": return QwenEar(name: name, folder: folder)
        default: return nil
        }
    }
}
