import XCTest
@testable import LodestarCore

/// The draft's settling pipeline: seams, casing, self-corrections, and
/// names by sound. The thresholds were measured on 175 recordings; these
/// hold the behaviours that made them safe.
final class DictationTests: XCTestCase {
    private static let packaging = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("packaging")
    private static let pronouncer: Pronouncer = {
        CommonWords.frequentListURL = packaging.appendingPathComponent("common-words.txt")
        let text = (try? String(contentsOf: packaging.appendingPathComponent("cmudict.dict"), encoding: .utf8)) ?? ""
        return Pronouncer(cmu: text)
    }()
    private let ordinary: (String) -> Bool = { CommonWords.isCommon($0) }

    private func matcher(_ words: [String]) -> NameMatcher {
        NameMatcher(terms: words.map { NameMatcher.Term($0) }, pronouncer: Self.pronouncer,
                    isCommon: { CommonWords.isCommon($0) }, isFrequent: { CommonWords.isFrequent($0) })
    }

    private let names = ["Lodestar", "Ghostty", "Xonar", "Kindora", "Supabase", "Asana", "MongoDB", "Compass",
                         "UAT", "Proton Pass", "Claude Code", "SwiftUI", "Raycast", "Kinesis", "Convex", "Telegram"]

    // MARK: - Seams

    func testAnEllipsisNeverLands() {
        XCTAssertEqual(Draft.Seams.smoothed("I was going to say... the deploy failed", isOrdinary: ordinary).text,
                       "I was going to say. The deploy failed", "a trailed-off end gets a period")
        XCTAssertEqual(Draft.Seams.smoothed("bracketed paste, but... I'm not sure", isOrdinary: ordinary).text,
                       "bracketed paste, but I'm not sure", "a pause after a word that cannot end a sentence joins")
        XCTAssertEqual(Draft.Seams.smoothed("…so then", isOrdinary: ordinary).text, "so then")
        let trailing = Draft.Seams.smoothed("and then we...", isOrdinary: ordinary)
        XCTAssertEqual(trailing.text, "and then we")
        XCTAssertTrue(trailing.trailedOff, "the next result decides")
    }

    func testAPauseBreakAfterADanglingWordJoins() {
        let joined = Draft.Seams.join(before: "Open the file and look at the.", incoming: "Function that closes it.",
                                      pause: true, trailedOff: false, isOrdinary: ordinary)
        XCTAssertEqual(joined.before, "Open the file and look at the")
        XCTAssertEqual(joined.incoming, "function that closes it.")
        let real = Draft.Seams.join(before: "That is what the app is.", incoming: "Then we ship.",
                                    pause: true, trailedOff: false, isOrdinary: ordinary)
        XCTAssertEqual(real.before, "That is what the app is.", "a real end stays")
        XCTAssertEqual(real.incoming, "Then we ship.")
        let names = Draft.Seams.join(before: "I sent it to.", incoming: "Paris already.",
                                     pause: true, trailedOff: false, isOrdinary: { _ in false })
        XCTAssertEqual(names.incoming, "Paris already.", "a name keeps its capital")
        let typed = Draft.Seams.join(before: "look at the.", incoming: "Function", pause: true, trailedOff: false,
                                     typedBetween: true, isOrdinary: ordinary)
        XCTAssertEqual(typed.before, "look at the.", "the hand typed between: its text decides")
        let quick = Draft.Seams.join(before: "look at the.", incoming: "Function", pause: false, trailedOff: false,
                                     isOrdinary: ordinary)
        XCTAssertEqual(quick.before, "look at the.", "no pause, no join")
    }

    func testCasingKeepsIAndNames() {
        XCTAssertEqual(Draft.cased("I'm sure", after: Array("and")), "I'm sure")
        XCTAssertEqual(Draft.cased("I’ll go", after: Array("then")), "I’ll go")
        XCTAssertEqual(Draft.cased("Paris is nice", after: Array("we went to"), isOrdinary: { $0 != "paris" }),
                       "Paris is nice")
        XCTAssertEqual(Draft.cased("Ghostty is open", after: Array("so"), isOrdinary: ordinary), "Ghostty is open")
        XCTAssertEqual(Draft.cased("Then it works", after: Array("and"), isOrdinary: ordinary), "then it works")
    }

    // MARK: - Self-corrections

    func testCuesTakeBackWhatTheyCorrect() {
        XCTAssertEqual(Draft.SelfCorrection.apply("Schedule the review for Monday, no wait, I mean Tuesday, at 10.").text,
                       "Schedule the review for Tuesday, at 10.")
        XCTAssertEqual(Draft.SelfCorrection.apply("Push it, scratch that, commit it first.").text, "Commit it first.")
        XCTAssertEqual(Draft.SelfCorrection.apply("Post it on Slack, or actually on Telegram.").text,
                       "Post it on Telegram.")
    }

    func testOrdinarySpeechIsLeftAlone() {
        for text in ["No, I think we should wait.", "I mean it.", "Sorry to bother you.", "Actually it works."] {
            XCTAssertEqual(Draft.SelfCorrection.apply(text).text, text, text)
        }
    }

    func testFillersGo() {
        XCTAssertEqual(Draft.SelfCorrection.withoutFillers("Um, so we, uh, ship it.").0, "So we ship it.")
        XCTAssertEqual(Draft.SelfCorrection.withoutFillers("the umbrella and the hum").0, "the umbrella and the hum")
    }

    // MARK: - Pronunciations

    func testNamesTheDictionaryLacksAreReadFromTheirPieces() {
        let p = Self.pronouncer
        XCTAssertEqual(p.phones("Supabase"), ["S", "UW", "P", "AH", "B", "EY", "S"])
        XCTAssertEqual(p.phones("Kindora"), ["K", "IH", "N", "D", "AO", "R", "AH"])
        XCTAssertEqual(p.phones("UAT"), ["Y", "UW", "EY", "T", "IY"])
        XCTAssertEqual(p.phones("SwiftUI"), ["S", "W", "IH", "F", "T", "Y", "UW", "AY"])
        XCTAssertLessThan(Pronouncer.distance(p.phones("load star"), p.phones("Lodestar")), 0.05)
        XCTAssertLessThan(Pronouncer.distance(p.phones("super base"), p.phones("Supabase")), 0.1)
        XCTAssertGreaterThan(Pronouncer.distance(p.phones("vaccine"), p.phones("Vaccone")), 0.2)
    }

    // MARK: - Names

    func testNamesComeBackBySound() {
        let m = matcher(names)
        XCTAssertEqual(m.apply("make load star back off when ray cast is running").text,
                       "make Lodestar back off when Raycast is running")
        XCTAssertEqual(m.apply("check the super base migration").text, "check the Supabase migration")
        XCTAssertEqual(m.apply("ask Cloud Code to fix it").text, "ask Claude Code to fix it")
        XCTAssertEqual(m.apply("move the Zona tasks into the can Dora board").text,
                       "move the Xonar tasks into the Kindora board")
        XCTAssertEqual(m.apply("open lodestar's log").text, "open Lodestar's log")
    }

    func testOrdinaryWordsStay() {
        let m = matcher(names)
        XCTAssertEqual(m.apply("the ghost text sticks around").text, "the ghost text sticks around")
        XCTAssertEqual(m.apply("a ghostly ghastly sound").text, "a ghostly ghastly sound")
        XCTAssertEqual(m.apply("get the vaccine").text, "get the vaccine")
        XCTAssertEqual(m.apply("compare the compass and a convex hull").text, "compare the compass and a convex hull",
                       "a name that is an everyday word is capitalized by its context, never by sound")
        XCTAssertEqual(m.apply("Compare MongoDB Compass").text, "Compare MongoDB Compass")
        XCTAssertEqual(m.apply("ship Lodestar 0.39.5 tonight").text, "ship Lodestar 0.39.5 tonight")
        XCTAssertEqual(m.apply("read lodestar.log and local/dev").text, "read lodestar.log and local/dev",
                       "code stays code")
    }

    func testAnUnsureOrdinaryWordMayBecomeAName() {
        let m = matcher(["Kash"])
        let unsure = m.apply(tokens: [.init("ask"), .init("cache", confidence: 0.3), .init("about")])
        XCTAssertEqual(unsure.text, "ask Kash about")
        let sure = m.apply(tokens: [.init("clear"), .init("cache", confidence: 0.95), .init("first")])
        XCTAssertEqual(sure.text, "clear cache first", "a word the recognizer was sure of stays")
    }

    func testPunctuationRidesAlong() {
        let m = matcher(names)
        XCTAssertEqual(m.apply("open ghosty, then (lodestar).").text, "open Ghostty, then (Lodestar).")
    }

    // MARK: - The whole pipeline

    func testTheSettlerJoinsAPauseAndPutsNamesBack() {
        var settler = Draft.Settler(matcher: matcher(names), isOrdinary: ordinary)
        let first = settler.land(Heard("Open load star and look at the.", words: [Heard.Word("Open load star and look at the.", start: 0, end: 2)]),
                                 after: "")
        XCTAssertEqual(first.text, "Open Lodestar and look at the.")
        let second = settler.land(Heard("Function that closes it.", words: [Heard.Word("Function that closes it.", start: 4, end: 5.5)]),
                                  after: first.text)
        XCTAssertEqual(second.before, .dropPeriod)
        XCTAssertEqual(second.text, "function that closes it.")
    }

    func testTheSettlerReachesBackForACorrection() {
        var settler = Draft.Settler(isOrdinary: ordinary)
        let first = settler.land(Heard("Send it on Monday."), after: "")
        let second = settler.land(Heard("No wait, I mean Tuesday."), after: first.text)
        XCTAssertTrue(second.replacesLast)
        XCTAssertEqual(second.text, "Send it on Tuesday.")
    }
}

/// Names in code: found in the repository from how they are said, and
/// restyled by one key when they do not exist yet.
final class CodeNamesTests: XCTestCase {
    private let isWord: (String) -> Bool = { CommonWords.isCommon($0) }
    private func index(_ names: [String]) -> CodeNames.Index {
        CodeNames.Index(names: names, pronouncer: Pronouncer())
    }

    func testEachStyle() {
        let text = "draft controller"
        XCTAssertEqual(CodeNames.restyled(text, as: .pascal, isWord: isWord), "DraftController")
        XCTAssertEqual(CodeNames.restyled(text, as: .camel, isWord: isWord), "draftController")
        XCTAssertEqual(CodeNames.restyled(text, as: .snake, isWord: isWord), "draft_controller")
        XCTAssertEqual(CodeNames.restyled(text, as: .kebab, isWord: isWord), "draft-controller")
        XCTAssertEqual(CodeNames.restyled(text, as: .upperSnake, isWord: isWord), "DRAFT_CONTROLLER")
        XCTAssertEqual(CodeNames.restyled("draftController", as: .words, isWord: isWord), "draft controller")
    }

    func testAnExtensionRidesAlong() {
        XCTAssertEqual(CodeNames.restyled("draft controller dot swift", as: .pascal, isWord: isWord), "DraftController.swift")
        XCTAssertEqual(CodeNames.restyled("DraftController.swift", as: .camel, isWord: isWord), "draftController.swift")
    }

    func testARunTogetherWordIsSplitFirst() {
        XCTAssertEqual(CodeNames.restyled("draftcontroller", as: .pascal, isWord: isWord), "DraftController")
    }

    func testRepositoryNamesAreWrittenAsTheCodeWritesThem() {
        let names = index(["DraftController.swift", "settleGhostAsSeen", "local/dev", "isRunning", "setUp", "Draft",
                           "WindowModel"])
        let common: (String) -> Bool = { CommonWords.isCommon($0) }
        XCTAssertEqual(names.apply("open draft controller dot swift and look", isCommon: common).text,
                       "open DraftController.swift and look")
        XCTAssertEqual(names.apply("open draftcontroller.swift now", isCommon: common).text,
                       "open DraftController.swift now")
        XCTAssertEqual(names.apply("rebase local slash dev on main", isCommon: common).text,
                       "rebase local/dev on main")
        XCTAssertEqual(names.apply("find where settle ghost as seen is called", isCommon: common).text,
                       "find where settleGhostAsSeen is called")
    }

    func testEverydayPhrasesStayProse() {
        let names = index(["isRunning", "setUp", "WindowModel", "HintLabels", "Draft"])
        let common: (String) -> Bool = { CommonWords.isCommon($0) }
        for text in ["back off when Raycast is running", "set up the board", "the window model is stale",
                     "the hint labels overlap", "send the draft"] {
            XCTAssertEqual(names.apply(text, isCommon: common).text, text, text)
        }
    }
}

/// `cr` and a style in the draft's editor (vim-abolish's coerce): the
/// name under the cursor or the selection, one undo step.
final class RestyleKeyTests: XCTestCase {
    private func keys(_ vim: inout Vim, _ buffer: inout Draft.Buffer, _ text: String) -> [Vim.Effect] {
        var effects: [Vim.Effect] = []
        for c in text { effects += vim.key(.char(c), buffer: &buffer, pasteboard: { nil }) }
        return effects
    }

    private func normal(_ text: String, at cursor: Int) -> (Vim, Draft.Buffer) {
        var buffer = Draft.Buffer(text: text, cursor: cursor)
        var vim = Vim()
        vim.enterNormal(&buffer)
        buffer.setCursor(cursor)
        return (vim, buffer)
    }

    func testCrNamesTheStyle() {
        var (vim, buffer) = normal("open draftcontroller.swift now", at: 7)
        _ = keys(&vim, &buffer, "crp")
        XCTAssertEqual(buffer.text, "open DraftController.swift now")
        _ = keys(&vim, &buffer, "crc")
        XCTAssertEqual(buffer.text, "open draftController.swift now")
        _ = keys(&vim, &buffer, "crs")
        XCTAssertEqual(buffer.text, "open draft_controller.swift now")
        _ = keys(&vim, &buffer, "u")
        XCTAssertEqual(buffer.text, "open draftController.swift now", "one undo step each")
    }

    func testACountTakesThatManyWords() {
        var (vim, buffer) = normal("call it model store dot swift.", at: 8)
        _ = keys(&vim, &buffer, "4crp")
        XCTAssertEqual(buffer.text, "call it ModelStore.swift.", "the sentence's period stays outside the name")
    }

    func testCrStillLeavesOtherChangesAlone() {
        var (vim, buffer) = normal("one two three", at: 4)
        _ = keys(&vim, &buffer, "cw")
        XCTAssertEqual(buffer.text, "one  three")
    }
}

/// The dictation journal: one line a dictation, kept only as long as asked.
final class DictationJournalTests: XCTestCase {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("journal-\(UUID().uuidString)", isDirectory: true)
    }

    func testADictationIsOneLineWithWhatWasHeardAndSent() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = DictationJournal(folder: dir, days: 14)
        let now = Date()
        journal.begin(app: "Ghostty", at: now)
        journal.heard(Heard("Open load star", words: [.init("Open load star", start: 0, end: 1)]),
                      landed: "Open Lodestar", at: now)
        journal.earHeard("qwen3-asr-1.7b", heard: "Open Lodestar.", stood: "Open Lodestar", placed: nil, seconds: 0.4, at: now)
        journal.finish("pasted", text: "Open Lodestar now", at: now)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 1)
        let line = try String(contentsOf: dir.appendingPathComponent(files[0]), encoding: .utf8)
        let entry = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(entry["text"] as? String, "Open Lodestar now")
        XCTAssertEqual(entry["app"] as? String, "Ghostty")
        XCTAssertEqual((entry["events"] as? [Any])?.count, 2)
    }

    func testNothingHeardIsNothingKept() {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let journal = DictationJournal(folder: dir, days: 14)
        journal.begin(app: nil, at: Date())
        journal.finish("empty", text: "", at: Date())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testOldDaysAreDeleted() throws {
        let dir = folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("2020-01-01.jsonl"))
        let today = DictationJournal.day(Date())
        try Data().write(to: dir.appendingPathComponent("\(today).jsonl"))
        _ = DictationJournal(folder: dir, days: 7)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["\(today).jsonl"])
    }
}
