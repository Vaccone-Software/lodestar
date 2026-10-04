import XCTest
@testable import LodestarCore

/// The intent pass's checker, held to the original it was ported from:
/// the probe's own cases, then every verdict the Python checker gave on the
/// hand-written text set, its seven models' rewrites, and every deletion
/// of one to four words from it (Fixtures/intent-checker.json).
final class IntentCheckerTests: XCTestCase {
    func testTheProbesOwnCases() {
        let cases: [(String, String, Bool)] = [
            ("Rename it to draft controller dot swift.", "Rename it to DraftController.swift.", true),
            ("Rename it to draft controller dot swift.", "Rename it to draft_controller.swift.", false),
            ("Read the last lines of Lodestar dot log.", "Read the last lines of Lodestar_dot_log.", false),
            ("Turn on row level security.", "Turn on row-level security.", true),
            ("Compute the dot product of the two vectors.", "Compute the.product of the two vectors.", false),
            ("Compute the dot product of the two vectors.", "Compute the dot product of the two vectors.", true),
            ("Send it to Mahavir, wait, I didn't mean him, send it to Ana.", "Send it to Ana.", true),
            ("Use the red one, actually no, the blue one.", "Use the blue one.", true),
            ("First, fix the build. Second, run the tests. Third, ship it.",
             "1. Fix the build.\n2. Run the tests.\n3. Ship it.", true),
            ("The first thing I noticed is that the second panel never closes.",
             "1. Thing I noticed\n2. Panel never closes", false),
            ("Um, so like, I think we should, uh, refactor this.", "I think we should refactor this.", true),
            ("I mean, can you pick it up and then wind it for 2 minutes?",
             "I can pick it up and then wind it for 2 minutes?", false),
            ("Check the logs in slash var slash log.", "Check the logs in /var/log.", true),
            ("Run the build with dash dash verbose.", "Run the build with --verbose.", true),
            ("Open the read me dot md file.", "Open the README.md file.", true),
            ("Bump it to version two point three.", "Bump it to version 2.3.", true),
            ("Open capital D R A F T capital C O N T R O L L E R dot Swift, and look.",
             "Open DraftController.swift and look.", true),
            ("Set it so the thumb key sends M E H. Then test it.", "Set it so the thumb key sends meh, then test it.", true),
            ("The meeting is at three, sorry four p.m. on Thursday.", "The meeting is at 4 PM on Thursday.", true),
            ("So the thing the thing is Lodestar keeps keeps losing focus when when Raycast opens.",
             "The thing is, Lodestar keeps losing focus when Raycast opens.", true),
            ("Use MongoDB Compass to actually let's use the Convex dashboard instead to look at the users table.",
             "Use the Convex dashboard to look at the users table.", true),
            ("Kill whatever is holding port, 3000. Restart the Expo dev server.",
             "Kill whatever is holding port 3000, restart the Expo dev server.", true),
            ("Find every place we call the Brex API.", "Find every place we call the Brex API endpoint.", false),
            ("The Expo dev server is backed up.", "The Expo dev server is back up.", false),
            ("Schedule the UAT review for Monday. No eight, I mean Tuesday at 10 a.m.",
             "Schedule the UAT review for Tuesday at 10 AM.", true),
            ("So it can either come back as a, you can have the hashtable, or you can have it returned as a vector.",
             "So it can either come back as a, you can have it returned as a vector.", false),
            ("Open capital DRAFT, capital C-O-N-T-R-O-L-L-E-R dot swift, and look.",
             "Open DraftController.swift and look.", true),
            ("Send the invoice to Maria, actually, send it to Sam and Maria.", "Send the invoice to Sam and Maria.", true),
            ("The meeting is at three, sorry four p.m. on Thursday.", "The meeting is at p.m. on Thursday.", false),
            ("Schedule the UAT review for I mean Tuesday at 10 AM.", "Schedule the UAT review for Tuesday at 10 AM.", true),
            ("Make the button bigger, wait, no, make it smaller.", "Make the button bigger, make it smaller.", false),
            ("Type slash compact when the context gets long.", "Type /compact when the context gets long.", true),
            ("Go to google dot com and search.", "Go to google.com and search.", true),
            ("Add a field called user underscore id.", "Add a field called user_id.", true),
            ("Add a field called user id.", "Add a field called user_id.", false),
            ("Add a field called user id.", "Add a field called user/id.", false),
        ]
        for (said, rewrite, want) in cases {
            let verdict = IntentChecker.check(said, rewrite)
            XCTAssertEqual(verdict.ok, want, "\(said) → \(rewrite): \(verdict.reason)")
        }
    }

    func testTheTextIsItselfAndNothingIsLeftEmpty() {
        let said = "Explain why the window model runs off the main thread and write it up in the readme."
        XCTAssertTrue(IntentChecker.check(said, said).ok)
        XCTAssertFalse(IntentChecker.check(said, "").ok)
        XCTAssertFalse(IntentChecker.check(said, "The window model runs off the main thread.").ok)
    }

    func testTheListCountsItsItems() {
        let verdict = IntentChecker.check("First, pull main. Second, rebase local slash dev. And third, run the tests.",
                                          "1. Pull main.\n2. Rebase local/dev.\n3. Run the tests.")
        XCTAssertTrue(verdict.ok, verdict.reason)
        XCTAssertEqual(verdict.listItems, 3)
    }

    private struct Fixture: Decodable {
        let inputs: [String]
        let cases: [Case]
        struct Case: Decodable {
            let input: Int, output: String, ok: Bool, reason: String, edits: [String]
            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                input = try c.decode(Int.self)
                output = try c.decode(String.self)
                ok = try c.decode(Bool.self)
                reason = try c.decode(String.self)
                edits = try c.decode([String].self)
            }
        }
    }

    func testEveryVerdictTheOriginalGave() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/intent-checker.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(fixture.cases.count, 2000)
        var differ = 0
        for item in fixture.cases {
            let said = fixture.inputs[item.input]
            let verdict = IntentChecker.check(said, item.output)
            if verdict.ok != item.ok || verdict.reason != item.reason || verdict.edits.map(\.kind) != item.edits {
                differ += 1
                if differ <= 20 {
                    XCTFail("\(said) → \(item.output)\n  python \(item.ok) \(item.reason) \(item.edits)\n"
                        + "  swift  \(verdict.ok) \(verdict.reason) \(verdict.edits.map(\.kind))")
                }
            }
        }
        XCTAssertEqual(differ, 0)
    }

    /// The checker's purpose in one number: of every one-to-four-word span
    /// deleted from ordinary text, almost none pass.
    func testArbitraryDeletionsRarelyPass() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/intent-checker.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let plain = [
            "Explain why the window model runs off the main thread and write it up in the readme.",
            "Add a test that opens the draft, speaks two sentences, and checks that both land in order.",
            "Look at how the clipboard strip decides which card is selected when the list changes.",
            "Find where the updater compares versions and make sure it compares them as numbers.",
            "Write a short summary of what changed in the settings window for the release notes.",
        ] + fixture.inputs
        var total = 0, accepted = 0
        for text in plain {
            let words = text.split(separator: " ").map(String.init)
            for length in 1...4 where words.count > length {
                for i in 0...(words.count - length) {
                    let span = words[i..<(i + length)]
                    if span.allSatisfy({ IntentChecker.fillers.contains($0.lowercased().filter(\.isLetter)) }) { continue }
                    let cut = (words[..<i] + words[(i + length)...]).joined(separator: " ")
                    total += 1
                    if IntentChecker.check(text, cut).ok { accepted += 1 }
                }
            }
        }
        // The fixture's inputs are dictation full of take-backs and stutters,
        // so they pass more than ordinary speech's 1%.
        let rate = Double(accepted) / Double(total)
        print("intent checker · \(accepted) of \(total) arbitrary deletions accepted (\(String(format: "%.1f", rate * 100))%)")
        XCTAssertLessThan(rate, 0.05)
    }
}
