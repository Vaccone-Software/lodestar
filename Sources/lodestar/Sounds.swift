import AppKit
import LodestarCore

/// The draft's two notes. Listening is a fifth rising, Landed the same
/// fifth falling, both the alert's strike (packaging/Lodestar.aiff,
/// tools/sound/lodestar.py) tuned around A5 and played quieter, so the
/// three are one voice. See DESIGN.md, "Two notes, and the silence
/// between them".
enum Sounds {
    enum Cue: String {
        case listening = "Listening"
        case landed = "Landed"
    }

    /// Replaced by the tests, which hear what would have played.
    static var play: (Cue) -> Void = playThroughSpeakers

    static let playThroughSpeakers: (Cue) -> Void = { cue in
        guard let sound = loaded[cue] ?? load(cue) else {
            Log.info("draft", ["sound": cue.rawValue, "missing": true])
            return
        }
        loaded[cue] = sound
        sound.stop()
        sound.play()
        Log.info("draft", ["sound": cue.rawValue])
    }

    private static var loaded: [Cue: NSSound] = [:]

    private static func load(_ cue: Cue) -> NSSound? {
        url(for: cue).flatMap { NSSound(contentsOf: $0, byReference: true) }
    }

    /// The bundle's copy, or under `swift build`, which has no bundle,
    /// the packaging folder the app would have copied it from.
    static func url(for cue: Cue) -> URL? {
        if let url = Bundle.main.url(forResource: cue.rawValue, withExtension: "aiff") { return url }
        #if DEBUG
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dev = root.appendingPathComponent("packaging/\(cue.rawValue).aiff")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        #endif
        return nil
    }
}
