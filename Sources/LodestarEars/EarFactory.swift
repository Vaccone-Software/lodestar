import Foundation

/// The ears by name, for the app's tiers and the probe.
public enum EarFactory {
    /// The ear called `name` ("parakeet-v2", "qwen3-asr-1.7b", …), its
    /// model files in `folder`; nil for a name not built. Parakeet runs on
    /// the Neural Engine, here. Qwen3-ASR runs on MLX, which the app reaches
    /// only through its models service, so the caller says how a Qwen ear
    /// is made (`qwen`): the app's hears through the service, the probe's
    /// in its own process. Without one, a Qwen name makes nothing.
    public static func make(_ name: String, folder: URL,
                            qwen: ((String, URL) -> SettlingEar?)? = nil) -> SettlingEar? {
        switch name {
        case ParakeetEar.Variant.v2.name: return ParakeetEar(.v2, folder: folder)
        case ParakeetEar.Variant.v3.name: return ParakeetEar(.v3, folder: folder)
        case _ where QwenEarFiles.manifest(for: name) != nil: return qwen?(name, folder)
        default: return nil
        }
    }
}
