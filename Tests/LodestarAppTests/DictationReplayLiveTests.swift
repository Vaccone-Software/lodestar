import AVFoundation
import XCTest
@testable import lodestar
import LodestarCore
import LodestarEars
import LodestarMLX

/// Recorded takes through the draft as the app runs it: Nemotron hears each
/// take 80 ms at a time and its phrases settle at their pauses
/// (`LivePhrases`), each delivered to the real draft controller at the moment
/// in the take it would have arrived, while the real ears (Parakeet in front,
/// Qwen3-ASR behind) hear the runs again from the held audio, in real time.
/// ⏎ lands the draft at the end of the take, and the pasted text is what the
/// take came to. On demand only:
///
///   DICTATION_REPLAY=<manifest.json> DICTATION_REPLAY_OUT=<out.json>
///   [EARS_FOLDER=~/.local/share/lodestar/ears] [DICTATION_REPLAY_BEHIND=qwen3-asr-0.6b]
///   [DICTATION_REPLAY_IDS=a,b] [DICTATION_REPLAY_WORDS=names.txt] [DICTATION_REPLAY_INTENT=gemma|qwen36]
///   swift test --filter DictationReplayLiveTests
///
/// The panels go on screen, as every scenario does.
final class DictationReplayLiveTests: XCTestCase {
    private struct Event {
        let at: Double
        let event: LivePhrases.Event
    }

    private func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000, url.lastPathComponent)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    /// Wait for async work off the main thread, turning the main queue.
    private func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ReplayBox<T>()
        Task.detached {
            do { box.put(.success(try await work())) } catch { box.put(.failure(error)) }
        }
        while box.get() == nil { Stage.pump() }
        return try box.get()!.get()
    }

    /// The take as the live layer hears it: each event at the second of the
    /// take its chunk ends, as the microphone's 80 ms buffers arrive.
    private func phrases(_ audio: [Float], live: LiveEar) throws -> [Event] {
        try blocking {
            guard let id = await live.begin() else { throw XCTSkip("Nemotron is not warm") }
            var phrases = LivePhrases()
            var events: [Event] = []
            var heard = 0
            var i = 0
            while i < audio.count {
                let j = min(audio.count, i + 1280)
                let (pieces, chunks) = await live.feed(id, Array(audio[i..<j]))
                i = j
                guard chunks > 0 else { continue }
                heard += chunks
                let at = Double(i) / 16_000
                events += phrases.take(pieces).map { Event(at: at, event: $0) }
                for _ in 1..<max(1, chunks) { events += phrases.take([]).map { Event(at: at, event: $0) } }
            }
            let end = Double(audio.count) / 16_000
            events += phrases.finish(await live.finish(id)).map { Event(at: end, event: $0) }
            return events
        }
    }

    func testRecordedTakesThroughTheDraft() throws {
        let env = ProcessInfo.processInfo.environment
        guard let manifestPath = env["DICTATION_REPLAY"], let outPath = env["DICTATION_REPLAY_OUT"] else {
            throw XCTSkip("set DICTATION_REPLAY to a manifest and DICTATION_REPLAY_OUT to where the texts go")
        }
        let ears = URL(fileURLWithPath: ((env["EARS_FOLDER"] ?? "~/.local/share/lodestar/ears") as NSString).expandingTildeInPath)
        let manifestURL = URL(fileURLWithPath: (manifestPath as NSString).expandingTildeInPath)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let only = env["DICTATION_REPLAY_IDS"].map { Set($0.split(separator: ",").map(String.init)) }
        let items = try XCTUnwrap(manifest["items"] as? [[String: Any]]).filter { item in
            only.map { $0.contains(item["id"] as? String ?? "") } ?? true
        }
        let words = try env["DICTATION_REPLAY_WORDS"].map {
            try String(contentsOfFile: ($0 as NSString).expandingTildeInPath, encoding: .utf8)
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } ?? []

        let live = LiveEar(folder: ears.appendingPathComponent("nemotron-speech-streaming-en-0.6b-coreml"))
        try blocking { await live.prepare() }
        let quick = try XCTUnwrap(EarFactory.make("parakeet-v2", folder: ears.appendingPathComponent("parakeet-tdt-0.6b-v2-coreml")))
        let behindName = env["DICTATION_REPLAY_BEHIND"] ?? "qwen3-asr-0.6b"
        let behindFolder = env["DICTATION_REPLAY_BEHIND_FOLDER"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? ears.appendingPathComponent(behindName == "qwen3-asr-0.6b" ? "Qwen3-ASR-0.6B-8bit" : "Qwen3-ASR-1.7B-8bit")
        let behind: SettlingEar? = behindName == "none" ? nil
            : EarFactory.make(behindName, folder: behindFolder, qwen: { QwenEar(name: $0, folder: $1) })
        try blocking { try await quick.load(); try await behind?.load() }
        // The pass for what was meant, as Speak's setup runs it.
        let cleanup = env["DICTATION_REPLAY_INTENT"].flatMap(CleanupModel.init(rawValue:))
            .map { DraftModel(model: $0, loader: InProcessModels.cleanup) }
        let prompt = IntentPass.prompt(names: words)
        if let cleanup {
            try blocking { await cleanup.load(); _ = await cleanup.rewrite("Warm up.", prompt: prompt) }
        }

        var out: [String: Any] = [:]
        for item in items {
            let id = try XCTUnwrap(item["id"] as? String)
            let file = try XCTUnwrap(item["file"] as? String)
            let audio = try samples(manifestURL.deletingLastPathComponent().appendingPathComponent(file))
            let events = try phrases(audio, live: live)

            let stage = Stage()
            stage.draft.ear = quick
            stage.draft.backgroundEar = behind
            stage.draft.words = words
            stage.draft.earContext = words
            stage.draft.intentNames = words
            if let cleanup { stage.draft.intend = { await cleanup.rewrite($0, prompt: prompt) } }
            stage.speech.held.append(audio, rate: 16_000)
            stage.lode(".")
            // Real time: the ears' answers race the next phrase as they do
            // at the desk, and the virtual clock keeps pace for the draft's
            // own waits.
            let began = Date()
            var clockAt = 0.0
            func keepPace(until moment: Double) {
                while Date().timeIntervalSince(began) < moment {
                    Stage.pump()
                    let now = Date().timeIntervalSince(began)
                    if now - clockAt > 0.02 { stage.clock.advance(by: now - clockAt); clockAt = now }
                }
            }
            var settled: [String] = []
            var steps: [[String: Any]] = []
            for event in events {
                keepPace(until: event.at)
                switch event.event {
                case .volatile(let text): stage.speech.hear(text)
                case .settled(let heard):
                    settled.append(heard.text)
                    stage.speech.settle(heard)
                    steps.append(["at": event.at, "settled": heard.text, "buffer": stage.draft.buffer.text])
                }
            }
            keepPace(until: Double(audio.count) / 16_000 + 0.05)
            let beforeReturn = stage.draft.buffer.text
            stage.press("return")
            let pressed = Date()
            while stage.pasteboard.isEmpty, Date().timeIntervalSince(pressed) < 10 {
                keepPace(until: Date().timeIntervalSince(began) + 0.02)
            }
            let landed = stage.pasteboard.last ?? ""
            out[id] = ["text": landed, "beforeReturn": beforeReturn, "phrases": settled, "steps": steps,
                       "returnWait": Date().timeIntervalSince(pressed)]
            print("replay \(id): \(landed.split(separator: " ").count) words, \(settled.count) phrases")
            // The ear behind may still be hearing for this draft: let it go
            // before the next take's stage.
            stage.settle(turns: 50)
        }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath))
    }
}

/// One answer handed from a detached task to the main thread.
private final class ReplayBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    func put(_ value: Result<T, Error>) { lock.withLock { result = value } }
    func get() -> Result<T, Error>? { lock.withLock { result } }
}
