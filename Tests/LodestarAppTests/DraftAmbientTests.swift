import LodestarCore
import LodestarEars
import Stoic
import XCTest
@testable import lodestar

/// The draft's off-main-thread work runs inside Stoic's ambient context,
/// the clock, the events and the task ledger the app binds at launch, so
/// what it records reaches Lodestar's log. A detached task starts without
/// it: the work still ran, and said nothing anywhere.
final class DraftAmbientTests: XCTestCase {
    /// An ear that says which ambient context its work ran in.
    private final class TaggedEar: SettlingEar, @unchecked Sendable {
        let name = "tagged"
        let isLoaded = true
        private let lock = NSLock()
        private var _tags: [UInt64?] = []
        private var _priorities: [TaskPriority] = []
        var tags: [UInt64?] { lock.withLock { _tags } }
        var priorities: [TaskPriority] { lock.withLock { _priorities } }
        func load() async throws {}
        func unload() {}
        func transcribe(_ samples: [Float], context: [String]) async throws -> Heard {
            lock.withLock {
                _tags.append(Ambient.current.ledgerTag)
                _priorities.append(Task.currentPriority)
            }
            return Heard("Ship it today.")
        }
    }

    private static let tag: UInt64 = 0xA3B1E7

    func testTheSecondEarsWorkRunsInTheAmbientContext() {
        let ear = TaggedEar()
        withAmbient({ $0.ledgerTag = Self.tag }) {
            let stage = Stage()
            stage.draft.ear = ear
            stage.speech.held.append([Float](repeating: 0.01, count: 16_000 * 4), rate: 16_000)
            stage.lode(".")
            stage.speech.settle(Heard("Ship it today.", words: [Heard.Word("Ship it today.", start: 0, end: 2)]))
            stage.pump(until: { !ear.tags.isEmpty })
        }
        XCTAssertEqual(ear.tags, [Self.tag], "the ear heard in the context the draft was driven in, not a bare one")
        // The priority a detached task had, not the main thread's: the ear
        // does not outrank the hand it is heard beside.
        XCTAssertEqual(ear.priorities, [.medium])
    }

    func testTheIntentPassesWorkRunsInTheAmbientContext() {
        let seen = Mutex()
        withAmbient({ $0.ledgerTag = Self.tag }) {
            let stage = Stage()
            stage.draft.intend = { _ in
                seen.record(Ambient.current.ledgerTag)
                return nil
            }
            stage.lode(".")
            stage.speech.settle("Use the red one, actually no, the blue one.")
            stage.pump(until: { !seen.values.isEmpty })
        }
        XCTAssertEqual(seen.values, [Self.tag])
    }

    private final class Mutex: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [UInt64?] = []
        var values: [UInt64?] { lock.withLock { _values } }
        func record(_ value: UInt64?) { lock.withLock { _values.append(value) } }
    }
}
