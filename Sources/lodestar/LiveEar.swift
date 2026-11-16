import Foundation
import LodestarCore
import LodestarEars

/// The live recognizer when this Mac has Nemotron: the words on the draft as
/// they are said, about 0.4 s behind the voice and never rewritten, in place
/// of Apple's recognizer (about 1.2 s behind, rewriting as it goes).
/// Measured on the maker's 60 recordings after the draft's pipeline: 8.7% of
/// words wrong and 84% of names, against Apple's 11.4% and 79%.
///
/// One stream for the process, kept in memory all day once it is warm (280
/// MB): its first prediction in a process compiles the GPU's kernels for
/// about 4.4 s, so it is loaded and warmed at launch, never at the first
/// word. A session takes the stream with `begin()`; a newer session's
/// `begin()` ends the older one's claim, and its late audio is ignored, so
/// two sessions overlapping while one winds down never share the caches.
actor LiveEar {
    let stream: NemotronStream
    private var current = 0
    private(set) var isWarm = false

    init(folder: URL) {
        stream = NemotronStream(folder: NemotronStream.folder(inDownload: folder))
    }

    /// Load and pay the first prediction's compile. Ready only if both did.
    func prepare() async {
        guard !isWarm else { return }
        let began = ContinuousClock.now
        do {
            try await stream.load()
            try await stream.warm()
            isWarm = true
            Log.info("draft", ["live": "nemotron", "warm ms": Int(began.secondsElapsed * 1000)])
        } catch {
            Log.info("draft", ["live": "nemotron", "load failed": "\(error)"])
        }
    }

    func unload() async {
        isWarm = false
        current += 1
        await stream.unload()
    }

    /// A session begins: the stream is cleared and is this session's.
    func begin() async -> Int? {
        guard isWarm else { return nil }
        current += 1
        do { try await stream.reset() } catch { return nil }
        return current
    }

    /// Audio for session `id`; nothing for one that has been replaced.
    func feed(_ id: Int, _ samples: [Float]) async -> (pieces: [LivePhrases.Piece], chunks: Int) {
        guard id == current, isWarm else { return ([], 0) }
        let before = await stream.chunks
        let tokens = (try? await stream.feed(samples)) ?? []
        let after = await stream.chunks
        return (tokens.map(Self.piece), after - before)
    }

    /// The end of session `id`: the last words.
    func finish(_ id: Int) async -> [LivePhrases.Piece] {
        guard id == current, isWarm else { return [] }
        return ((try? await stream.finish()) ?? []).map(Self.piece)
    }

    private static func piece(_ token: NemotronStream.Token) -> LivePhrases.Piece {
        LivePhrases.Piece(token.text, start: token.start, end: token.end)
    }

    /// Session `id`'s audio as it comes, until the stream ends with the
    /// session: the open phrase as it grows, and each phrase settled at a
    /// pause, delivered on the main thread; the last words when it ends.
    nonisolated func hear(_ id: Int, from stream: AsyncStream<[Float]>,
                          onVolatile: @escaping (String) -> Void,
                          onSettled: @escaping (Heard) -> Void) async {
        var phrases = LivePhrases()
        func deliver(_ events: [LivePhrases.Event]) async {
            for event in events {
                switch event {
                case .volatile(let text): await MainActor.run { onVolatile(text) }
                case .settled(let heard): await MainActor.run { onSettled(heard) }
                }
            }
        }
        for await samples in stream where !samples.isEmpty {
            let (pieces, chunks) = await feed(id, samples)
            guard chunks > 0 else { continue }
            // Nearly always one chunk a buffer; any more were quiet.
            await deliver(phrases.take(pieces))
            for _ in 1..<chunks { await deliver(phrases.take([])) }
        }
        await deliver(phrases.finish(await finish(id)))
    }
}
