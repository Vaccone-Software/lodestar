import LodestarCore
import XCTest
@testable import lodestar

/// The editor's model weighs its own grammar fixes before the session sees
/// them (`EditorConfidence`): a fix it barely prefers is taken out of the
/// answer, a clean answer is never weighed, and a model that cannot weigh
/// has its answers stand as they came.
final class EditorModelGateTests: XCTestCase {
    /// Fixes "Their" and "its"; finds "They're" far likelier than "Their"
    /// and "it's" barely likelier than "its".
    private final class Weigher: EditorBackend, @unchecked Sendable {
        let scores: Bool
        private let lock = NSLock()
        private var _weighed: [[String]] = []
        var weighed: [[String]] { lock.withLock { _weighed } }

        init(scores: Bool = true) { self.scores = scores }

        func respond(to sentence: String, instructions: String) async throws -> String {
            sentence.replacingOccurrences(of: "Their", with: "They're").replacingOccurrences(of: " its ", with: " it's ")
        }

        func likelihoods(of answers: [String], to text: String, instructions: String) async throws -> [Double] {
            lock.withLock { _weighed.append(answers) }
            return answers.map { answer in
                answer == text ? -20 : answer.contains("They're") ? -8 : -18.5
            }
        }
    }

    private func model(_ backend: Weigher) -> EditorModel {
        EditorModel(engine: .standard, idleRelease: 3600, answerDeadline: 8, gateWait: 3, loadDeadline: 60,
                    stuckAfter: 20, gate: MLXGate(), loader: { _ in backend }, clearCache: {})
    }

    func testAFixTheModelBarelyPrefersIsTakenOutAndAStrongOneStays() async {
        let backend = Weigher()
        let model = model(backend)
        let answer = await model.correct("Their going and its late now.")
        XCTAssertEqual(answer, "They're going and its late now.")
        XCTAssertEqual(backend.weighed.count, 1, "one question weighs every fix together")
        XCTAssertEqual(backend.weighed.first?.first, "Their going and its late now.", "the sentence as written leads")
        XCTAssertEqual(backend.weighed.first?.count, 3)
        await model.release(reason: "test")
    }

    func testAnAnswerWithNoGrammarFixIsNeverWeighed() async {
        let backend = Weigher()
        let model = model(backend)
        let answer = await model.correct("Everything here is fine.")
        XCTAssertEqual(answer, "Everything here is fine.")
        XCTAssertTrue(backend.weighed.isEmpty)
        await model.release(reason: "test")
    }

    func testAModelThatCannotWeighHasItsAnswerStand() async {
        let backend = Weigher(scores: false)
        let model = model(backend)
        let answer = await model.correct("Their going and its late now.")
        XCTAssertEqual(answer, "They're going and it's late now.")
        XCTAssertTrue(backend.weighed.isEmpty)
        await model.release(reason: "test")
    }
}
