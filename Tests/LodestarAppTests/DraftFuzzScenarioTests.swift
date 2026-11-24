import XCTest
@testable import lodestar
@testable import LodestarCore

/// A seeded storm through the real path: the tap's keys, the
/// controller's modes, the editor, and the panel's actual layout. The
/// pure exercises prove the editor cannot crash on any key; this one
/// proves the seams — where v0.26.7's exclusivity abort actually lived
/// — cannot either. Deterministic, so a failure replays exactly.
final class DraftFuzzScenarioTests: XCTestCase {
    func testSeededStormThroughTheRealDraft() {
        let stage = Stage()
        var state: UInt64 = 0xC0FFEE
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33) % bound
        }
        // Base ANSI names only: the tap synthesizes real keycodes, and
        // `$` or `?` reach the draft as shift over `4` and `/`, the way
        // real hands make them.
        let keys = Array("abcdefghijklmnopqrstuvwxyz0123456789;,./'-=[]\\`").map(String.init)
            + ["space", "escape", "delete", "left", "right", "up", "down", "return"]
        stage.lode(".")
        stage.speech.settle("the quick brown fox jumps over the lazy dog and keeps going until the panel wraps this line at least once")
        for turn in 0..<400 {
            if !stage.draft.isOpen {
                stage.lode(".")
                stage.speech.settle("fresh words after a close on turn \(turn)")
            }
            let key = keys[next(keys.count)]
            _ = stage.press(key, shift: next(4) == 0)
            let buffer = stage.draft.buffer
            XCTAssertTrue((0...buffer.count).contains(buffer.cursor),
                          "cursor \(buffer.cursor) outside bounds on turn \(turn) after \(key)")
        }
    }
}
