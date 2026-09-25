import XCTest
@testable import lodestar
@testable import LodestarCore

/// The real model over the accuracy fixture. Off by default — it loads
/// gigabytes of weights — and on by environment:
///
///     LODESTAR_EDITOR_RECORD=standard swift test --filter EditorAccuracyLiveTests
///         asks the model every question and writes its answers into the
///         fixture, which the core test then scores on every run;
///     LODESTAR_EDITOR_LIVE=standard swift test --filter EditorAccuracyLiveTests
///         asks and scores without writing: has the model, the prompt or
///         MLX drifted from what was recorded?
final class EditorAccuracyLiveTests: XCTestCase {
    static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../LodestarCoreTests/Fixtures/editor-accuracy.json").standardized

    @MainActor
    func testTheModelAgainstTheFixture() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let name = env["LODESTAR_EDITOR_RECORD"] ?? env["LODESTAR_EDITOR_LIVE"],
              let engine = EditorEngine(rawValue: name) else {
            throw XCTSkip("set LODESTAR_EDITOR_RECORD or LODESTAR_EDITOR_LIVE to an engine to run the real model")
        }
        guard engine.usesModel else { throw XCTSkip("Spelling has no model to record: the core test scores it") }
        let recording = env["LODESTAR_EDITOR_RECORD"] != nil
        var fixture = try JSONDecoder().decode(EditorBench.Fixture.self, from: Data(contentsOf: Self.fixture))
        // LODESTAR_EDITOR_ONLY=prompt,hand scores a few sources, for trying a
        // prompt quickly; it never writes.
        let only = env["LODESTAR_EDITOR_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        if let only { fixture.cases = fixture.cases.filter { only.contains($0.src) } }
        let model = EditorModel(engine: engine)
        let started = Date()
        var asked = 0, changed = 0
        for index in fixture.cases.indices {
            var answers: [String: String] = [:]
            for sentence in EditorBench.questions(fixture.cases[index].text) {
                let reply = await model.correct(sentence) ?? ""
                answers[sentence] = reply
                asked += 1
                if let before = fixture.cases[index].answers[engine.rawValue]?[sentence], before != reply { changed += 1 }
            }
            fixture.cases[index].answers[engine.rawValue] = answers
        }
        await model.release(reason: "test done")
        let score = EditorBench.score(fixture.cases, engine: engine.rawValue)
        print("editor accuracy · \(engine.rawValue) · \(asked) questions in \(Int(Date().timeIntervalSince(started)))s · "
              + "\(changed) answers differ from the recording\n\(score)")
        if env["SHOW_MISSES"] != nil {
            score.misses.forEach { print("  missed  \($0)") }
            score.falseMarks.forEach { print("  wrong   \($0)") }
            for item in fixture.cases where item.src == "prompt" {
                print("  asked   \(item.text)\n  replied \(item.answers[engine.rawValue]?.values.joined(separator: " | ") ?? "")")
            }
        }
        if recording && only == nil {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(fixture).write(to: Self.fixture)
        } else {
            XCTAssertLessThanOrEqual(changed, asked / 10, "the model answers differently than when it was recorded")
        }
    }
}

/// The region's instruction on the real model: British sentences stay
/// British when the model is told, on demand (LODESTAR_EDITOR_LIVE=standard).
final class EditorRegionLiveTests: XCTestCase {
    static let british = [
        "The colour of the new logo is grey.",
        "We need to organise the travel before the programme starts.",
        "Please analyse the behaviour of the cache.",
        "I travelled to the centre on Monday.",
        "The catalogue arrives in the autumn.",
    ]

    @MainActor
    func testBritishSpellingStaysBritishWhenTheModelIsTold() async throws {
        guard let name = ProcessInfo.processInfo.environment["LODESTAR_EDITOR_LIVE"],
              let engine = EditorEngine(rawValue: name), engine.usesModel else {
            throw XCTSkip("LODESTAR_EDITOR_LIVE=standard runs the real model")
        }
        func americanized(_ language: String) async -> [String] {
            let model = EditorModel(engine: engine)
            await model.setLanguage(language)
            var changed: [String] = []
            for sentence in Self.british {
                let answer = await model.correct(sentence) ?? sentence
                let issues = EditorDiff.issues(text: sentence as NSString, sentence: NSRange(location: 0, length: (sentence as NSString).length),
                                               corrected: answer, guards: EditorGuards(), protected: [])
                changed += issues.map { "\($0.original) → \($0.replacement)" }
            }
            await model.release(reason: "test")
            return changed
        }
        let untold = await americanized("en_US")
        let told = await americanized("en_GB")
        print("editor region · told nothing: \(untold) · told British: \(told)")
        XCTAssertTrue(told.isEmpty, "British spelling marked as wrong: \(told)")
    }
}
