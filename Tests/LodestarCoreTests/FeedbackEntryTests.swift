import XCTest
@testable import LodestarCore

/// A note as the outbox keeps it: the bytes on disk are the note and a
/// version, and read back as exactly what was written.
final class FeedbackEntryTests: XCTestCase {
    private func roundTrip(_ feedback: Feedback) throws -> FeedbackEntry {
        let codec = FeedbackEntry.codec
        return try codec.decode(try codec.encode(FeedbackEntry(feedback)))
    }

    func testANoteReadsBackAsWrittenWithEveryField() throws {
        let note = Feedback(message: "Line one\nLine \"two\" — ünïcode 🧭", replyTo: "me@example.com",
                            version: "0.49.1", macos: "27.0.0", diagnostics: "log\nlines")
        XCTAssertEqual(try roundTrip(note).feedback, note)
    }

    func testAnAbsentReportStaysAbsent() throws {
        let read = try roundTrip(Feedback(message: "hi", version: "1", macos: "2")).feedback
        XCTAssertNil(read.diagnostics)
        XCTAssertEqual(read.replyTo, "")
    }

    func testWhatIsSentAfterReadingIsWhatWouldHaveBeenSent() throws {
        // The queue sends the entry's note, possibly days and a relaunch
        // later: the body must not depend on the trip through the file.
        let note = Feedback(message: "  padded \n", replyTo: " me@example.com ", version: "0.49.1", macos: "27.0.0",
                            diagnostics: "OLDEST\n" + String(repeating: "x", count: Feedback.diagnosticsLimit) + "\nNEWEST")
        XCTAssertEqual(try roundTrip(note).feedback.payload, note.payload)
    }

    func testTheBytesAreReadableJSONWithTheVersionOfTheFormat() throws {
        let bytes = try FeedbackEntry.codec.encode(FeedbackEntry(Feedback(message: "hi", version: "1", macos: "2")))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any])
        XCTAssertEqual(object["schema"] as? Int, 1)
        XCTAssertEqual((object["feedback"] as? [String: Any])?["message"] as? String, "hi")
    }

    func testALaterFormatThatOnlyAddedFieldsStillReads() throws {
        let later = #"{"schema":2,"queuedAt":"2027-01-01","feedback":{"message":"hi","replyTo":"","version":"1","macos":"2","tags":[]}}"#
        let read = try FeedbackEntry.codec.decode(Array(later.utf8))
        XCTAssertEqual(read.schema, 2)
        XCTAssertEqual(read.feedback.message, "hi")
    }

    func testBytesThatAreNotANoteDoNotRead() {
        for bad in ["", "{", "[]", #"{"schema":1}"#, #"{"schema":0,"feedback":{"message":"hi","replyTo":"","version":"1","macos":"2"}}"#,
                    #"{"schema":1,"feedback":{"replyTo":""}}"#] {
            XCTAssertThrowsError(try FeedbackEntry.codec.decode(Array(bad.utf8)), bad)
        }
    }
}
