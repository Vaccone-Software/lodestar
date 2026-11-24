import XCTest
@testable import lodestar
import LodestarCore
import LodestarEars

/// A settling ear that answers what it is told to, after a pause.
final class FakeEar: SettlingEar, @unchecked Sendable {
    let name = "fake"
    var isLoaded = true
    var answers: [String]
    var delay: Double
    private(set) var heard: [Int] = []
    /// Answers returned, so a test that expects nothing to change waits
    /// for the answer it is refusing instead of for a while.
    private(set) var answered = 0
    init(answer: String, delay: Double = 0) {
        self.answers = [answer]
        self.delay = delay
    }
    /// Holds the first hearing until `release()`, so a test can settle the
    /// next phrase while that hearing is surely still out.
    private let gate = NSLock()
    private var holding = false
    private var waiting: CheckedContinuation<Void, Never>?
    func holdFirst() { gate.withLock { holding = true } }
    func release() {
        let waiter = gate.withLock { () -> CheckedContinuation<Void, Never>? in
            holding = false
            defer { waiting = nil }
            return waiting
        }
        waiter?.resume()
    }
    init(answers: [String]) {
        self.answers = answers
        self.delay = 0
    }
    func load() async throws {}
    func unload() {}
    func transcribe(_ samples: [Float], context: [String]) async throws -> Heard {
        heard.append(samples.count)
        if heard.count == 1 {
            await withCheckedContinuation { continuation in
                let held = gate.withLock { () -> Bool in
                    if holding { waiting = continuation }
                    return holding
                }
                if !held { continuation.resume() }
            }
        }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        defer { answered += 1 }
        return Heard(answers[min(heard.count, answers.count) - 1])
    }
}

/// The second recognizer through the real draft: each settled phrase is
/// heard again from the held audio, its words replace the live ones in
/// place as one undo step, a read-back of the list is refused, and ⏎
/// waits for the last phrase.
final class SettlingEarScenarioTests: XCTestCase {
    private func timed(_ text: String, _ start: Double, _ end: Double) -> Heard {
        Heard(text, words: [Heard.Word(text, start: start, end: end)])
    }

    private func stageWithAudio(_ ear: FakeEar) -> Stage {
        let stage = Stage()
        stage.draft.ear = ear
        stage.speech.held.append([Float](repeating: 0.01, count: 16_000 * 6), rate: 16_000)
        return stage
    }

    // MARK: - Ink drying

    /// Grey can still change; ink is final. A settled phrase stays grey
    /// while the second ear hears it again, and turns to ink when the ear
    /// is done, whether or not it changed a word.
    func testWordsStayGreyUntilTheEarHasHeardThem() {
        let ear = FakeEar(answer: "Ship it today.", delay: 0.2)
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("Ship it today.", 0, 2))
        XCTAssertEqual(stage.draft.state["wet"] as? String, "Ship it today.", "heard, still being checked")
        stage.pump(until: { stage.draft.state["wet"] == nil }, turns: 400)
        XCTAssertNil(stage.draft.state["wet"], "the ear is done: ink")
        XCTAssertEqual(stage.draft.state["revised"] as? [String], [], "nothing changed, nothing underlined")
    }

    /// A word the ear rewrote is underlined, the word alone and not the
    /// phrase, until the hand's next key.
    func testARewriteIsUnderlinedUntilTheNextKey() {
        let ear = FakeEar(answer: "Then rerun the build.")
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("Then rerun the bill.", 0, 2))
        stage.pump(until: { stage.draft.buffer.text.contains("build") })
        XCTAssertEqual(stage.draft.state["revised"] as? [String], ["build"])
        stage.press("space")
        XCTAssertEqual(stage.draft.state["revised"] as? [String], [], "the hand's next key clears it")
    }

    /// With no second ear and no intent pass there is nothing to wait for:
    /// settled words are ink at once, as they always were.
    func testWithoutAPassSettledWordsAreInkAtOnce() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle(timed("Plain words.", 0, 1.5))
        XCTAssertNil(stage.draft.state["wet"])
    }

    func testAPhraseIsHeardAgainAndReplacedInPlace() {
        let ear = FakeEar(answer: "Ask Claude Code to fix the panel.")
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("Ask clone code to fix the panel.", 0, 2.5))
        stage.pump(until: { stage.draft.buffer.text.contains("Claude") })
        XCTAssertEqual(stage.draft.buffer.text, "Ask Claude Code to fix the panel.")
        XCTAssertEqual(ear.heard.first.map { $0 >= 16_000 * 2 }, true, "the phrase's audio, with a margin")
        stage.press("escape")
        stage.press("u")
        XCTAssertEqual(stage.draft.buffer.text, "Ask clone code to fix the panel.", "u brings the live words back")
    }

    func testAReadBackOfTheListIsRefused() {
        let ear = FakeEar(answer: "Lodestar, Ghostty, Xonar, Kindora.")
        let stage = stageWithAudio(ear)
        stage.draft.earContext = ["Lodestar", "Ghostty", "Xonar", "Kindora"]
        stage.lode(".")
        stage.speech.settle(timed("Okay.", 0, 1.5))
        stage.pump(until: { ear.answered == 1 })
        stage.settle(turns: 20)
        XCTAssertEqual(stage.draft.buffer.text, "Okay.")
    }

    func testAPhraseTheHandHasEditedIsLeftAlone() {
        let ear = FakeEar(answer: "Ship the build tonight.", delay: 0.2)
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("Ship the bill tonight.", 0, 2))
        stage.press("escape")
        stage.press("x")
        stage.pump(until: { ear.answered == 1 })
        stage.settle(turns: 20)
        XCTAssertFalse(stage.draft.buffer.text.contains("build"), "the hand's edit wins")
    }

    func testTwoPhrasesAreHeardAgainAsOneRun() {
        let ear = FakeEar(answer: "Open the file and look at the function that closes it.")
        // The first hearing's answer already says "closes": were it back
        // before the second phrase, the wait below would end on it.
        ear.holdFirst()
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("Open the file and look at the.", 0, 2))
        stage.pump(until: { ear.heard.count == 1 })
        stage.speech.settle(timed("Function that clothes it.", 3, 5))
        ear.release()
        stage.pump(until: { stage.draft.buffer.text.contains("closes") })
        XCTAssertEqual(stage.draft.buffer.text, "Open the file and look at the function that closes it.")
        XCTAssertEqual(ear.heard.last.map { $0 >= 16_000 * 5 }, true, "the second hearing spans the whole run")
    }

    func testTheHandEndsTheRun() {
        let ear = FakeEar(answers: ["First part.", "Second part."])
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("First part.", 0, 1.5))
        stage.pump(until: { ear.heard.count == 1 })
        stage.press("space")
        stage.speech.settle(timed("Second bart.", 3, 4.5))
        stage.pump(until: { stage.draft.buffer.text.contains("Second part") })
        XCTAssertEqual(stage.draft.buffer.text, "First part. Second part.")
        XCTAssertEqual(ear.heard.last, Int((16_000 * (4.8 - 2.0)).rounded()), "only what came after the hand: from half a second past the first phrase")
    }

    func testReturnWaitsForTheLastPhrase() {
        let ear = FakeEar(answer: "Rebase local/dev on main.", delay: 0.15)
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("Rebase local dev on main.", 0, 2))
        stage.press("return")
        stage.pump(until: { !stage.pasteboard.isEmpty })
        XCTAssertEqual(stage.pasteboard.last, "Rebase local/dev on main.")
    }

    /// A run longer than fifteen seconds begins again: a longer one made
    /// every hearing slower and worse.
    func testARunPastFifteenSecondsBeginsAgain() {
        let ear = FakeEar(answers: ["First part.", "Second part."])
        let stage = Stage()
        stage.draft.ear = ear
        stage.speech.held.append([Float](repeating: 0.01, count: 16_000 * 20), rate: 16_000)
        stage.lode(".")
        stage.speech.settle(timed("First part.", 0, 1.5))
        stage.pump(until: { ear.answered == 1 })
        stage.speech.settle(timed("Second bart.", 16, 17.5))
        stage.pump(until: { stage.draft.buffer.text.contains("Second part") })
        XCTAssertEqual(ear.heard.last, Int((16_000 * (17.8 - 13.0)).rounded()), "only the new run: three seconds before it, long after the first ended")
    }

    // MARK: - The ear behind

    /// The slower ear hears the run after the quick one, from the words the
    /// quick one left, and its words go in where those stand.
    func testTheEarBehindHearsWhatTheQuickOneLeft() {
        let quick = FakeEar(answer: "Ask Claude code to fix the panel.")
        let behind = FakeEar(answer: "Ask Claude Code to fix the panel.")
        let stage = stageWithAudio(quick)
        stage.draft.backgroundEar = behind
        stage.lode(".")
        stage.speech.settle(timed("Ask clone code to fix the panel.", 0, 2.5))
        stage.pump(until: { stage.draft.buffer.text == "Ask Claude Code to fix the panel." })
        XCTAssertEqual(quick.heard.count, 1)
        XCTAssertEqual(behind.heard.count, 1, "after the quick ear, once")
    }

    /// ⏎ waits for the quick ear alone: the paste goes with its words while
    /// the ear behind is still hearing.
    func testReturnDoesNotWaitForTheEarBehind() {
        let quick = FakeEar(answer: "Rebase local/dev on main.")
        let behind = FakeEar(answer: "Rebase local/dev onto main.", delay: 3)
        let stage = stageWithAudio(quick)
        stage.draft.backgroundEar = behind
        stage.lode(".")
        stage.speech.settle(timed("Rebase local dev on main.", 0, 2))
        stage.pump(until: { quick.answered == 1 })
        stage.press("return")
        stage.pump(until: { !stage.pasteboard.isEmpty })
        XCTAssertEqual(stage.pasteboard.last, "Rebase local/dev on main.")
        XCTAssertEqual(behind.answered, 0, "landed before the ear behind answered")
    }

    /// A new phrase moves the run on: the ear behind's hearing of the run
    /// before it is not taken, and the run is heard again whole.
    func testANewPhraseDropsTheEarBehindsOlderHearing() {
        let quick = FakeEar(answers: ["Open the file and look at the.", "Open the file and look at the function that clothes it."])
        let behind = FakeEar(answers: ["Open the vile and look at the.", "Open the file and look at the function that closes it."])
        behind.holdFirst()
        let stage = stageWithAudio(quick)
        stage.draft.backgroundEar = behind
        stage.lode(".")
        stage.speech.settle(timed("Open the file and look at the.", 0, 2))
        stage.pump(until: { behind.heard.count == 1 })
        stage.speech.settle(timed("Function that clothes it.", 3, 5))
        stage.pump(until: { quick.answered == 2 })
        behind.release()
        stage.pump(until: { stage.draft.buffer.text.contains("closes") })
        XCTAssertEqual(stage.draft.buffer.text, "Open the file and look at the function that closes it.")
        XCTAssertFalse(stage.draft.buffer.text.contains("vile"), "the older hearing is not taken")
    }

    // MARK: - Catching up

    /// Said while the ear was still loading, a run is heard from the held
    /// audio the moment the ear is in, in place, and as one hearing.
    func testAColdEarHearsTheRunWhenItHasLoaded() {
        let ear = FakeEar(answer: "Open the file and look at the function that closes it.")
        ear.isLoaded = false
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("Open the file and look at the.", 0, 2))
        stage.speech.settle(timed("Function that clothes it.", 3, 5))
        stage.settle(turns: 30)
        XCTAssertEqual(ear.heard.count, 0, "cold: nothing to hear with")
        XCTAssertEqual(stage.draft.buffer.text, "Open the file and look at the function that clothes it.")
        ear.isLoaded = true
        stage.draft.earLoaded()
        stage.pump(until: { stage.draft.buffer.text.contains("closes") })
        XCTAssertEqual(ear.heard.count, 1, "the whole run at once, not a hearing per phrase")
        XCTAssertEqual(ear.heard.last.map { $0 >= 16_000 * 5 }, true, "from the first word to the last")
        XCTAssertEqual(stage.draft.state["revised"] as? [String], ["closes"])
    }

    /// The hand ended the run before the ear came in: those words are the
    /// hand's now, and are not heard.
    func testACatchUpLeavesWhatTheHandTouched() {
        let ear = FakeEar(answer: "Ship the build tonight.")
        ear.isLoaded = false
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("Ship the bill tonight.", 0, 2))
        stage.press("space")
        ear.isLoaded = true
        stage.draft.earLoaded()
        stage.settle(turns: 30)
        XCTAssertEqual(ear.heard.count, 0)
        XCTAssertTrue(stage.draft.buffer.text.contains("bill"), "the live words stand")
    }

    /// An ear arriving after the draft closed has nothing to hear for.
    func testACatchUpAfterTheDraftClosedHearsNothing() {
        let ear = FakeEar(answer: "Ship the build tonight.")
        ear.isLoaded = false
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("Ship the bill tonight.", 0, 2))
        stage.press("escape")
        ear.isLoaded = true
        stage.draft.earLoaded()
        stage.settle(turns: 30)
        XCTAssertEqual(ear.heard.count, 0)
    }

    /// The catch-up is a hearing like any other: a read-back of the list
    /// is refused by the same guard.
    func testACatchUpIsGuardedLikeAnyHearing() {
        let ear = FakeEar(answer: "Lodestar, Ghostty, Xonar, Kindora.")
        ear.isLoaded = false
        let stage = stageWithAudio(ear)
        stage.draft.earContext = ["Lodestar", "Ghostty", "Xonar", "Kindora"]
        stage.lode(".")
        stage.speech.settle(timed("Okay.", 0, 1.5))
        ear.isLoaded = true
        stage.draft.earLoaded()
        stage.pump(until: { ear.answered == 1 })
        stage.settle(turns: 20)
        XCTAssertEqual(stage.draft.buffer.text, "Okay.")
    }

    // MARK: - One running, one waiting

    /// Phrases landing while the ear is busy replace one another in the
    /// queue: the ear hears the run that was running, and then the newest.
    func testOnlyTheNewestWaitingHearingRuns() {
        let ear = FakeEar(answers: ["Stale.", "First part. Second part. Third part."])
        ear.holdFirst()
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("First part.", 0, 1.5))
        stage.pump(until: { ear.heard.count == 1 })
        stage.speech.settle(timed("Second part.", 2, 3.5))
        stage.speech.settle(timed("Third bart.", 4, 5.5))
        ear.release()
        stage.pump(until: { stage.draft.buffer.text.contains("Third part") })
        XCTAssertEqual(ear.heard.count, 2, "the run, then the newest; the one between never ran")
        XCTAssertEqual(ear.heard.last.map { $0 >= 16_000 * 5 }, true, "and the newest spans the whole run")
        stage.settle(turns: 20)
        XCTAssertEqual(ear.heard.count, 2)
    }

    /// ⏎ waits for the running hearing and the newest waiting one, and
    /// lands what they made.
    func testReturnWaitsForTheNewestAlone() {
        let ear = FakeEar(answers: ["Stale.", "First part. Second part. Third part."])
        ear.delay = 0.1
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("First part.", 0, 1.5))
        stage.speech.settle(timed("Second part.", 2, 3.5))
        stage.speech.settle(timed("Third bart.", 4, 5.5))
        stage.press("return")
        stage.pump(until: { !stage.pasteboard.isEmpty })
        XCTAssertEqual(stage.pasteboard.last, "First part. Second part. Third part.")
        XCTAssertEqual(ear.heard.count, 2)
    }

    func testTheJournalKeepsADictationWhenAsked() throws {
        let ear = FakeEar(answer: "Rebase local/dev on main.")
        let stage = stageWithAudio(ear)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        stage.draft.journal = DictationJournal(folder: dir, days: 14)
        stage.lode(".")
        stage.speech.settle(timed("Rebase local dev on main.", 0, 2))
        stage.pump(until: { stage.draft.buffer.text.contains("local/dev") })
        stage.press("return")
        stage.pump(until: { !stage.pasteboard.isEmpty })
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let text = try String(contentsOf: dir.appendingPathComponent(files[0]), encoding: .utf8)
        XCTAssertTrue(text.contains("Rebase local dev on main."), "what the live recognizer heard")
        XCTAssertTrue(text.contains("\"ear\""), "what the ear heard")
    }

    // MARK: - Nemotron in front

    /// Nemotron writes a sentence's period late, at the head of the next
    /// phrase. The ear's hearing of that phrase starts at its first word:
    /// the period stays with the sentence it ends, and the words keep the
    /// space between them (it read "keyboardhi Maria" at the desk).
    func testALatePeriodSurvivesTheEarHearingTheNextPhrase() {
        let ear = FakeEar(answers: ["Check it with a keyboard", "Hi Maria, the receipt is attached."])
        let stage = Stage()
        stage.draft.ear = ear
        stage.speech.held.append([Float](repeating: 0.01, count: 16_000 * 32), rate: 16_000)
        stage.lode(".")
        stage.speech.settle(timed("Check it with a keyboard", 0, 10))
        stage.pump(until: { ear.answered == 1 })
        // Past fifteen seconds: a run of its own.
        stage.speech.settle(timed(". Hi Maria, the receipt is attached.", 26, 30))
        stage.pump(until: { ear.answered == 2 })
        stage.settle(turns: 20)
        XCTAssertEqual(stage.draft.buffer.text, "Check it with a keyboard. Hi Maria, the receipt is attached.")
    }

    /// The ear heard the whole run: its sentence end stands where the live
    /// words had none.
    func testTheEarsPeriodLands() {
        let ear = FakeEar(answer: "There are a lot of issues with it.")
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("There are a lot of issues with it", 0, 3))
        stage.pump(until: { stage.draft.buffer.text.hasSuffix(".") })
        XCTAssertEqual(stage.draft.buffer.text, "There are a lot of issues with it.")
    }

    /// Nemotron times a word after the voice began it: the run is heard
    /// from three seconds before its first word's time, so the first words
    /// are in the audio ("Hey team, quick update" landed "Quick update").
    func testTheRunIsHeardFromThreeSecondsBeforeItsFirstWord() {
        let ear = FakeEar(answer: "Open the draft controller.")
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("Open the draft controller", 4, 5.5))
        stage.pump(until: { ear.answered == 1 })
        XCTAssertEqual(ear.heard.first, Int(16_000 * (5.8 - 1.0)), "from 1.0 s to 5.8 s")
    }

    /// Never into the phrase before: a run the hand began, soon after
    /// another phrase ended, is heard from half a second past that phrase's
    /// last word, whose voice may sound past its time.
    func testARunIsNotHeardFromInsideThePhraseBefore() {
        let ear = FakeEar(answers: ["First part.", "Second part."])
        let stage = Stage()
        stage.draft.ear = ear
        stage.speech.held.append([Float](repeating: 0.01, count: 16_000 * 22), rate: 16_000)
        stage.lode(".")
        stage.speech.settle(timed("First part", 0, 16.6))
        stage.pump(until: { ear.answered == 1 })
        stage.press("space")
        stage.speech.settle(timed("Second part", 17.0, 19))
        stage.pump(until: { ear.answered == 2 })
        XCTAssertEqual(ear.heard.last, Int((16_000 * (19.3 - 16.8)).rounded()), "from 16.8 s: past the first's tail, 0.2 s before the second")
    }

    /// ⏎ on a take the voice ended lands it with its last sentence ended,
    /// whether or not the ear wrote the period; the hand's own ending stands.
    func testReturnLandsATakeTheVoiceEndedWithAPeriod() {
        let ear = FakeEar(answer: "but this is noticeably worse to interact with")
        let stage = stageWithAudio(ear)
        stage.lode(".")
        stage.speech.settle(timed("but this is noticeably worse to interact with", 0, 3))
        stage.pump(until: { ear.answered == 1 })
        stage.press("return")
        stage.pump(until: { !stage.pasteboard.isEmpty })
        XCTAssertEqual(stage.pasteboard.last, "but this is noticeably worse to interact with.")
    }

    func testReturnLeavesATakeTheHandEnded() {
        let stage = Stage()
        stage.lode(".")
        stage.speech.settle(timed("Rename it to", 0, 1.5))
        for key in ["space", "g", "o"] { stage.press(key) }
        stage.press("return")
        stage.pump(until: { !stage.pasteboard.isEmpty })
        XCTAssertEqual(stage.pasteboard.last, "Rename it to go")
    }

    /// A run that goes on from the one before is heard from inside the
    /// phrase before, and the ear's mark at the seam stands: a pause the
    /// first run's ear ended with a period goes on as one sentence when
    /// the ear hears both sides.
    func testARunThatGoesOnIsHeardAcrossItsSeam() {
        let ear = FakeEar(answers: ["We want a variance in the radii.", "in the radii, it holds the shape."])
        let stage = Stage()
        stage.draft.ear = ear
        stage.speech.held.append([Float](repeating: 0.01, count: 16_000 * 30), rate: 16_000)
        stage.lode(".")
        stage.speech.settle(timed("we want a variance in the radii", 0, 10))
        stage.pump(until: { stage.draft.buffer.text.hasSuffix(".") })
        stage.speech.settle(timed("it holds the shape", 12, 21))
        stage.pump(until: { ear.answered == 2 })
        stage.settle(turns: 20)
        XCTAssertEqual(stage.draft.buffer.text, "We want a variance in the radii, it holds the shape.")
        XCTAssertEqual(ear.heard.last, Int(16_000 * (21.3 - 4.0)), "from six seconds before the phrase before ended")
    }

    /// And where the ear hears a sentence end at the seam, it stands.
    func testASentenceEndHeardAcrossASeamStands() {
        let ear = FakeEar(answers: ["We want a variance in the radii", "in the radii. It holds the shape."])
        let stage = Stage()
        stage.draft.ear = ear
        stage.speech.held.append([Float](repeating: 0.01, count: 16_000 * 30), rate: 16_000)
        stage.lode(".")
        stage.speech.settle(timed("we want a variance in the radii", 0, 10))
        stage.pump(until: { stage.draft.buffer.text.hasPrefix("We") })
        stage.speech.settle(timed("it holds the shape", 12, 21))
        stage.pump(until: { ear.answered == 2 })
        stage.settle(turns: 20)
        XCTAssertEqual(stage.draft.buffer.text, "We want a variance in the radii. It holds the shape.")
    }

    /// After a long pause the run is heard alone: no silence for context.
    func testARunAfterALongPauseIsHeardAlone() {
        let ear = FakeEar(answers: ["We want a variance in the radii.", "It holds the shape."])
        let stage = Stage()
        stage.draft.ear = ear
        stage.speech.held.append([Float](repeating: 0.01, count: 16_000 * 30), rate: 16_000)
        stage.lode(".")
        stage.speech.settle(timed("we want a variance in the radii", 0, 10))
        stage.pump(until: { stage.draft.buffer.text.hasSuffix(".") })
        stage.speech.settle(timed("it holds the shape", 18, 21))
        stage.pump(until: { stage.draft.buffer.text.hasSuffix("shape.") })
        XCTAssertEqual(stage.draft.buffer.text, "We want a variance in the radii. It holds the shape.")
        XCTAssertEqual(ear.heard.last, Int(16_000 * (21.3 - 15.0)), "from three seconds before its first word")
    }

    /// The phrase before's last word may still be sounding at its time: a
    /// run is heard from half a second past it, not from it.
    func testARunIsNotHeardFromThePhraseBeforesLastWord() {
        let ear = FakeEar(answers: ["We want both.", "Inner force holds it."])
        let stage = Stage()
        stage.draft.ear = ear
        stage.speech.held.append([Float](repeating: 0.01, count: 16_000 * 30), rate: 16_000)
        stage.lode(".")
        stage.speech.settle(timed("we want both", 0, 10))
        stage.pump(until: { stage.draft.buffer.text.hasSuffix(".") })
        stage.press("space")
        stage.speech.settle(timed("inner force holds it", 11.5, 14))
        stage.pump(until: { ear.answered == 2 })
        XCTAssertEqual(ear.heard.last, Int((16_000 * (14.3 - 10.5)).rounded()), "from 10.5 s, not 10 s")
    }
}
