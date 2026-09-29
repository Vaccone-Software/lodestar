import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// On by environment, with a person: a real dictation session on the
/// default input, timed. At the tone, say "one two three four five".
/// Reports when the session was listening, on what, whether the Mac's
/// microphone stood in and when the headset took over, and what was
/// heard, so a lost first word shows.
final class MicBridgeLiveTests: XCTestCase {
    func testTheFirstWordsAreHeardWhileTheHeadsetWakes() throws {
        guard ProcessInfo.processInfo.environment["LODESTAR_LIVE_MIC"] != nil else {
            throw XCTSkip("set LODESTAR_LIVE_MIC and say 'one two three four five' at the tone")
        }
        var lines: [String] = []
        let lock = NSLock()
        Log.listener = { line in
            if line.contains("draft") { lock.withLock { lines.append(line.trimmingCharacters(in: .newlines)) } }
        }
        defer { Log.listener = nil }
        let session = AnalyzerSpeechSession()
        var listening: [(Double, String)] = []
        var aliveAt: Double?
        var settled: [String] = []
        var volatile = ""
        let started = Date()
        NSSound(named: "Tink")?.play()
        session.listen(words: [], input: nil, onState: { state in
            if case .listening(let input) = state { listening.append((Date().timeIntervalSince(started), input ?? "?")) }
        }, onLevel: { _, _ in }, onAlive: {
            if aliveAt == nil { aliveAt = Date().timeIntervalSince(started) }
        }, onVolatile: { volatile = $0 }, onSettled: { settled.append($0) })
        RunLoop.main.run(until: Date().addingTimeInterval(8))
        let done = expectation(description: "stopped")
        session.stop { done.fulfill() }
        wait(for: [done], timeout: 5)
        print("LIVE lid closed=\(Lid.isClosed().map(String.init) ?? "?")")
        for (at, input) in listening { print(String(format: "LIVE listening at %.0f ms on %@", at * 1000, input)) }
        print(String(format: "LIVE alive at %.0f ms", (aliveAt ?? -1) * 1000))
        for line in lock.withLock({ lines }) where line.contains("bridg") || line.contains("\"audio\"") || line.contains("engine") {
            print("LIVE log:", line.dropFirst(13))
        }
        print("LIVE heard:", (settled + [volatile]).joined(separator: " ").trimmingCharacters(in: .whitespaces))
    }
}
