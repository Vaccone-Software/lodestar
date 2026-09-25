import XCTest
@testable import LodestarCore

final class EditorDiffTests: XCTestCase {
    private func issues(_ text: String, _ corrected: String, guards: EditorGuards = EditorGuards()) -> [EditorIssue] {
        let ns = text as NSString
        return EditorDiff.issues(text: ns, sentence: NSRange(location: 0, length: ns.length),
                                 corrected: corrected, guards: guards,
                                 protected: EditorText.protectedRanges(in: text))
    }

    func testWordFixesBecomeIssuesAtTheirOwnRanges() {
        let found = issues("Their going to recieve the files.", "They're going to receive the files.")
        XCTAssertEqual(found.map(\.original), ["Their", "recieve"])
        XCTAssertEqual(found.map(\.replacement), ["They're", "receive"])
        XCTAssertEqual(found[1].range, NSRange(location: 15, length: 7))
    }

    func testANameIsNeverTouched() {
        XCTAssertTrue(issues("The Ghostty window keeps its size.", "The Ghostly window keeps its size.").isEmpty)
    }

    func testASentenceStartMayBeFixed() {
        XCTAssertEqual(issues("Its been a long week.", "It's been a long week.").map(\.replacement), ["It's"])
    }

    func testARewriteIsRefused() {
        XCTAssertTrue(issues("Each of the reviewers have approved it.",
                             "All reviewers approved the entire change set.").isEmpty)
    }

    func testCasualCaseAndPunctuationStand() {
        let found = issues("its fine lol just ship it", "It's fine, lol, just ship it.")
        XCTAssertEqual(found.map(\.original), ["its"])
        XCTAssertEqual(found.map(\.replacement), ["it's"], "the writer's lowercase start stands")
    }

    func testTrailingPunctuationIsTheWriters() {
        let found = issues("Let me know if your available.", "Let me know if you're available.")
        XCTAssertEqual(found.map(\.replacement), ["you're"])
    }

    func testAnInsertIsCarriedByTheWordAfterIt() {
        let found = issues("Can you send me link?", "Can you send me the link?")
        XCTAssertEqual(found.map(\.original), ["link?"])
        XCTAssertEqual(found.map(\.replacement), ["the link?"])
    }

    func testADeleteIsCarriedByTheWordAfterIt() {
        let found = issues("Can you send me the the link?", "Can you send me the link?")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].replacement, "link?")
        XCTAssertEqual(found[0].original, "the link?")
    }

    func testVocabularyIsRefused() {
        let guards = EditorGuards(vocabulary: ["retile"])
        XCTAssertTrue(issues("The window keeps its size after the retile.",
                             "The window keeps its size after the retiling.", guards: guards).isEmpty)
    }

    func testCodeAndLinksAreNotProse() {
        XCTAssertTrue(issues("Run `swift buld` first.", "Run `swift build` first.").isEmpty)
        XCTAssertTrue(issues("See https://github.com/foo/barr ok.", "See https://github.com/foo/bar ok.").isEmpty)
    }

    func testATalkativeReplyIsCleanedOrRefused() {
        XCTAssertEqual(EditorDiff.clean("<think>hmm</think>\n\"It's fine.\""), "It's fine.")
        XCTAssertEqual(EditorDiff.clean("Corrected: It's fine."), "It's fine.")
        XCTAssertTrue(issues("Its fine.", "Sure! Here is a much longer answer that explains every single change in detail.").isEmpty)
    }

    func testAStrayCommaTheModelRemovedIsMarked() {
        let found = issues("I pet a small, cat.", "I pet a small cat.")
        XCTAssertEqual(found.map(\.original), ["small,"])
        XCTAssertEqual(found.map(\.replacement), ["small"])
        XCTAssertEqual(found.first?.shown, "remove comma", "the chip says what changes")
        XCTAssertEqual(issues("I kissed, my beautiful cat.", "I kissed my beautiful cat.").map(\.replacement), ["kissed"])
    }

    func testACommaTheModelAddedIsTidyingAndIgnored() {
        XCTAssertTrue(issues("ok so the tap died again", "Ok, so the tap died again.").isEmpty)
    }

    func testALittleWordCapitalizedMidSentenceIsLowered() {
        let found = issues("I like This message, haha.", "I like this message, haha.")
        XCTAssertEqual(found.map(\.replacement), ["this"])
        XCTAssertEqual(found.first?.shown, "lowercase")
        XCTAssertTrue(issues("I use Slack daily.", "I use slack daily.").isEmpty, "a name keeps its capital")
    }

    func testOpcodesCoverBothSequences() {
        let ops = EditorDiff.opcodes(["a", "b", "c"], ["a", "x", "c", "d"])
        XCTAssertEqual(ops.map(\.kind), [.equal, .replace, .equal, .insert])
    }
}

final class EditorSessionTests: XCTestCase {
    func testOnlyFinishedSentencesAreSentToTheModel() {
        let session = EditorSession()
        let text = "Their going to push it. Let me know if your"
        // The caret sits in the unfinished second sentence.
        XCTAssertEqual(session.sentencesToCheck(text: text, caret: (text as NSString).length, paused: false),
                       ["Their going to push it."])
        // A pause finishes it.
        XCTAssertEqual(session.sentencesToCheck(text: text, caret: (text as NSString).length, paused: true).count, 2)
        session.record(sentence: "Their going to push it.", corrected: "They're going to push it.")
        XCTAssertEqual(session.sentencesToCheck(text: text, caret: (text as NSString).length, paused: true),
                       ["Let me know if your"])
    }

    func testTheModelsAnswerSurvivesEditsElsewhere() {
        let session = EditorSession()
        session.record(sentence: "Their going to push it.", corrected: "They're going to push it.")
        let before = session.issues(text: "Their going to push it.", caret: nil)
        let after = session.issues(text: "Hello there. Their going to push it.", caret: nil)
        XCTAssertEqual(before.map(\.replacement), ["They're"])
        XCTAssertEqual(after.map(\.range.location), [13], "re-anchored where the sentence now stands")
    }

    func testSpellingWaitsForTheWordToFinish() {
        let session = EditorSession()
        let text = "We need to recieve"
        XCTAssertTrue(session.issues(text: text, caret: (text as NSString).length).isEmpty,
                      "the caret is still in the word")
        let done = session.issues(text: text + " them", caret: (text as NSString).length + 5)
        XCTAssertEqual(done.map(\.replacement), ["receive"])
        XCTAssertEqual(done.first?.kind, .spelling)
    }

    func testTheModelOverrulesTheSpellCheckerInWhatItRead() {
        let session = EditorSession()
        session.guards = EditorGuards()
        let text = "the tap died after the retile, looking now."
        session.record(sentence: text, corrected: text)
        XCTAssertTrue(session.issues(text: text, caret: nil).isEmpty,
                      "the model read the sentence and accepted the term")
    }

    func testJustOnceQuietsAnIssueWhileItsSentenceStands() {
        let session = EditorSession()
        let text = "Their going to push it."
        session.record(sentence: text, corrected: "They're going to push it.")
        let issue = session.issues(text: text, caret: nil)[0]
        session.dismissOnce(issue, in: text)
        XCTAssertTrue(session.issues(text: text, caret: nil).isEmpty)
    }

    func testANameIsNotASpellingMistake() {
        let session = EditorSession()
        XCTAssertTrue(session.issues(text: "Open the Ghostty window now.", caret: nil).isEmpty)
    }

    func testVocabularyReachesTheSpellChecker() {
        let session = EditorSession()
        session.guards = EditorGuards(vocabulary: ["lgtmz"])
        XCTAssertTrue(session.issues(text: "lgtmz merging now.", caret: nil).isEmpty)
    }
}

/// The cases a real field throws at the editor: what it must mark, where,
/// and what it must leave alone.
final class EditorCasesTests: XCTestCase {
    private func issues(_ text: String, _ corrected: String, guards: EditorGuards = EditorGuards()) -> [EditorIssue] {
        let ns = text as NSString
        return EditorDiff.issues(text: ns, sentence: NSRange(location: 0, length: ns.length),
                                 corrected: corrected, guards: guards,
                                 protected: EditorText.protectedRanges(in: text))
    }

    private func spelling(_ text: String, caret: Int? = nil) -> [EditorIssue] {
        EditorSession().issues(text: text, caret: caret)
    }

    private func sentences(_ text: String) -> [String] {
        let ns = text as NSString
        return EditorText.sentences(in: text).map { ns.substring(with: $0) }
    }

    // MARK: Offsets

    func testEmojiCountsInUTF16LikeEveryAccessibilityRange() {
        let text = "🎉 Their going to push it."
        let found = EditorSession().issuesAfter(recording: text, as: "🎉 They're going to push it.")
        XCTAssertEqual(found.map(\.range), [NSRange(location: 3, length: 5)], "🎉 is two units, then a space")
        let skin = "👍🏽 we need to recieve them."
        let typo = spelling(skin)
        XCTAssertEqual(typo.map(\.range), [(skin as NSString).range(of: "recieve")])
    }

    func testAnIssueAfterAnEmojiReplacesExactlyItsWords() {
        let text = "ok 🙂 your welcome."
        let found = issues(text, "ok 🙂 you're welcome.")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual((text as NSString).substring(with: found[0].range), "your")
    }

    // MARK: Apostrophes

    func testCurlyAndStraightApostrophesAreTheSameWord() {
        XCTAssertTrue(issues("It’s fine, I’ll look.", "It's fine, I'll look.").isEmpty)
    }

    func testAFixWearsTheWritersApostrophe() {
        XCTAssertEqual(issues("It’s done, your welcome.", "It's done, you're welcome.").map(\.replacement),
                       ["you’re"], "a writer who curls gets a curled fix")
        XCTAssertEqual(issues("Your welcome.", "You're welcome.").map(\.replacement), ["You're"])
    }

    // MARK: Lines, greetings, sign-offs

    func testALineBreakEndsASentence() {
        XCTAssertEqual(sentences("Hi Sam,\nThanks for the notes.\nBest,\nRocco"),
                       ["Hi Sam,", "Thanks for the notes.", "Best,", "Rocco"])
    }

    func testAListIsItsItems() {
        let text = "- fix the tap\n- ship it\n- recieve feedback"
        XCTAssertEqual(sentences(text).count, 3)
        XCTAssertEqual(spelling(text).map(\.original), ["recieve"])
    }

    func testTheNameUnderASignOffIsNotASpellingMistake() {
        XCTAssertTrue(spelling("Thanks for the notes.\n\nBest,\nVaccone").isEmpty)
        XCTAssertTrue(spelling("Hi Anneliese,\nsee you then.").isEmpty)
    }

    func testAOneWordLineIsNotSentToTheModel() {
        let session = EditorSession()
        let text = "Hi Sam,\nThanks for the notes.\nBest,\nRocco"
        XCTAssertEqual(session.sentencesToCheck(text: text, caret: nil, paused: false),
                       ["Hi Sam,", "Thanks for the notes."])
    }

    // MARK: Casual writing

    func testChatWordsAreNotMistakes() {
        XCTAssertTrue(spelling("lol ok np, lmk tmrw if the pr is lgtm. gonna ship it rn.").isEmpty)
    }

    func testAbbreviationsTimesAndVersionsStand() {
        XCTAssertTrue(spelling("Meet at 3pm, e.g. after the v0.36.2 release, i.e. Tue.").isEmpty)
        XCTAssertEqual(sentences("Ask Dr. Lee, e.g. after lunch. Then ship.").count, 2,
                       "the tokenizer knows an abbreviation's dot")
    }

    func testTechnicalWordsWithoutBackticksAreProtected() {
        let text = "Open Sources/LodestarCore/Engine.swift and ~/Library/Logs, check foo_bar and com.apple.finder now."
        XCTAssertTrue(spelling(text).isEmpty)
        let protected = EditorText.protectedRanges(in: text)
        for word in ["Sources/LodestarCore/Engine.swift", "~/Library/Logs", "foo_bar", "com.apple.finder"] {
            let range = (text as NSString).range(of: word)
            XCTAssertTrue(protected.contains { NSIntersectionRange($0, range).length == range.length }, word)
        }
    }

    func testSlackMarkupStands() {
        let text = ":tada: @sam shipped it in #lodestar-dev :+1:"
        XCTAssertTrue(spelling(text).isEmpty)
        XCTAssertTrue(issues(text, ":party: @sam shipped it in #lodestar-dev :+1:").isEmpty,
                      "a shortcode is not a word to fix")
    }

    // MARK: The model's answer

    func testTheSameSentenceTwiceIsMarkedTwice() {
        let text = "Their going. Their going."
        let found = EditorSession().issuesAfter(recording: "Their going.", as: "They're going.", in: text)
        XCTAssertEqual(found.map(\.range.location), [0, 13])
    }

    func testAReplyWithNoiseIsCleanedToItsSentence() {
        XCTAssertEqual(EditorDiff.clean("Here is the corrected text: It's fine."), "It's fine.")
        XCTAssertEqual(EditorDiff.clean("It's fine.\n\nI changed its to it's."), "It's fine.")
        XCTAssertEqual(EditorDiff.clean("\u{201C}It's fine.\u{201D}"), "It's fine.")
        XCTAssertEqual(issues("Its fine.", "It's fine.\n\nI changed its to it's.").map(\.replacement), ["It's"])
    }

    func testTheRewriteGuardsEdgeIsTwoWordsInFive() {
        // Ten words: four changed is a correction, five is a rewrite.
        let text = "me and him goes to the store on monday morning"
        let four = issues(text, "he and I go to a store on monday morning")
        XCTAssertFalse(four.isEmpty, "four in ten stands")
        XCTAssertTrue(issues(text, "he and I go to a shop on monday morning").isEmpty, "five in ten is refused")
    }

    // MARK: Commas

    func testACommaIsTakenOnlyWhenTheModelRemovesIt() {
        XCTAssertEqual(issues("The report, is ready now.", "The report is ready now.").map(\.shown), ["remove comma"])
        XCTAssertTrue(issues("The report is ready now however we wait.",
                             "The report is ready now, however, we wait.").isEmpty, "added commas are tidying")
    }

    /// Keeping a grammar or punctuation mark quiets it in its sentence
    /// and teaches nothing: the same change elsewhere is marked.
    func testAKeptCommaStaysKeptInItsSentenceOnly() {
        let session = EditorSession()
        let text = "I pet a small, cat. We saw a small, dog."
        session.record(sentence: "I pet a small, cat.", corrected: "I pet a small cat.")
        session.record(sentence: "We saw a small, dog.", corrected: "We saw a small dog.")
        let marks = session.issues(text: text, caret: nil)
        XCTAssertEqual(marks.count, 2)
        session.dismissOnce(marks[0], in: text)
        XCTAssertEqual(session.issues(text: text, caret: nil).map(\.range.location), [marks[1].range.location])
        // Edited, the sentence is read afresh.
        let edited = "I pet a small, grey cat. We saw a small, dog."
        session.record(sentence: "I pet a small, grey cat.", corrected: "I pet a small grey cat.")
        XCTAssertEqual(session.issues(text: edited, caret: nil).count, 2)
    }

    // MARK: Names

    func testNamesThatAreWordsKeepTheirCapital() {
        XCTAssertTrue(issues("I asked Will about it.", "I asked will about it.").isEmpty)
        XCTAssertTrue(issues("I saw May yesterday.", "I saw may yesterday.").isEmpty)
        XCTAssertTrue(issues("Send it to Bill today.", "Send it to bill today.").isEmpty)
    }

    // MARK: Other languages and other people's words

    func testASentenceInAnotherLanguageIsNotRead() {
        XCTAssertTrue(EditorText.isForeign("Nos vemos mañana en la oficina."))
        XCTAssertFalse(EditorText.isForeign("See you tomorrow at the office."))
        XCTAssertFalse(EditorText.isForeign("ok gracias"), "two words is too few to judge")
        let text = "See you tomorrow. Nos vemos mañana en la oficina con todos."
        XCTAssertEqual(EditorSession().sentencesToCheck(text: text, caret: nil, paused: true), ["See you tomorrow."])
        XCTAssertTrue(spelling(text).isEmpty)
    }

    func testAQuotedThreadIsSomeoneElses() {
        let text = "Sounds good, I will recieve it tomorrow.\n\nOn Tue, Sep 23, 2026 at 9:00 AM Sam Lee <sam@example.com> wrote:\n> Their going to send teh files."
        XCTAssertEqual(EditorText.quoteStart(in: text), (text as NSString).range(of: "On Tue").location)
        XCTAssertEqual(spelling(text).map(\.original), ["recieve"])
        XCTAssertEqual(EditorSession().sentencesToCheck(text: text, caret: nil, paused: true),
                       ["Sounds good, I will recieve it tomorrow."])
    }

    func testOutlooksThreadStartsAreFound() {
        XCTAssertNotNil(EditorText.quoteStart(in: "Thanks.\n\n-----Original Message-----\nFrom: Sam"))
        XCTAssertNotNil(EditorText.quoteStart(in: "Thanks.\n\nFrom: Sam Lee\nSent: Tuesday\nTo: Rocco"))
        XCTAssertNotNil(EditorText.quoteStart(in: "Thanks.\n________________________________\nFrom: Sam"))
        XCTAssertNil(EditorText.quoteStart(in: "Thanks. From: here on, we ship."))
    }
}

private extension EditorSession {
    /// Record one model answer and read the text.
    func issuesAfter(recording sentence: String, as corrected: String, in text: String? = nil) -> [EditorIssue] {
        record(sentence: sentence, corrected: corrected)
        return issues(text: text ?? sentence, caret: nil)
    }
}

final class EditorUnansweredTests: XCTestCase {
    func testAnUnansweredSentenceKeepsItsSpellingMarks() {
        let session = EditorSession()
        let text = "We need to recieve them."
        session.record(sentence: text, corrected: nil)
        XCTAssertTrue(session.hasAnswer(for: text), "asked, so not asked again")
        XCTAssertTrue(session.sentencesToCheck(text: text, caret: nil, paused: true).isEmpty)
        XCTAssertEqual(session.issues(text: text, caret: nil).map(\.original), ["recieve"],
                       "a model that did not answer did not read it")
    }

    func testAListItemsFirstWordIsItsStart() {
        let session = EditorSession()
        session.record(sentence: "- Their going to push it.", corrected: "- They're going to push it.")
        XCTAssertEqual(session.issues(text: "- Their going to push it.", caret: nil).map(\.replacement), ["They're"],
                       "a dash does not make the first word a name")
    }
}

final class EditorAnsweredPromptTests: XCTestCase {
    /// A small model answers a sentence that is itself a request. That
    /// reply marks nothing, and it does not silence the spell checker.
    func testAModelThatAnsweredTheSentenceDidNotReadIt() {
        let session = EditorSession()
        let text = "Rewrite this paragraaph so it is easier to read out loud."
        session.record(sentence: text, corrected: "Please provide the paragraph you would like me to rewrite.")
        XCTAssertEqual(session.issues(text: text, caret: nil).map(\.replacement), ["paragraph"])
    }
}

final class EditorSettingsTests: XCTestCase {
    /// Every engine is listed; the ones this Mac cannot run are greyed,
    /// named with what they need.
    func testAModelTooBigIsListedAndGreyed() throws {
        var machine = SettingsModel.MachineState()
        machine.editorEngines = ["spelling", "minimal", "standard", "full"]
        machine.editorEngineLabels = ["Spelling", "Minimal", "Standard", "Full · needs 64 GB"]
        machine.editorEngineCurrent = "standard"
        machine.editorEnginesUnavailable = ["full"]
        let rows = SettingsModel.catalog(config: Config(), machine: machine).flatMap(\.rows)
        let model = try XCTUnwrap(rows.first { $0.path == "editor.model" })
        guard case .choice(let options, let labels, let current) = model.control else {
            return XCTFail("the model is a choice")
        }
        XCTAssertEqual(options, ["spelling", "minimal", "standard", "full"])
        XCTAssertEqual(labels.last, "Full · needs 64 GB")
        XCTAssertEqual(current, "standard")
        XCTAssertEqual(model.disabledChoices, ["full"])
    }

    func testNothingIsLearnedFromGrammar() {
        let rows = SettingsModel.catalog(config: Config(), machine: SettingsModel.MachineState()).flatMap(\.rows)
        XCTAssertFalse(rows.contains { $0.path == "editor.learned" }, "no list of kept grammar")
        XCTAssertNotNil(rows.first { $0.path == "draft.words" }, "kept words are still listed")
    }
}

/// The slips that need no model.
final class EditorRulesTests: XCTestCase {
    private func rules(_ text: String, caret: Int? = nil) -> [EditorIssue] {
        EditorRules.issues(in: text, caret: caret, protected: EditorText.protectedRanges(in: text))
    }

    func testAWordTypedTwiceIsMarked() {
        let found = rules("I sent it to to the whole team.")
        XCTAssertEqual(found.map(\.original), ["to to"])
        XCTAssertEqual(found.map(\.replacement), ["to"])
        XCTAssertEqual(rules("The The report is out.").map(\.replacement), ["The"], "whatever its case")
        XCTAssertEqual(rules("We saw the the.").map(\.replacement), ["the."], "the second's punctuation rides along")
    }

    func testWordsThatRepeatOnPurposeStand() {
        XCTAssertTrue(rules("I know that that is true.").isEmpty)
        XCTAssertTrue(rules("She had had enough.").isEmpty)
        XCTAssertTrue(rules("no no, bye bye, very very good").isEmpty)
        XCTAssertTrue(rules("the, the other one").isEmpty, "a comma between is a choice")
        XCTAssertTrue(rules("- ship the\nthe list").isEmpty, "a line break is layout")
    }

    func testShouldOfIsShouldHave() {
        XCTAssertEqual(rules("I should of called.").map(\.replacement), ["should have"])
        XCTAssertEqual(rules("Could of been worse.").map(\.replacement), ["Could have"])
        XCTAssertEqual(rules("we must of.").map(\.replacement), ["must have."])
        XCTAssertTrue(rules("It could of course fail.").isEmpty, "the phrase is right")
        XCTAssertTrue(rules("Most of them came.").isEmpty)
    }

    func testAlotIsALot() {
        XCTAssertEqual(rules("There's alot of work.").map(\.replacement), ["a lot"])
        XCTAssertEqual(rules("Alot changed.").map(\.replacement), ["A lot"])
    }

    func testTheWordAtTheCaretIsNotFinished() {
        let text = "I sent it to to"
        XCTAssertTrue(rules(text, caret: (text as NSString).length).isEmpty, "the hand may be typing \"today\"")
        XCTAssertTrue(rules("we should of", caret: 12).isEmpty)
    }

    func testCodeIsNotProse() {
        XCTAssertTrue(rules("Run `echo the the` now.").isEmpty)
    }

    /// One mark where a rule and the spell checker both see a slip: the
    /// rule knows the phrase.
    func testARuleSpeaksOnceOverTheSpellChecker() {
        let found = EditorSession().issues(text: "There's alot of work left.", caret: nil)
        XCTAssertEqual(found.map(\.replacement), ["a lot"])
    }
}
