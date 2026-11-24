import AVFoundation
import XCTest
@testable import lodestar
import LodestarCore
import LodestarEars

/// Nemotron as the draft's live recognizer, on the real model: set
/// NEMOTRON_FOLDER to the 560 ms variant's folder. Two sentences spoken by
/// the system's own voice with a pause between are streamed 80 ms at a time,
/// as the microphone gives them: the open phrase only grows, each sentence
/// settles at its pause with its words timed, and a session replaced by a
/// newer one hears nothing more.
final class LiveEarLiveTests: XCTestCase {
    private func spoken(_ text: String) throws -> [Float] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let aiff = directory.appendingPathComponent("s.aiff"), wav = directory.appendingPathComponent("s.wav")
        for (tool, arguments) in [("/usr/bin/say", ["-o", aiff.path, text]),
                                  ("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEF32@16000", "-c", "1", aiff.path, wav.path])] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, tool)
        }
        let file = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    private func words(_ text: String) -> [String] {
        text.lowercased().split(separator: " ").map { $0.filter { $0.isLetter } }.filter { !$0.isEmpty }
    }

    @MainActor
    func testSentencesSettleAtTheirPausesAndTheOpenPhraseOnlyGrows() async throws {
        guard let path = ProcessInfo.processInfo.environment["NEMOTRON_FOLDER"] else {
            throw XCTSkip("set NEMOTRON_FOLDER to the nemotron_coreml_560ms folder")
        }
        let first = "Open the settings window and check the keyboard page."
        let second = "Then send the notes to the whole team."
        let audio = try spoken("[[slnc 500]] \(first) [[slnc 1800]] \(second) [[slnc 500]]")
        let live = LiveEar(folder: URL(fileURLWithPath: path).deletingLastPathComponent())
        await live.prepare()
        let warm = await live.isWarm
        XCTAssertTrue(warm)
        let begun = await live.begin()
        let session = try XCTUnwrap(begun)

        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        var volatile: [String] = []
        var settled: [Heard] = []
        let hearing = Task { await live.hear(session, from: stream, onVolatile: { volatile.append($0) },
                                             onSettled: { settled.append($0) }) }
        var i = 0
        while i < audio.count {
            continuation.yield(Array(audio[i..<min(audio.count, i + 1280)]))
            i += 1280
        }
        continuation.finish()
        await hearing.value

        XCTAssertEqual(settled.count, 2, "one phrase a sentence: \(settled.map(\.text))")
        XCTAssertEqual(words(settled.map(\.text).joined(separator: " ")), words(first + " " + second))
        XCTAssertEqual(settled.first.map { words($0.text) }, words(first), "the pause ends the first")
        for heard in settled {
            XCTAssertEqual(heard.words.map(\.text).joined(), heard.text)
            XCTAssertNotNil(heard.start)
        }
        if let a = settled.first?.end, let b = settled.last?.start { XCTAssertLessThan(a, b, "times run forward") }
        // Within a phrase the open text only grows.
        for (a, b) in zip(volatile, volatile.dropFirst()) where b.count >= a.count {
            XCTAssertTrue(b.hasPrefix(a) || words(b).starts(with: words(a)), "\(a) → \(b)")
        }

        // A newer session takes the stream: the older one hears nothing.
        let replaced = await live.begin()
        let newer = try XCTUnwrap(replaced)
        XCTAssertNotEqual(newer, session)
        let stale = await live.feed(session, Array(audio.prefix(16_000)))
        guard case .notCurrent = stale else { return XCTFail("the replaced session's audio is refused, not heard: \(stale)") }
        await live.unload()
    }
}
