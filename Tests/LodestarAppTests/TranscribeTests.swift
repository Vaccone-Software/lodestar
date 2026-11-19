import AVFoundation
import XCTest
@testable import lodestar

/// A file made ready for an ear, and the names it leans toward.
final class TranscribeTests: XCTestCase {
    /// Whatever it was recorded as, an ear gets 16 kHz mono.
    func testAFileBecomesSixteenKilohertzMono() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcribe-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        for channel in 0..<2 {
            for frame in 0..<44_100 { buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 0.05)) * 0.5 }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let samples = try Transcribe.samples(of: url)
        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 200, "one second at 16 kHz")
        XCTAssertGreaterThan(samples.map(abs).max() ?? 0, 0.3, "the sound came through")
    }

    func testAFileThatIsNotAudioSaysSo() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcribe-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: Data("not audio".utf8))
        XCTAssertThrowsError(try Transcribe.samples(of: url)) { error in
            XCTAssertEqual("\(error)", "can't read \(url.lastPathComponent) as audio")
        }
    }

    /// The caller's names lead, then dictation's, each once.
    func testTheCallersNamesLead() {
        XCTAssertEqual(Transcribe.names(["PrivateLink", "tsnet"], dictation: ["Lodestar", "privatelink"]),
                       ["PrivateLink", "tsnet", "Lodestar"])
    }
}
