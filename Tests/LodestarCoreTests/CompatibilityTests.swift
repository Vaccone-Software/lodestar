import Foundation
import StoicJSON
import StoicSchema
import StoicSchemaTesting
import StoicSettings
import XCTest
@testable import LodestarCore

// Schema compatibility (Stoic design/32): a released format is a promise, and
// this is the test that keeps it.
//
// Three formats are written by one build and read by another, and the
// outbox's reader deletes what it cannot read (`onUndecodable: .discard`), so
// a format that drifts costs a person something silently:
//
//   feedback-entry  a note waiting in the outbox (FeedbackEntry's codec). An
//                   update that is rolled back runs the older decoder over
//                   what the newer build queued, and a note it cannot read is
//                   dropped.
//   config          lodestar.json, as the store reads it (ConfigFile.schema).
//                   A person's file outlives every release that touched it.
//   state           the machine's state (PersistedState, StateFiles.decode;
//                   StateMigrations lifts an old version before the decode).
//
// What is checked, per format:
//
//   - Every released payload under Compatibility/<format>/<release>/ reads
//     with today's reader, through the reader's own entry (the store's read
//     for the config, the codec for the entry, StateFiles.decode for the
//     state). A failure names the release, the sample, the path and why.
//   - What today writes is read by the release before: against the reader
//     kept as `_schema.json` (the JSON Schema of that release's decoder), and,
//     for the entry and the state, against that release's Codable decoder kept
//     verbatim in CompatibilityReleased.swift.
//
// The fixtures. One folder per format, one per release, one file per payload,
// exactly the bytes that release wrote, and its reader as `_schema.json`.
// Compatibility/README.md says which release each folder stands for and how a
// shape that predates the tests was rebuilt from git.
//
// RECORDING, at release time, from the release's own commit:
//
//     scripts/record-compat-fixtures.sh 0.54.23
//
// which is `STOIC_RECORD_COMPATIBILITY=0.54.23 swift test --filter
// LodestarCoreTests.CompatibilityTests`. Each format's samples are written by
// the format's real writer (the outbox codec, the settings store, StateFiles)
// as <format>/0.54.23/<sample>.json beside the reader. A file already there
// with the same bytes passes; one with other bytes is refused, because a
// released promise is not rewritten. A run that wrote anything fails, so a
// recording is never mistaken for a pass, and CI never sets the variable. Then
// `git add Tests/LodestarCoreTests/Compatibility` with the tag. (The wiring
// into release.sh is the release's own business.)
//
// The records are made here, not by Stoic's `expectCompatibility`, because
// that is a Swift Testing call and the app's test runner is XCTest's; the
// rules (what is written, what is refused, that the run fails) are the same,
// and the checking is Stoic's own (`CompatibilityCheck`).
final class CompatibilityTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Compatibility").path

    // MARK: - The formats

    private struct Format<Value: Sendable> {
        var name: String
        var schema: Schema<Value>
        /// Today's values: written by the real writer, and what the older readers are offered.
        var samples: [(name: String, value: Value)]
        /// The bytes the real writer writes for a value.
        var write: (Value) -> [UInt8]?
        /// What a recording keeps as `_schema.json`: this build's reader as JSON Schema.
        var reader: JSONValue
        var reading: (@Sendable ([UInt8]) -> Decoded<Value>)?
        var verify: (@Sendable (CompatibilityFixture, Value) -> [String])?
        var olderReadersMayRefuse: [String: String] = [:]
        /// How many of the schema's own generated documents are offered to the older readers as well.
        var generated = 50
        /// Whether a warning on reading a released payload fails too: for a format whose
        /// promise is that an old file loads clean, not merely that it loads.
        var warningsFail = false
        /// Codes of the older readers' refusals that are not breaks: the reader keeps what it knows.
        var tolerated: Set<String> = []
    }

    private func expect<Value: Sendable>(_ format: Format<Value>, file: StaticString = #filePath, line: UInt = #line) {
        if let release = ProcessInfo.processInfo.environment["STOIC_RECORD_COMPATIBILITY"], !release.isEmpty {
            record(format, release: release, file: file, line: line)
            return
        }
        var check = CompatibilityCheck(format.schema, options: .strict)
        check.reading = format.reading
        check.samples = format.samples.map { ($0.name, $0.value) }
        check.verify = format.verify
        check.generated = format.generated
        for (text, why) in format.olderReadersMayRefuse {
            guard let release = ReleaseVersion(text) else { return XCTFail("\(text) is not a release", file: file, line: line) }
            check.olderReadersMayRefuse[release] = why
        }
        let set: CompatibilitySet
        do {
            set = try loadCompatibilitySet(format: format.name, from: Self.root)
        } catch {
            return XCTFail("\(error)", file: file, line: line)
        }
        let report = check.report(set)
        // A note on the fixtures themselves (a release with no reader kept) is not a break.
        let broken = (report.failures.filter { !($0.direction == .olderReader && format.tolerated.contains($0.code)) })
            + (format.warningsFail ? report.warnings.filter { $0.direction == .olderWriter } : [])
        for finding in broken {
            XCTFail("\"\(format.name)\": \(finding)", file: file, line: line)
        }
        XCTAssertGreaterThan(report.read, 0, "\"\(format.name)\": no released payload was read", file: file, line: line)
        XCTAssertGreaterThan(report.offered, 0, "\"\(format.name)\": no document of today's was offered to an older reader",
                             file: file, line: line)
    }

    /// The recording run: writes what is not there, refuses what differs, and
    /// fails when it wrote anything.
    private func record<Value: Sendable>(_ format: Format<Value>, release text: String, file: StaticString, line: UInt) {
        guard let release = ReleaseVersion(text) else {
            return XCTFail("STOIC_RECORD_COMPATIBILITY=\(text) is not a release version", file: file, line: line)
        }
        let folder = URL(fileURLWithPath: Self.root).appendingPathComponent(format.name)
            .appendingPathComponent(release.description)
        var files: [(String, [UInt8])] = []
        for sample in format.samples {
            guard let bytes = format.write(sample.value) else {
                return XCTFail("\"\(format.name)\": the writer could not write sample \"\(sample.name)\"", file: file, line: line)
            }
            files.append(("\(sample.name).json", bytes))
        }
        files.append(("_schema.json", format.reader.encoded(style: .pretty(indent: 2)) + [0x0A]))
        var written = 0
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, bytes) in files {
                let url = folder.appendingPathComponent(name)
                if let existing = try? Data(contentsOf: url) {
                    if Array(existing) != bytes {
                        XCTFail("\"\(format.name)\": release \(release) is already recorded with other bytes in \(name); "
                                + "a released promise is not rewritten", file: file, line: line)
                    }
                    continue
                }
                try Data(bytes).write(to: url)
                written += 1
            }
        } catch {
            return XCTFail("recording \"\(format.name)\" \(release) failed: \(error)", file: file, line: line)
        }
        if written > 0 {
            XCTFail("recorded \(written) file(s) for \"\(format.name)\" \(release): commit \(folder.path)", file: file, line: line)
        }
    }

    // MARK: - The feedback entry

    /// Today's notes. Their `version` is this build's, which is what a note carries.
    private static let notes: [(name: String, value: FeedbackEntry)] = [
        ("typical", FeedbackEntry(Feedback(message: "The strip is quicker than I expected.", replyTo: "reader@example.com",
                                            version: Lodestar.version, macos: "27.0.0"))),
        ("with-report", FeedbackEntry(Feedback(message: "Dictation stopped after a minute.", replyTo: "",
                                                version: Lodestar.version, macos: "27.0.0",
                                                diagnostics: "12:00:01.000 INFO boot\n12:00:02.500 ERR  speech: the recognizer stopped\n"))),
        ("no-reply", FeedbackEntry(Feedback(message: "One line, no address.", version: Lodestar.version, macos: "27.0.1"))),
        ("unicode", FeedbackEntry(Feedback(message: "Café ☕ and “quotes”,\nthen a second line with a tab\there.",
                                            replyTo: "réponse@example.com", version: Lodestar.version, macos: "27.0.0"))),
    ]

    /// The entry's decoder as JSON Schema: a `schema` of 1 or more and a note
    /// with its four strings, the report optional, and keys it does not know
    /// left alone (the codec says a later format may only add fields).
    private static let entryReader: JSONValue = parse("""
        {"$schema": "http://json-schema.org/draft-07/schema#", "type": "object", "required": ["feedback", "schema"],
         "properties": {"schema": {"type": "integer", "minimum": 1},
          "feedback": {"type": "object", "required": ["macos", "message", "replyTo", "version"],
           "properties": {"diagnostics": {"type": "string"}, "macos": {"type": "string"}, "message": {"type": "string"},
                          "replyTo": {"type": "string"}, "version": {"type": "string"}}}}}
        """)

    func testTheFeedbackEntryStillReadsWhatEveryReleaseWrote() {
        expect(Format(
            name: "feedback-entry",
            schema: .codable(FeedbackEntry.self, examples: Self.notes.map(\.value)),
            samples: Self.notes,
            write: { try? FeedbackEntry.codec.encode($0) },
            reader: Self.entryReader,
            reading: nil,
            // The outbox does not read an entry with the schema's decoder: it reads it with the codec's.
            verify: { fixture, _ in
                do {
                    let entry = try FeedbackEntry.codec.decode(fixture.bytes)
                    return entry.schema >= FeedbackEntry.schema ? [] : ["the codec read schema \(entry.schema)"]
                } catch {
                    return ["the outbox's codec cannot read it, so the outbox would discard this note: \(error)"]
                }
            }))
    }

    /// The release the updater rolls back to opens an outbox this build wrote.
    func testTheReleaseBeforeReadsTheNotesThisBuildQueues() throws {
        for (name, entry) in Self.notes {
            let written = try FeedbackEntry.codec.encode(entry)
            let read = try Released_0_54_22.FeedbackEntry.decode(written)
            XCTAssertEqual(read.schema, entry.schema, name)
            XCTAssertEqual(read.feedback.message, entry.feedback.message, name)
            XCTAssertEqual(read.feedback.replyTo, entry.feedback.replyTo, name)
            XCTAssertEqual(read.feedback.version, entry.feedback.version, name)
            XCTAssertEqual(read.feedback.macos, entry.feedback.macos, name)
            XCTAssertEqual(read.feedback.diagnostics, entry.feedback.diagnostics, name)
        }
    }

    /// The promise in the codec's own words: a later format may only add
    /// fields, and this build reads it; a format older than the first is not a note.
    func testALaterEntryFormatIsReadAndAnEarlierOneIsNot() throws {
        let later = Array(#"{"feedback":{"macos":"27.0.0","message":"hi","newer":[1,2],"replyTo":"","version":"9.9.9"},"future":true,"schema":2}"#.utf8)
        let read = try FeedbackEntry.codec.decode(later)
        XCTAssertEqual(read.schema, 2)
        XCTAssertEqual(read.feedback.message, "hi")
        let earlier = Array(#"{"feedback":{"macos":"27.0.0","message":"hi","replyTo":"","version":"0.1.0"},"schema":0}"#.utf8)
        XCTAssertThrowsError(try FeedbackEntry.codec.decode(earlier))
    }

    /// A deterministic writer writes the very bytes the release wrote from the
    /// same values (design/32: that is the reverse direction for a record with
    /// no reader to offer documents to).
    func testTodaysWriterWritesTheBytesReleasesWroteForTheSameNote() throws {
        let folder = URL(fileURLWithPath: Self.root).appendingPathComponent("feedback-entry/0.50.0")
        for name in ["typical", "with-report", "no-reply", "unicode"] {
            let bytes = Array(try Data(contentsOf: folder.appendingPathComponent("\(name).json")))
            let entry = try FeedbackEntry.codec.decode(bytes)
            XCTAssertEqual(try FeedbackEntry.codec.encode(entry), bytes,
                           "release 0.50.0's sample \"\(name)\" is not what this build writes for the same note")
        }
    }

    // MARK: - The config

    private static let configSamples: [(name: String, value: ConfigFile)] = {
        var tuned = ConfigFile()
        tuned.lode.tap = false
        tuned.lode.trigger = .leftCommand
        tuned.app.channel = .preview
        tuned.app.autoUpdate = false
        tuned.app.units = "metric"
        tuned.gestures["scroll"] = false
        tuned.web.fallback = "brave:Work"
        tuned.web.routes = ["example.com": "brave:Work"]
        tuned.web.links = ["docs": ConfigFile.Web.Link(profile: nil, url: "example.com/docs")]
        tuned.scroll.speed = 2200
        tuned.scroll.step = 80
        tuned.select.copyOnComplete = true
        tuned.clipboard.maxSizeMB = 200
        tuned.draft.editingStyle = .vim
        tuned.draft.words = ["Lodestar": true]
        tuned.appearance.eyeComfort = false
        tuned.mice.reversedWheels = ["1133:49271": "Desk Mouse"]
        tuned.keys = ["10": "§"]
        return [("defaults", ConfigFile()), ("tuned", tuned)]
    }()

    /// The bytes the settings store writes for a value: the real writer, into a file of its own.
    private static func configBytes(_ value: ConfigFile) -> [UInt8]? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("compat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("lodestar.json")
            // A first launch leaves the header and the defaults; a change is written over it.
            try ConfigStore.materialize(at: url)
            if value != ConfigFile() {
                _ = try ConfigStore.store(at: url).blockingUpdate { $0 = value }
            }
            return Array(try Data(contentsOf: url))
        } catch {
            return nil
        }
    }

    func testTheConfigStillReadsWhatEveryReleaseWrote() {
        expect(Format(
            name: "config",
            schema: ConfigFile.schema,
            samples: Self.configSamples,
            write: Self.configBytes,
            reader: ConfigFile.jsonSchema(),
            // As the store reads a file: its lenient options, its header set aside.
            reading: { bytes in
                ConfigStore.Store.read(bytes, schema: ConfigFile.schema, format: .handEdited, options: ConfigStore.options())
            },
            verify: { fixture, file in
                // What a key meant must not move: the keys every release wrote the same way.
                var problems: [String] = []
                if fixture.name == "defaults", file != ConfigFile() {
                    problems.append("a file with only its header reads as something other than the defaults")
                }
                if fixture.name == "tuned", file.scroll.speed != 2200 || file.scroll.step != 80 {
                    problems.append("scroll.speed and scroll.step, written as 2200 and 80, read as \(file.scroll.speed) and \(file.scroll.step)")
                }
                return problems
            },
            // A release that wrote a key this build has since retired is read by the
            // schema's `retired` list and its renames, and none of them may be an error.
            olderReadersMayRefuse: [:],
            // The graph is a free-form leaf (`.json`), so the generator draws any JSON
            // for it, and a document with a number for the graph is not a file anyone
            // could write; the samples above are the files that can be.
            generated: 0,
            // The schema's promise, in its own words, is that a file written before a
            // retirement or a rename "keeps loading clean": an unknown key reported on a
            // released file is a break, though the file still loads.
            warningsFail: true,
            // A key this build has that an older one does not is how every setting arrives, and
            // the older store reads such a file with an unknown-key warning and everything it
            // knows (its exported schema closes the object, which is stricter than it behaves).
            // A key it knows that now reads differently (a type, a range, a spelling, a missing
            // required one) is a break.
            tolerated: ["additionalProperties"]))
    }

    /// The old spellings still mean what they meant: the same switch under its
    /// new word, not a key that is merely tolerated.
    func testOlderSpellingsStillMeanWhatTheyMeant() throws {
        func read(_ release: String, _ name: String) throws -> ConfigFile {
            let url = URL(fileURLWithPath: Self.root).appendingPathComponent("config/\(release)/\(name).json")
            let decoded = ConfigStore.Store.read(Array(try Data(contentsOf: url)), schema: ConfigFile.schema,
                                                 format: .handEdited, options: ConfigStore.options())
            return try XCTUnwrap(decoded.value, "release \(release)'s \(name): \(decoded.errors)")
        }
        XCTAssertEqual(try read("0.9.10", "hyper-spelling").lode.trigger, .rightCommand, "hyper's raw-hyper folds into the default")
        XCTAssertEqual(try read("0.9.10", "hyper-spelling").scroll.speed, 2000)
        let old = try read("0.21.0", "registry-and-old-gestures")
        XCTAssertFalse(old.gestures["launcher"], "gestures.searcher is the launcher's switch")
        XCTAssertEqual(old.web.fallback, "brave:Work", "a profile named through the retired registry reads as its reference")
        XCTAssertEqual(old.web.routes["example.com"], "brave:Work")
        XCTAssertEqual(old.web.links["tracker"]?.profile, "brave:Work")
        let switches = try read("0.40.0", "old-switches")
        XCTAssertFalse(switches.gestures["commands"], "gestures.menu-search is the commands bar's switch")
        XCTAssertFalse(switches.observations.logbook, "observations.enabled is the logbook's switch")
    }

    // MARK: - The state

    private static let stateSamples: [(name: String, value: PersistedState)] = {
        let session = "1730000000.0"
        var state = PersistedState()
        state.version = Lodestar.stateVersion
        state.breaths = [BreathRecord(path: "gb", orientation: "horizontal", members: [
            BreathMember(windowID: 4101, bundleID: "com.example.One", appName: "One", title: "one",
                         frame: CGRect(x: 0, y: 25, width: 960, height: 1055), display: "DISPLAY-A"),
            BreathMember(windowID: 4102, bundleID: nil, appName: "Two", title: "two",
                         frame: CGRect(x: 960, y: 25, width: 960, height: 1055)),
        ], orientations: ["DISPLAY-A": "horizontal"])]
        state.latestBreath = "gb"
        state.parked = [7001: CGRect(x: 1900, y: 1060, width: 1920, height: 1080)]
        state.parkedSession = session
        state.usage = ["One": UsageRecord(count: 42, last: Date(timeIntervalSinceReferenceDate: 783_000_000.5))]
        state.walkStep = 3
        state.walkCompletedVersion = Lodestar.version
        state.walkDoor = "speak"
        state.editorConsentAt = Date(timeIntervalSinceReferenceDate: 783_100_000.25)
        state.meetingSpent = ["standup@2026-04-01T09:00"]
        state.coachStandingSince = ["breath:gb": Date(timeIntervalSinceReferenceDate: 783_100_000.25)]
        state.curriculum = ["breaths": Curriculum.Record(offers: 2, lastOfferedAt: Date(timeIntervalSinceReferenceDate: 783_100_000.25),
                                                         completedAt: nil)]
        state.editingStyleSettled = true
        return [("typical", state), ("empty", PersistedState())]
    }()

    /// What PersistedState's decoder asks of a file: `breaths` and `parked` (a
    /// non-optional Codable property has no default when its key is absent),
    /// a number for each date, and nothing else it does not name.
    private static let stateReader: JSONValue = parse("""
        {"$schema": "http://json-schema.org/draft-07/schema#", "type": "object", "required": ["breaths", "parked"],
         "properties": {"version": {"type": "integer"}, "breaths": {"type": "array"}, "latestBreath": {"type": "string"},
          "parked": {"type": "array"}, "parkedSession": {"type": "string"}, "usage": {"type": "object"},
          "walkStep": {"type": "integer"}, "walkCompletedVersion": {"type": "string"}, "walkDoor": {"type": "string"},
          "editorConsentAt": {"type": "number"}, "meetingSpent": {"type": "array", "items": {"type": "string"}},
          "coachStandingSince": {"type": "object"}, "curriculum": {"type": "object"}, "editingStyleSettled": {"type": "boolean"}}}
        """)

    func testTheStateStillReadsWhatEveryReleaseWrote() {
        expect(Format(
            name: "state",
            schema: .codable(PersistedState.self, examples: Self.stateSamples.map(\.value)),
            samples: Self.stateSamples,
            write: { StateFiles.encode($0) },
            reader: Self.stateReader,
            reading: nil,
            // The store reads a file through StateMigrations first, then JSONDecoder.
            verify: { fixture, state in
                guard StateFiles.decode(fixture.bytes) != nil else { return ["StateFiles.decode cannot read it"] }
                guard state.breaths.allSatisfy({ !$0.members.isEmpty }) else { return ["a breath lost its members"] }
                return []
            }))
    }

    func testTheReleaseBeforeReadsTheStateThisBuildWrites() throws {
        for (name, state) in Self.stateSamples {
            let written = try XCTUnwrap(StateFiles.encode(state), name)
            let read = try XCTUnwrap(Released_0_54_22.PersistedState.decode(written), "\(name): 0.54.22 cannot read it")
            XCTAssertEqual(read.breaths.count, state.breaths.count, name)
            XCTAssertEqual(read.latestBreath, state.latestBreath, name)
            XCTAssertEqual(read.parked.count, state.parked.count, name)
            XCTAssertEqual(read.walkDoor, state.walkDoor, name)
            XCTAssertEqual(read.editingStyleSettled, state.editingStyleSettled, name)
            XCTAssertEqual(read.coachStandingSince, state.coachStandingSince, name)
        }
    }

    /// A release whose shape is today's writes the very bytes it read.
    func testTheStateRewritesAsTheReleaseWroteIt() throws {
        for (release, name) in [("0.54.5", "typical"), ("0.54.11", "typical"), ("0.54.11", "empty")] {
            let url = URL(fileURLWithPath: Self.root).appendingPathComponent("state/\(release)/\(name).json")
            let bytes = Array(try Data(contentsOf: url))
            let state = try XCTUnwrap(StateFiles.decode(bytes), "release \(release)'s \(name)")
            XCTAssertEqual(StateFiles.encode(state), bytes, "release \(release)'s \(name) is not what this build writes back")
        }
    }

    /// A file from before the chain had a step, with no version, is lifted to
    /// the current one and still reads.
    func testAStateWithNoVersionIsLiftedAndRead() throws {
        let bytes = Array(#"{"breaths":[],"parked":[]}"#.utf8)
        let lifted = StateMigrations.lift(Data(bytes))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: lifted) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, Lodestar.stateVersion)
        XCTAssertNotNil(StateFiles.decode(bytes))
    }

    // MARK: - Helpers

    private static func parse(_ text: String) -> JSONValue {
        do {
            return try JSONParser().parseValue(Array(text.utf8))
        } catch {
            preconditionFailure("the reader in this file is not JSON: \(error)")
        }
    }
}
