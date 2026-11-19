import AVFoundation
import Foundation
import LodestarCore
import LodestarEars

/// `lodestar transcribe <file>`: a file heard by dictation's own ears, with
/// its list of names, and the words written out. Nothing opens; nothing is
/// typed. Another program on this Mac (Woodsmoke's walks, which send a
/// phrase said into a phone) gets dictation's hearing without a copy of
/// its ears or a second model in memory.
enum Transcribe {
    enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        case empty
        case noEar

        var description: String {
            switch self {
            case .unreadable(let file): return "can't read \(file) as audio"
            case .empty: return "the file holds no sound"
            case .noEar: return "dictation has no ear on this Mac yet (Settings › Dictation)"
            }
        }
    }

    /// The rate every ear hears at.
    static let rate: Double = 16_000

    /// A file's sound as 16 kHz mono samples, whatever it was recorded as.
    static func samples(of url: URL) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw Failure.unreadable(url.lastPathComponent) }
        guard file.length > 0 else { throw Failure.empty }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        do { try file.read(into: input) } catch { throw Failure.unreadable(url.lastPathComponent) }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * rate / file.processingFormat.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw Failure.empty }
        var fed = false
        var problem: NSError?
        converter.convert(to: output, error: &problem) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard problem == nil, output.frameLength > 0, let channel = output.floatChannelData?[0] else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// The names the ear leans toward: the caller's own first (the words
    /// of the moment, as dictation leads with the words used last), then
    /// dictation's list, each once.
    static func names(_ asked: [String], dictation: [String]) -> [String] {
        var seen = Set<String>()
        return (asked + dictation).filter { seen.insert($0.lowercased()).inserted }
    }

    /// The answer a script reads: the words as the message, and with
    /// `--json` the ear that heard them and each word's time.
    static func answer(_ heard: Heard, ear: String, seconds: Double) -> [String: Any] {
        let words: [[String: Any]] = heard.words.map { word in
            var entry: [String: Any] = ["text": word.text]
            if let start = word.start { entry["start"] = start }
            if let end = word.end { entry["end"] = end }
            return entry
        }
        return ["ok": true, "message": heard.text,
                "result": ["text": heard.text, "ear": ear, "words": words, "seconds": seconds]]
    }
}
