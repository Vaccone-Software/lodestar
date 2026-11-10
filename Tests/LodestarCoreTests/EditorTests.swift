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
        // Written on past the kept words, the keep stands.
        let longer = "I pet a small, grey cat. We saw a small, dog."
        session.record(sentence: "I pet a small, grey cat.", corrected: "I pet a small grey cat.")
        XCTAssertEqual(session.issues(text: longer, caret: nil).count, 1)
        // Edited before them, the sentence is read afresh.
        let edited = "Today I pet a small, cat. We saw a small, dog."
        session.record(sentence: "Today I pet a small, cat.", corrected: "Today I pet a small cat.")
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

    /// A markdown blockquote, a Slack quote, a diff, a review: the `>`
    /// line stays unread, and the writer's text under it is still read.
    func testAGreaterThanLineDoesNotHideTheTextUnderIt() {
        let text = "Looks good\n\n> old comment\n\nPlease fix the typo in teh function"
        XCTAssertNil(EditorText.quoteStart(in: text), "a > line is not a mail reply")
        let ns = text as NSString
        let protected = EditorText.protectedRanges(in: text)
        let quote = ns.range(of: "> old comment")
        XCTAssertTrue(protected.contains { NSIntersectionRange($0, quote).length == quote.length },
                      "the quote line is not read")
        let typo = ns.range(of: "teh")
        XCTAssertFalse(protected.contains { NSIntersectionRange($0, typo).length > 0 },
                       "the writer's text under the quote is read")
        XCTAssertFalse(protected.contains { $0.location == quote.location && NSMaxRange($0) == ns.length },
                       "the quote does not run to the end of the field")
        XCTAssertEqual(spelling(text).map(\.original), ["teh"])
        XCTAssertEqual(EditorSession().sentencesToCheck(text: text, caret: nil, paused: true),
                       ["Looks good", "Please fix the typo in teh function"])

        let quotedTypo = "Looks good\n\n> send teh files\n\nPlease fix the typo in teh function"
        let quoted = quotedTypo as NSString
        XCTAssertEqual(spelling(quotedTypo).map(\.range), [quoted.range(of: "teh", options: .backwards)],
                       "a typo on the quote line stays quiet")
    }

    /// A real reply header still covers everything under it, `>` lines and
    /// the prose beneath them. The writer's words above stay readable.
    func testAMailHeaderStillProtectsTheReplyBelowIt() {
        let text = "Sounds good, I will recieve it tomorrow.\n\nOn Tue, Sep 23, 2026 at 9:00 AM Sam Lee <sam@example.com> wrote:\n> Their going to send teh files.\n\nSend teh files today."
        let ns = text as NSString
        let start = ns.range(of: "On Tue").location
        XCTAssertEqual(EditorText.quoteStart(in: text), start)
        let protected = EditorText.protectedRanges(in: text)
        XCTAssertTrue(protected.contains { $0.location == start && NSMaxRange($0) == ns.length },
                      "the thread runs to the end of the field")
        XCTAssertEqual(spelling(text).map(\.original), ["recieve"])
        XCTAssertEqual(EditorSession().sentencesToCheck(text: text, caret: nil, paused: true),
                       ["Sounds good, I will recieve it tomorrow."])

        let outlook = "I will recieve it.\n\n-----Original Message-----\nFrom: Sam\nSend teh files today."
        let outlookStart = (outlook as NSString).range(of: "-----Original Message-----").location
        XCTAssertEqual(EditorText.quoteStart(in: outlook), outlookStart)
        XCTAssertTrue(EditorText.protectedRanges(in: outlook).contains {
            $0.location == outlookStart && NSMaxRange($0) == (outlook as NSString).length
        })
        XCTAssertEqual(spelling(outlook).map(\.original), ["recieve"])
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
        XCTAssertTrue(session.hasAnswer(for: text), "asked, so not asked again at once")
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
        XCTAssertEqual(options, ["", "spelling", "minimal", "standard", "full"])
        XCTAssertEqual(labels.first, "Automatic", "Automatic names no model")
        XCTAssertEqual(labels.last, "Full · needs 64 GB")
        XCTAssertEqual(current, "standard")
        XCTAssertEqual(model.disabledChoices, ["full"])
    }

    /// Both Model menus lead with a bare Automatic, the one thing to trust.
    func testBothModelMenusLeadWithABareAutomatic() throws {
        var machine = SettingsModel.MachineState()
        machine.editorEngines = ["spelling", "minimal", "standard", "full"]
        machine.editorEngineLabels = ["Spelling", "Minimal", "Standard", "Full"]
        let rows = SettingsModel.catalog(config: Config(), machine: machine).flatMap(\.rows)
        for path in ["editor.model", "draft.model"] {
            let model = try XCTUnwrap(rows.first { $0.path == path })
            guard case .choice(let options, let labels, _) = model.control else {
                return XCTFail("\(path) is a choice")
            }
            XCTAssertEqual(options.first, "", path)
            XCTAssertEqual(labels.first, "Automatic", path)
            XCTAssertEqual(labels.count, options.count, path)
        }
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

/// Which English the editor holds you to, inferred from the Mac.
final class EditorRegionTests: XCTestCase {
    func testTheMacsFirstEnglishDecides() {
        XCTAssertEqual(EditorRegion.inferred(preferredLanguages: ["en-US"], region: "US"), "en_US")
        XCTAssertEqual(EditorRegion.inferred(preferredLanguages: ["en-GB"], region: "GB"), "en_GB")
        XCTAssertEqual(EditorRegion.inferred(preferredLanguages: ["fr-FR", "en-CA"], region: "FR"), "en_CA",
                       "the first English, after another language")
        XCTAssertEqual(EditorRegion.inferred(preferredLanguages: ["en"], region: "AU"), "en_AU",
                       "a bare en takes the Mac's region")
        XCTAssertEqual(EditorRegion.inferred(preferredLanguages: ["en-IE"], region: "IE"), "en_GB",
                       "no Irish dictionary: Ireland spells the British way")
        XCTAssertEqual(EditorRegion.inferred(preferredLanguages: ["en-PH"], region: "PH"), "en_US")
        XCTAssertEqual(EditorRegion.inferred(preferredLanguages: ["de-DE"], region: "DE"), "en_US",
                       "no English at all: US English")
    }

    func testAChoiceStandsAndEmptyFollowsTheMac() {
        XCTAssertEqual(EditorRegion.resolved("en_NZ"), "en_NZ")
        XCTAssertEqual(EditorRegion.resolved(""), EditorRegion.inferred())
        XCTAssertEqual(EditorRegion.resolved("klingon"), EditorRegion.inferred())
    }

    func testTheModelIsToldOnlyWhenItIsNotUSEnglish() {
        XCTAssertNil(EditorRegion.instruction(for: "en_US"))
        XCTAssertTrue(EditorRegion.instruction(for: "en_GB")?.contains("colour and organise") == true)
        XCTAssertTrue(EditorRegion.instruction(for: "en_CA")?.contains("organize") == true)
    }

    func testTheConfigTakesAnyDictionaryAndDefaultsToAutomatic() {
        XCTAssertEqual(Config().editorLanguage, "")
    }
}

/// What the spell checker may mark: a typo's repair and nothing the writer
/// chose, a casing, an apostrophe, a name.
final class EditorSpellingMarksTests: XCTestCase {
    private func marks(_ word: String, caret: Int? = nil) -> [EditorIssue] {
        EditorSession().issues(text: "we said \(word) here today", caret: caret)
    }

    func testCasingAndApostrophesAreTheWritersOwn() {
        for word in ["jeff", "github", "iphone", "macos", "dont", "im", "ive", "youre", "isnt"] {
            XCTAssertTrue(marks(word).isEmpty, "\(word) is the writer's casing or apostrophe: \(marks(word).map(\.replacement))")
        }
    }

    func testAnswersThatAreTheWordInAnotherCaseOrApostropheAreDropped() {
        XCTAssertNil(EditorSpelling.fix(for: "dont", correction: "don't", guesses: ["don't", "done"]))
        XCTAssertNil(EditorSpelling.fix(for: "dont", correction: "don\u{2019}t", guesses: []), "curly too")
        XCTAssertNil(EditorSpelling.fix(for: "im", correction: nil, guesses: ["in", "I'm"]),
                     "the checker knows the letters: in is not the repair of im")
        XCTAssertNil(EditorSpelling.fix(for: "github", correction: "GitHub", guesses: ["GitHub", "Github"]))
        XCTAssertEqual(EditorSpelling.fix(for: "teh", correction: nil, guesses: ["the", "ten"]), "the")
    }

    func testRealTyposStillMark() {
        let typos = ["teh": "the", "recieve": "receive", "seperate": "separate", "definately": "definitely",
                     "wierd": "weird", "becuase": "because", "adn": "and", "thier": "their",
                     "untill": "until", "occured": "occurred"]
        for (typo, fix) in typos {
            XCTAssertEqual(marks(typo).map(\.replacement), [fix], typo)
        }
    }

    func testNamesAndJargonTheCheckerAnswersWithAStrangerAreLeftAlone() {
        for word in ["priya", "jira", "nyc", "kubectl", "slackbot", "ngl", "tbh", "grokbot", "kitsugi"] {
            XCTAssertTrue(marks(word).isEmpty, "\(word) → \(marks(word).map(\.replacement))")
        }
        XCTAssertNil(EditorSpelling.fix(for: "priya", correction: nil, guesses: ["prayer", "pray"]), "three away")
        XCTAssertNil(EditorSpelling.fix(for: "jira", correction: "Mira", guesses: ["Mira"]), "a name for a lowercase word")
        XCTAssertNil(EditorSpelling.fix(for: "kubectl", correction: nil, guesses: []), "no answer, no mark")
        XCTAssertNotNil(EditorSpelling.fix(for: "definately", correction: "definitely", guesses: []))
    }

    func testTheAllowanceGrowsWithTheWord() {
        XCTAssertEqual(EditorSpelling.allowance(forLength: 3), 1)
        XCTAssertEqual(EditorSpelling.allowance(forLength: 5), 1)
        XCTAssertEqual(EditorSpelling.allowance(forLength: 6), 2)
        XCTAssertEqual(EditorSpelling.allowance(forLength: 20), 2)
        XCTAssertNotNil(EditorSpelling.fix(for: "reciepts", correction: "receipts", guesses: []), "a swap and a slip")
        XCTAssertNil(EditorSpelling.fix(for: "abcd", correction: "abxy", guesses: []), "two away from four letters")
    }

    func testDistanceCountsASwapAsOne() {
        func d(_ a: String, _ b: String) -> Int { EditorSpelling.distance(Array(a), Array(b)) }
        XCTAssertEqual(d("teh", "the"), 1)
        XCTAssertEqual(d("recieve", "receive"), 1)
        XCTAssertEqual(d("kitten", "sitting"), 3)
        XCTAssertEqual(d("", "abc"), 3)
        XCTAssertEqual(d("priya", "prayer"), 3)
    }

    func testChatsOwnWordsAndWordsWithoutAVowelAreNeverMarks() {
        for word in ["ngl", "smh", "tfw", "nyc", "pls", "fomo"] {
            XCTAssertTrue(EditorSpelling.skips(word), word)
        }
        XCTAssertFalse(EditorSpelling.skips("recieve"))
    }

    // MARK: Sigils

    private func bare(_ text: String) -> [EditorIssue] {
        EditorSpelling.issues(in: text, caret: nil, language: "en_US", guards: EditorGuards(), protected: [])
    }

    func testAWordAfterASigilIsNotProse() {
        XCTAssertEqual(bare("go recieve now").map(\.replacement), ["receive"], "the control")
        for sigil in ["#", "@", "/", ":", "$", "~"] {
            XCTAssertTrue(bare("go \(sigil)recieve now").isEmpty, "\(sigil)recieve")
        }
        XCTAssertTrue(bare("react with :recieve: now").isEmpty)
    }

    func testALabelsColonIsPunctuationNotASigil() {
        XCTAssertEqual(bare("Note: recieve now").map(\.replacement), ["receive"])
    }

    // MARK: Vocabulary

    func testEachWordOfAMultiWordEntryReachesTheChecker() {
        XCTAssertEqual(bare("we recieve them").map(\.replacement), ["receive"], "the control")
        let guards = EditorGuards(vocabulary: ["Recieve Plan"])
        let found = EditorSpelling.issues(in: "we recieve them", caret: nil, language: "en_US",
                                          guards: guards, protected: [])
        XCTAssertTrue(found.isEmpty, "the entry is two words and the checker meets one at a time")
        XCTAssertEqual(Set(EditorSpelling.ignorable(["recieve plan", "solo"])), ["recieve plan", "recieve", "plan", "solo"])
    }

    func testTheCheckersIgnoredWordsIgnoreCase() {
        let guards = EditorGuards(vocabulary: ["recieve"])
        for form in ["recieve", "Recieve", "RECIEVE"] {
            XCTAssertTrue(EditorSpelling.issues(in: "we \(form) them", caret: nil, language: "en_US",
                                                guards: guards, protected: []).isEmpty, form)
        }
    }
}

/// The model's marks wait for the word the caret is in, as the spell
/// checker's and the rules' do.
final class EditorModelCaretTests: XCTestCase {
    func testAModelMarkOnTheWordBeingTypedWaits() {
        let session = EditorSession()
        let text = "Their going to push it."
        session.record(sentence: text, corrected: "They're going to push it.")
        XCTAssertEqual(session.issues(text: text, caret: nil).count, 1)
        XCTAssertTrue(session.issues(text: text, caret: 3).isEmpty, "inside the word")
        XCTAssertTrue(session.issues(text: text, caret: 5).isEmpty, "just after it")
        XCTAssertEqual(session.issues(text: text, caret: 6).count, 1, "a space on, the word is finished")
        XCTAssertEqual(session.issues(text: text, caret: 20).count, 1, "elsewhere in the sentence")
    }

    func testAFinishedSentencesClosingPunctuationIsNotTheWord() {
        let session = EditorSession()
        let text = "We went to their."
        session.record(sentence: text, corrected: "We went to there.")
        let end = (text as NSString).length
        XCTAssertEqual(session.issues(text: text, caret: end).map(\.replacement), ["there."], "past the full stop")
        XCTAssertTrue(session.issues(text: text, caret: end - 1).isEmpty, "before the full stop")
    }
}

/// A keep outlives the typing of the sentence it was made in.
final class EditorKeepTests: XCTestCase {
    func testAKeepOnTheModelsMarkHoldsAsTheSentenceGrows() {
        let session = EditorSession()
        let first = "Their going to push it"
        session.record(sentence: first, corrected: "They're going to push it")
        session.dismissOnce(session.issues(text: first, caret: nil)[0], in: first)
        let grown = first + " now"
        session.record(sentence: grown, corrected: "They're going to push it now")
        XCTAssertTrue(session.issues(text: grown, caret: nil).isEmpty, "the next keystroke does not bring it back")
        let more = grown + " tonight, then lunch."
        session.record(sentence: more, corrected: "They're going to push it now tonight, then lunch.")
        XCTAssertTrue(session.issues(text: more, caret: nil).isEmpty)
    }

    func testAKeepOnASpellingMarkHoldsAsTheSentenceGrows() {
        let session = EditorSession()
        let first = "We need to recieve"
        let tail = first + " them"
        let issue = session.issues(text: tail, caret: nil)[0]
        session.dismissOnce(issue, in: tail)
        XCTAssertTrue(session.issues(text: tail + " soon", caret: nil).isEmpty)
        XCTAssertTrue(session.issues(text: tail + " soon, and then more", caret: nil).isEmpty)
    }

    func testAKeepOnARuleHoldsAsTheSentenceGrows() {
        let session = EditorSession()
        let text = "I think the the plan"
        let issue = session.issues(text: text, caret: nil)[0]
        session.dismissOnce(issue, in: text)
        XCTAssertTrue(session.issues(text: text + " works", caret: nil).isEmpty)
    }

    func testAKeepIsReadAfreshWhenTheWordsBeforeItChange() {
        let session = EditorSession()
        let text = "We need to recieve them"
        session.dismissOnce(session.issues(text: text, caret: nil)[0], in: text)
        XCTAssertEqual(session.issues(text: "So we need to recieve them", caret: nil).map(\.original), ["recieve"],
                       "the lead-in changed: a different sentence")
    }

    func testTheSameChangeInAnotherSentenceIsNotKept() {
        let session = EditorSession()
        let text = "Their going to push it. Their going to ship it."
        session.record(sentence: "Their going to push it.", corrected: "They're going to push it.")
        session.record(sentence: "Their going to ship it.", corrected: "They're going to ship it.")
        let marks = session.issues(text: text, caret: nil)
        XCTAssertEqual(marks.count, 2)
        session.dismissOnce(marks[0], in: text)
        XCTAssertEqual(session.issues(text: text, caret: nil).map(\.range.location), [marks[1].range.location])
    }

    func testAKeepSurvivesAnEditInAnEarlierSentence() {
        let session = EditorSession()
        let text = "Hello there. We need to recieve them."
        session.dismissOnce(session.issues(text: text, caret: nil)[0], in: text)
        XCTAssertTrue(session.issues(text: "Hello there, friend. We need to recieve them.", caret: nil).isEmpty,
                      "the sentence moved on in the field, and is still the second")
    }

    func testKeepsAreLetGoWhenTheFieldIsReadEmpty() {
        let session = EditorSession()
        let text = "We need to recieve them."
        session.dismissOnce(session.issues(text: text, caret: nil)[0], in: text)
        XCTAssertTrue(session.issues(text: text, caret: nil).isEmpty)
        XCTAssertTrue(session.issues(text: "", caret: nil).isEmpty)
        XCTAssertEqual(session.issues(text: text, caret: nil).map(\.original), ["recieve"], "sent, and written afresh")
    }

    func testAKeepDoesNotSilenceAnotherMistakeInTheSameSentence() {
        let session = EditorSession()
        let text = "We need to recieve them and seperate it"
        let issues = session.issues(text: text, caret: nil)
        XCTAssertEqual(issues.map(\.original), ["recieve", "seperate"])
        session.dismissOnce(issues[0], in: text)
        XCTAssertEqual(session.issues(text: text, caret: nil).map(\.original), ["seperate"])
    }
}

/// A question the model did not answer is asked again, a little later.
final class EditorRetryTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var at = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { at = at.addingTimeInterval(seconds) }
    }

    private let text = "Their going to push it."

    private func asked(_ session: EditorSession) -> Bool {
        !session.sentencesToCheck(text: text, caret: nil, paused: true).isEmpty
    }

    func testAnUnansweredSentenceIsAskedAgainAfterTenSecondsThenAMinute() {
        let clock = Clock()
        let session = EditorSession(now: { clock.at })
        XCTAssertTrue(asked(session))
        session.record(sentence: text, corrected: nil)
        XCTAssertFalse(asked(session), "not at once")
        clock.advance(9)
        XCTAssertFalse(asked(session))
        clock.advance(1)
        XCTAssertTrue(asked(session), "ten seconds on")
        session.record(sentence: text, corrected: nil)
        clock.advance(59)
        XCTAssertFalse(asked(session))
        clock.advance(1)
        XCTAssertTrue(asked(session), "a minute after the second failure")
        session.record(sentence: text, corrected: nil)
        clock.advance(86_400)
        XCTAssertFalse(asked(session), "two retries, then it is given up on while the text stands")
    }

    func testAnAnswerEndsTheRetries() {
        let clock = Clock()
        let session = EditorSession(now: { clock.at })
        session.record(sentence: text, corrected: nil)
        clock.advance(10)
        XCTAssertTrue(asked(session))
        session.record(sentence: text, corrected: "They're going to push it.")
        clock.advance(86_400)
        XCTAssertFalse(asked(session))
        XCTAssertEqual(session.issues(text: text, caret: nil).map(\.replacement), ["They're"])
    }

    func testSpellingStillSpeaksWhileTheSentenceWaits() {
        let clock = Clock()
        let session = EditorSession(now: { clock.at })
        let typo = "We need to recieve them."
        session.record(sentence: typo, corrected: nil)
        XCTAssertEqual(session.issues(text: typo, caret: nil).map(\.original), ["recieve"])
    }

    func testEachSentenceKeepsItsOwnWait() {
        let clock = Clock()
        let session = EditorSession(now: { clock.at })
        let two = "Their going to push it. Let me know if your coming."
        session.record(sentence: "Their going to push it.", corrected: nil)
        clock.advance(10)
        session.record(sentence: "Let me know if your coming.", corrected: nil)
        XCTAssertEqual(session.sentencesToCheck(text: two, caret: nil, paused: true), ["Their going to push it."])
    }
}

/// The writer's register and punctuation are theirs: what the Standard
/// model marked in 265 passages of the maker's dictated text that were
/// style, not slips, are not offered.
final class EditorStyleTests: XCTestCase {
    private func issues(_ text: String, _ corrected: String) -> [EditorIssue] {
        let ns = text as NSString
        return EditorDiff.issues(text: ns, sentence: NSRange(location: 0, length: ns.length),
                                 corrected: corrected, guards: EditorGuards(),
                                 protected: EditorText.protectedRanges(in: text))
    }

    func testAContractionWrittenOutIsNotAMistake() {
        XCTAssertTrue(issues("I think it's fine.", "I think it is fine.").isEmpty)
        XCTAssertTrue(issues("It\u{2019}s fine today.", "It is fine today.").isEmpty, "curly, case kept")
        XCTAssertTrue(issues("I think there's a bug.", "I think there is a bug.").isEmpty)
        XCTAssertTrue(issues("Whatever's left is fine.", "Whatever is left is fine.").isEmpty)
        XCTAssertTrue(issues("The layout's broken now.", "The layout is broken now.").isEmpty)
        XCTAssertTrue(issues("We don't know yet.", "We do not know yet.").isEmpty)
        XCTAssertTrue(issues("They're late and we'll wait.", "They are late and we will wait.").isEmpty)
        XCTAssertTrue(issues("I've seen it and I'm sure.", "I have seen it and I am sure.").isEmpty)
        XCTAssertTrue(issues("He'd go if she'd ask.", "He would go if she had ask.").isEmpty)
        XCTAssertTrue(issues("I can't see it.", "I cannot see it.").isEmpty)
        XCTAssertTrue(issues("I won't go.", "I will not go.").isEmpty)
    }

    func testTheRealErrorsAroundContractionsStillMark() {
        XCTAssertEqual(issues("I think its fine.", "I think it's fine.").map(\.replacement), ["it's"])
        XCTAssertEqual(issues("The dog wagged it's tail.", "The dog wagged its tail.").map(\.replacement), ["its"])
        XCTAssertEqual(issues("I think your right.", "I think you're right.").map(\.replacement), ["you're"])
        XCTAssertEqual(issues("Their going home.", "They're going home.").map(\.replacement), ["They're"])
        XCTAssertEqual(issues("I think there's two bugs.", "I think there are two bugs.").map(\.replacement), ["there are"],
                       "agreement, not an expansion")
        XCTAssertFalse(issues("We don't know yet.", "We do not care yet.").isEmpty, "an expansion plus another change")
    }

    func testDigitsAndNumberWordsAreTheWritersChoice() {
        XCTAssertTrue(issues("I have 2 cats.", "I have two cats.").isEmpty)
        XCTAssertTrue(issues("I have two cats.", "I have 2 cats.").isEmpty)
        XCTAssertTrue(issues("We met 25 times.", "We met twenty five times.").isEmpty)
        XCTAssertTrue(issues("We met twenty-five times.", "We met 25 times.").isEmpty)
        XCTAssertTrue(issues("We need 100 of them.", "We need one hundred of them.").isEmpty)
        XCTAssertFalse(issues("I have 2 cats.", "I have three cats.").isEmpty, "a different number is a change")
        XCTAssertFalse(issues("I have to cats.", "I have two cats.").isEmpty, "to for two is a homophone slip")
    }

    func testACommaBeforeAConjunctionIsTheWritersBreath() {
        for conjunction in ["and", "because", "when", "but", "or", "while", "though", "although", "since", "yet", "as"] {
            let text = "I describe a feature, \(conjunction) I like it."
            let model = "I describe a feature \(conjunction) I like it."
            XCTAssertTrue(issues(text, model).isEmpty, conjunction)
        }
        XCTAssertTrue(issues("Ship it, so that we can rest.", "Ship it so that we can rest.").isEmpty)
        XCTAssertEqual(issues("Ship it, so we can rest.", "Ship it so we can rest.").map(\.shown), ["remove comma"],
                       "so alone is not a conjunction here")
    }

    func testACommaAfterALoneSentenceOpenerIsTheWritersBreath() {
        for opener in ["However", "Also", "So", "Actually", "Honestly", "Well", "Yes", "No", "Okay", "Please"] {
            XCTAssertTrue(issues("\(opener), we ship it.", "\(opener) we ship it.").isEmpty, opener)
        }
        XCTAssertEqual(issues("Could you please, review the draft?", "Could you please review the draft?").map(\.shown),
                       ["remove comma"], "mid-sentence, a stray")
        XCTAssertEqual(issues("Tomorrow, we ship it.", "Tomorrow we ship it.").map(\.shown), ["remove comma"],
                       "only the listed openers")
    }

    func testStrayCommasStillMark() {
        XCTAssertEqual(issues("We talked about, the workflow.", "We talked about the workflow.").map(\.shown), ["remove comma"])
        XCTAssertEqual(issues("I like your, recommendations.", "I like your recommendations.").map(\.shown), ["remove comma"])
        XCTAssertEqual(issues("Treat it as someone, who knows.", "Treat it as someone who knows.").map(\.shown), ["remove comma"])
        XCTAssertEqual(issues("The new policy, applies to everyone.", "The new policy applies to everyone.").map(\.shown),
                       ["remove comma"])
    }
}
