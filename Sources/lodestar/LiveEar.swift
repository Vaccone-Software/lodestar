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
    /// What a feed came to: the model's words, audio for a session the
    /// stream no longer serves, or a model that threw.
    enum Fed {
        case heard(pieces: [LivePhrases.Piece], chunks: Int)
        case notCurrent
        case failed(String)
    }

    func feed(_ id: Int, _ samples: [Float]) async -> Fed {
        guard id == current, isWarm else { return .notCurrent }
        let before = await stream.chunks
        do {
            let tokens = try await stream.feed(samples)
            let after = await stream.chunks
            return .heard(pieces: tokens.map(Self.piece), chunks: after - before)
        } catch {
            return .failed("\(error)")
        }
    }

    /// The end of session `id`: the last words.
    func finish(_ id: Int) async -> Fed {
        guard id == current, isWarm else { return .notCurrent }
        do {
            return .heard(pieces: try await stream.finish().map(Self.piece), chunks: 0)
        } catch {
            return .failed("\(error)")
        }
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
        var tally = LiveTally()
        func deliver(_ events: [LivePhrases.Event]) async {
            for event in events {
                switch event {
                case .volatile(let text): await MainActor.run { onVolatile(text) }
                case .settled(let heard):
                    tally.settled()
                    await MainActor.run { onSettled(heard) }
                }
            }
        }
        for await samples in stream where !samples.isEmpty {
            tally.gave(samples)
            switch await feed(id, samples) {
            case .notCurrent: tally.notCurrent()
            case .failed(let error): tally.failed(error)
            case .heard(let pieces, let chunks):
                tally.heard(chunks: chunks, pieces: pieces.count)
                guard chunks > 0 else { continue }
                // Nearly always one chunk a buffer; any more were quiet.
                await deliver(phrases.take(pieces))
                for _ in 1..<chunks { await deliver(phrases.take([])) }
            }
        }
        var last: [LivePhrases.Piece] = []
        switch await finish(id) {
        case .notCurrent: tally.notCurrent()
        case .failed(let error): tally.failed(error)
        case .heard(let pieces, _):
            tally.heard(chunks: 0, pieces: pieces.count)
            last = pieces
        }
        await deliver(phrases.finish(last))
        // The draft's count of what Nemotron was given and gave back, so an
        // empty draft says which step lost the words.
        Log.info("draft", fields: [("live", "nemotron")] + tally.fields)
    }
}
