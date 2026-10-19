import XCTest
@testable import LodestarCore

/// Files as a kind of clip: how a copy is told to be files, how an index that
/// holds a kind this build does not know still opens, and what a file card
/// says about its files.
final class ClipboardFileTests: XCTestCase {
    private let file = [Clipboard.fileURLType, "public.utf8-plain-text"]

    private func fact(_ name: String, folder: String = "Documents", kind: String = "PDF document",
                      bytes: Int? = 1_000_000, items: Int? = nil, detail: String? = nil) -> Clipboard.FileFact {
        Clipboard.FileFact(name: name, folder: folder, kind: kind, type: "com.adobe.pdf",
                           bytes: bytes, items: items, detail: detail)
    }

    private func files(_ facts: [Clipboard.FileFact], count: Int? = nil) -> Clipboard.Clip {
        Clipboard.Clip(id: "f", kind: .file, created: Date(timeIntervalSince1970: 1_000_000),
                       sourceBundleID: "com.apple.finder", sourceAppName: "Finder",
                       preview: facts.map { "/Users/x/\($0.name)" }.joined(separator: "\n"), bytes: 100,
                       nativeTypes: file,
                       otherItemTypes: Array(repeating: file, count: max(0, (count ?? facts.count) - 1)),
                       fileFacts: facts)
    }

    // MARK: - What pastes as files

    func testACopyOfFilesPastesAsFilesWhateverKindItWasRecordedAs() {
        func clip(_ kind: Clipboard.Kind, _ native: [String], others: [[String]] = []) -> Clipboard.Clip {
            Clipboard.Clip(id: "p", kind: kind, created: Date(timeIntervalSince1970: 1_000_000),
                           sourceBundleID: nil, sourceAppName: nil, preview: "x", bytes: 1,
                           nativeTypes: native, otherItemTypes: others)
        }
        XCTAssertTrue(clip(.file, file).pastesAsFiles)
        XCTAssertTrue(clip(.text, file, others: [file]).pastesAsFiles, "a file copy from before files were a kind")
        XCTAssertFalse(clip(.text, ["public.html"]).pastesAsFiles)
        XCTAssertFalse(clip(.text, file, others: [["public.html"]]).pastesAsFiles, "files beside other things are as copied")
        XCTAssertFalse(clip(.image, ["public.png"]).pastesAsFiles)
        XCTAssertFalse(clip(.text, []).pastesAsFiles, "plain text carries no types at all")
    }

    // MARK: - An index with a kind this build does not know

    /// The test that must not regress: the index is one journal, and one
    /// clip that will not decode takes every other down with it.
    func testAnIndexWithAKindThisBuildDoesNotKnowStillDecodesEveryClip() throws {
        let json = """
        [{"id":"a","kind":"text","created":760000,"preview":"one","bytes":3,"nativeTypes":[]},
         {"id":"b","kind":"hologram","created":760001,"preview":"two","bytes":3,"nativeTypes":[]},
         {"id":"c","kind":"image","created":760002,"preview":"three","bytes":3,"nativeTypes":[]},
         {"id":"d","kind":"file","created":760003,"preview":"four","bytes":3,"nativeTypes":[]}]
        """
        let clips = try JSONDecoder().decode([Clipboard.Clip].self, from: Data(json.utf8))
        XCTAssertEqual(clips.map(\.id), ["a", "b", "c", "d"], "every clip, in order")
        XCTAssertEqual(clips.map(\.kind), [.text, .text, .image, .file], "the stranger reads as text")
        XCTAssertEqual(clips[1].preview, "two", "and keeps everything else it had")
    }

    /// The same through the snapshot the index folds to, where one bad
    /// entry would have discarded the whole snapshot.
    func testASnapshotWithAKindThisBuildDoesNotKnowKeepsEveryEntry() throws {
        let entries = ["a", "b", "c"].map { id in
            ClipEntry(clip: Clipboard.Clip(id: id, kind: id == "b" ? .file : .text, created: Date(timeIntervalSince1970: 1),
                                           sourceBundleID: nil, sourceAppName: nil, preview: id, bytes: 1),
                      storage: ClipboardSealed.newStorage(), blobKey: Data([1, 2, 3]))
        }
        let snapshot = try XCTUnwrap(ClipboardIndexState(entries: entries).snapshot())
        let written = String(decoding: snapshot, as: UTF8.self)
        XCTAssertTrue(written.contains(#""kind":"file""#))
        let foreign = written.replacingOccurrences(of: #""kind":"file""#, with: #""kind":"from-the-future""#)
        let state = try XCTUnwrap(ClipboardIndexState.decoding(snapshot: [UInt8](foreign.utf8)))
        XCTAssertEqual(state.entries.map(\.clip.id), ["a", "b", "c"])
        XCTAssertEqual(state.entries[1].clip.kind, .text)
    }

    func testTheKindsAreWrittenAsTheyAlwaysWereAndFileJoinsThem() throws {
        XCTAssertEqual([Clipboard.Kind.text, .image, .file].map(\.rawValue), ["text", "image", "file"])
        let written = String(decoding: try JSONEncoder().encode([Clipboard.Kind.file, .text, .image]), as: UTF8.self)
        XCTAssertEqual(written, #"["file","text","image"]"#)
        XCTAssertEqual(try JSONDecoder().decode([Clipboard.Kind].self, from: Data(written.utf8)), [.file, .text, .image])
    }

    // MARK: - A clip written before files had facts

    func testAClipWrittenBeforeFileFactsDecodesWithoutThemAndWritesNone() throws {
        let legacy = #"{"bytes":12,"created":760000,"id":"abc","kind":"text","nativeTypes":["public.file-url"],"preview":"/a/b"}"#
        let clip = try JSONDecoder().decode(Clipboard.Clip.self, from: Data(legacy.utf8))
        XCTAssertNil(clip.fileFacts)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(clip), as: UTF8.self).contains("fileFacts"),
                       "a clip with no facts writes no key for them")
    }

    func testFileFactsSurviveTheRoundTripAndAFactMayLackEverythingOptional() throws {
        let made = files([fact("Report.pdf", detail: "12 pages"), fact("Notes", kind: "Folder", bytes: nil, items: 4)])
        let back = try JSONDecoder().decode(Clipboard.Clip.self, from: JSONEncoder().encode(made))
        XCTAssertEqual(back, made)
        let bare = #"{"name":"a","folder":"b","kind":"c"}"#
        let decoded = try JSONDecoder().decode(Clipboard.FileFact.self, from: Data(bare.utf8))
        XCTAssertNil(decoded.bytes)
        XCTAssertNil(decoded.detail)
        XCTAssertNil(decoded.pictured)
    }

    // MARK: - What kind a copy is

    func testACopyIsFilesExactlyWhenEveryItemIsAFile() {
        XCTAssertEqual(Clipboard.kind(ofCopy: [file]), .file, "one file")
        XCTAssertEqual(Clipboard.kind(ofCopy: [file, file, file]), .file, "all files")
        XCTAssertEqual(Clipboard.kind(ofCopy: [file, ["public.utf8-plain-text"]]), .text, "a file and a string")
        XCTAssertEqual(Clipboard.kind(ofCopy: [["public.utf8-plain-text"], file]), .text, "the other way round")
        XCTAssertEqual(Clipboard.kind(ofCopy: [file, ["public.html"], file]), .text, "one stranger among files")
        XCTAssertEqual(Clipboard.kind(ofCopy: [["public.utf8-plain-text"]]), .text, "text")
        XCTAssertEqual(Clipboard.kind(ofCopy: [["public.html", "public.utf8-plain-text"]]), .text, "rich text")
    }

    func testNothingCopiedIsNotFiles() {
        XCTAssertEqual(Clipboard.kind(ofCopy: []), .text)
        XCTAssertEqual(Clipboard.kind(ofCopy: [[]]), .text, "an item with no types is not a file")
    }

    /// A picture stays a picture: a preview's or a browser's copy, and a
    /// file whose pixels ride beside it, are read, captioned and opened
    /// large, as they have always been.
    func testAPictureStaysAPictureEvenBesideAFileAddress() {
        XCTAssertEqual(Clipboard.kind(ofCopy: [["public.png", "public.tiff"]]), .image, "an image from a preview")
        XCTAssertEqual(Clipboard.kind(ofCopy: [["public.tiff"]]), .image)
        XCTAssertEqual(Clipboard.kind(ofCopy: [[Clipboard.fileURLType, "public.png"]]), .image,
                       "a file that also brought its pixels is the picture it always was")
        XCTAssertEqual(Clipboard.kind(ofCopy: [file, [Clipboard.fileURLType, "public.png"]]), .file,
                       "the first item decides, as the capture's image bytes always came from it")
    }

    // MARK: - The files a copy names

    func testAFileURLIsReadFromItsBoardForm() {
        XCTAssertEqual(Clipboard.fileURL(from: Data("file:///Users/x/My%20Report.pdf".utf8))?.path, "/Users/x/My Report.pdf")
        XCTAssertEqual(Clipboard.fileURL(from: Data("file:///Users/x/a.pdf\0".utf8))?.path, "/Users/x/a.pdf", "a terminator is not part of the name")
        XCTAssertEqual(Clipboard.fileURL(from: Data(" file:///a/b \n".utf8))?.path, "/a/b")
        XCTAssertNil(Clipboard.fileURL(from: Data("https://example.com/a.pdf".utf8)), "an address that is not a file")
        XCTAssertNil(Clipboard.fileURL(from: Data("/Users/x/a.pdf".utf8)), "a bare path is not a file URL")
        XCTAssertNil(Clipboard.fileURL(from: Data([0xff, 0xfe])), "bytes that are not text")
        XCTAssertNil(Clipboard.fileURL(from: Data()))
    }

    func testTheFilesOfACopyComeInCopyOrderAndAnItemWithNoneIsLeftOut() {
        func item(_ url: String?) -> ClipboardContent.Item {
            .init(plain: Data("ignored".utf8), natives: url.map { [(Clipboard.fileURLType, Data($0.utf8))] } ?? [("public.html", Data("<b>".utf8))])
        }
        let urls = Clipboard.fileURLs(in: [item("file:///a/one.pdf"), item(nil), item("file:///b/two.mov")])
        XCTAssertEqual(urls.map(\.lastPathComponent), ["one.pdf", "two.mov"])
        XCTAssertEqual(Clipboard.fileURLs(in: []), [])
    }

    func testAFileIsNamedAndItsFolderByNameNeverByPath() {
        let names = Clipboard.fileNames(of: URL(fileURLWithPath: "/Users/x/Documents/Report 2026.pdf"))
        XCTAssertEqual(names.name, "Report 2026.pdf")
        XCTAssertEqual(names.folder, "Documents")
        XCTAssertEqual(Clipboard.fileNames(of: URL(fileURLWithPath: "/top.txt")).folder, "/")
    }

    // MARK: - What the card says

    func testNamesAreAllListedUpToThreeThenTwoAndHowManyMore() {
        let names = ["Report.pdf", "Beach.jpg", "Demo.mov", "Notes.txt", "Data.zip"]
        func lines(_ total: Int, _ given: Int = 5) -> [String] {
            Clipboard.nameLines(names: Array(names.prefix(given)), total: total).map(\.text)
        }
        XCTAssertEqual(lines(1), ["Report.pdf"])
        XCTAssertEqual(lines(2), ["Report.pdf", "Beach.jpg"])
        XCTAssertEqual(lines(3), ["Report.pdf", "Beach.jpg", "Demo.mov"])
        XCTAssertEqual(lines(4), ["Report.pdf", "Beach.jpg", "and 2 more"])
        XCTAssertEqual(lines(7), ["Report.pdf", "Beach.jpg", "and 5 more"], "the mock's seven")
        XCTAssertEqual(lines(100, 5), ["Report.pdf", "Beach.jpg", "and 98 more"], "more files than facts kept")
        XCTAssertEqual(Clipboard.nameLines(names: names, total: 7).map(\.grey), [false, false, true], "only the count is grey")
        XCTAssertEqual(Clipboard.nameLines(names: names, total: 3).map(\.grey), [false, false, false])
        XCTAssertEqual(Clipboard.nameLines(names: [], total: 2).count, 0, "no names yet, no lines")
        XCTAssertEqual(Clipboard.nameLines(names: ["a"], total: 3).map(\.text), ["a"], "never more lines than names")
    }

    func testSizesAreSaidTheWayTheFinderSaysThem() {
        XCTAssertEqual(Clipboard.byteText(0), "0 bytes", "never Zero KB")
        XCTAssertEqual(Clipboard.byteText(38_000_000), "38 MB")
        XCTAssertEqual(Clipboard.byteText(212_000_000), "212 MB")
        XCTAssertEqual(Clipboard.sizeText(of: fact("a", bytes: 5_000_000)), "5 MB")
        XCTAssertEqual(Clipboard.sizeText(of: fact("d", kind: "Folder", bytes: nil, items: 12)), "12 items")
        XCTAssertEqual(Clipboard.sizeText(of: fact("d", kind: "Folder", bytes: nil, items: 1)), "1 item")
        XCTAssertNil(Clipboard.sizeText(of: fact("app", bytes: nil, items: nil)), "a package has no size said")
    }

    func testTheTotalIsTheSumOfTheStoredSizesAndNilWhenItWouldNotBeTrue() {
        let three = [fact("a", bytes: 1_000_000), fact("b", bytes: 2_000_000), fact("c", bytes: 5_000_000)]
        XCTAssertEqual(Clipboard.totalBytes(of: three, itemCount: 3), 8_000_000)
        XCTAssertNil(Clipboard.totalBytes(of: three, itemCount: 40), "a dozen facts of forty files is not their total")
        XCTAssertNil(Clipboard.totalBytes(of: three + [fact("d", kind: "Folder", bytes: nil, items: 2)], itemCount: 4),
                     "a folder has no size here, so there is no total to claim")
        XCTAssertNil(Clipboard.totalBytes(of: [], itemCount: 0))
    }

    func testTheFootSaysSizeAndAgeForSeveralAndKindSizeAndAgeForOne() {
        let several = files([fact("a", bytes: 30_000_000), fact("b", bytes: 8_000_000)])
        XCTAssertEqual(Clipboard.fileCaption(of: several, age: "2m ago"), "38 MB · 2m ago")
        let one = files([fact("a.pdf", bytes: 3_000_000)])
        XCTAssertEqual(Clipboard.fileCaption(of: one, age: "2m ago"), "PDF document · 3 MB · 2m ago")
        XCTAssertEqual(Clipboard.fileCaption(of: one, age: "2m ago", withKind: false), "3 MB · 2m ago", "the kind gives way first")
        let folder = files([fact("Notes", kind: "Folder", bytes: nil, items: 4)])
        XCTAssertEqual(Clipboard.fileCaption(of: folder, age: "1h ago"), "Folder · 4 items · 1h ago")
        let unknown = files([fact("a", bytes: 1)], count: 40)
        XCTAssertEqual(Clipboard.fileCaption(of: unknown, age: "9m ago"), "9m ago", "no total, so the age alone")
    }

    func testTheFootBeforeTheFilesAreReadIsTheAgeAlone() {
        var clip = files([fact("a")])
        clip.fileFacts = nil
        XCTAssertEqual(Clipboard.fileCaption(of: clip, age: "just now"), "just now")
        clip.fileFacts = []
        XCTAssertEqual(Clipboard.fileCaption(of: clip, age: "just now"), "just now")
    }

    func testACardWhoseFilesAreAllGoneSaysMissingInPlaceOfItsFoot() {
        let clip = files([fact("a"), fact("b")])
        XCTAssertEqual(Clipboard.fileCaption(of: clip, age: "2m ago", missing: true), "Missing")
        XCTAssertTrue(Clipboard.allMissing([false, false]))
        XCTAssertFalse(Clipboard.allMissing([false, true]), "a group with one file left is not missing")
        XCTAssertFalse(Clipboard.allMissing([true]))
        XCTAssertFalse(Clipboard.allMissing([]), "nothing known is not missing")
        XCTAssertFalse(Clipboard.allMissing(nil), "not yet asked is not missing")
    }

    func testTheLineUnderAFilesNameIsPagesPixelsOrMinutes() {
        XCTAssertEqual(Clipboard.pagesDetail(12), "12 pages")
        XCTAssertEqual(Clipboard.pagesDetail(1), "1 page")
        XCTAssertNil(Clipboard.pagesDetail(0))
        XCTAssertEqual(Clipboard.dimensionsDetail(width: 4032, height: 3024), "4032 × 3024")
        XCTAssertNil(Clipboard.dimensionsDetail(width: 0, height: 10))
        XCTAssertEqual(Clipboard.durationDetail(42), "0:42")
        XCTAssertEqual(Clipboard.durationDetail(59.9), "0:59", "not yet a minute")
        XCTAssertEqual(Clipboard.durationDetail(600), "10:00")
        XCTAssertEqual(Clipboard.durationDetail(3723), "1:02:03")
        XCTAssertNil(Clipboard.durationDetail(.nan))
        XCTAssertNil(Clipboard.durationDetail(-1))
        XCTAssertNil(Clipboard.durationDetail(.infinity), "a stream with no end has no length to say")
    }

    func testACardHasNamesBeforeItsFilesAreReadAndTheFactsOnceTheyAre() {
        var clip = files([fact("Report.pdf"), fact("Beach.jpg")])
        XCTAssertEqual(Clipboard.namesOnCard(of: clip), ["Report.pdf", "Beach.jpg"])
        clip.fileFacts = nil
        clip.preview = "/Users/x/Documents/Report.pdf\nBeach.jpg\n"
        XCTAssertEqual(Clipboard.namesOnCard(of: clip), ["Report.pdf", "Beach.jpg"], "the last part of each path, or a bare name")
        clip.preview = ""
        XCTAssertEqual(Clipboard.namesOnCard(of: clip), [])
    }

    func testVoiceOverIsToldTheFiles() {
        let many = files([fact("Report.pdf"), fact("Beach.jpg"), fact("Demo.mov"), fact("Notes.txt")], count: 7)
        XCTAssertEqual(Clipboard.fileSpeech(of: many), "7 files: Report.pdf, Beach.jpg, and 5 more")
        XCTAssertEqual(Clipboard.fileSpeech(of: files([fact("A.pdf"), fact("B.pdf")])), "2 files: A.pdf, B.pdf")
        XCTAssertEqual(Clipboard.fileSpeech(of: files([fact("A.pdf", detail: "12 pages")])),
                       "File A.pdf · in Documents · PDF document · 12 pages")
        XCTAssertTrue(Clipboard.fileSpeech(of: many, missing: true).hasSuffix(", missing"))
        var unread = files([fact("A.pdf")])
        unread.fileFacts = nil
        XCTAssertEqual(Clipboard.fileSpeech(of: unread), "File A.pdf", "named from the path until the facts arrive")
        unread.preview = ""
        XCTAssertEqual(Clipboard.fileSpeech(of: unread), "File copied")
    }

    // MARK: - The rest of the history

    func testAFileClipIsNotTextToEditOrToCount() {
        var clip = files([fact("a.pdf")])
        clip.lines = 400
        clip.characters = 90_000
        XCTAssertFalse(clip.isEditable, "a file is not text to open in the draft")
        XCTAssertNil(Clipboard.lengthBadge(for: clip), "and has no length badge, whatever was counted")
        XCTAssertNil(clip.color)
        XCTAssertNil(clip.time)
        XCTAssertNil(clip.masked)
        XCTAssertNil(Clipboard.reading(of: clip, units: .metric))
    }

    func testRecopyingTheSameFilesKeepsTheCardAndItsFactsUntilNewOnesLand() {
        let known = files([fact("a.pdf", bytes: 100)])
        var arrival = files([fact("a.pdf", bytes: 100)])
        arrival.fileFacts = nil
        XCTAssertEqual(Clipboard.merging([known], with: arrival).first?.fileFacts, known.fileFacts)
        arrival.fileFacts = [fact("a.pdf", bytes: 250)]
        XCTAssertEqual(Clipboard.merging([known], with: arrival).first?.fileFacts?.first?.bytes, 250, "what is read again wins")
    }

    func testAFileCopyRecordedAsTextBeforeBecomesAFileClipWhenCopiedAgain() {
        let old = Clipboard.Clip(id: "f", kind: .text, created: Date(timeIntervalSince1970: 1), sourceBundleID: nil,
                                 sourceAppName: nil, preview: "/Users/x/a.pdf", bytes: 10, nativeTypes: file,
                                 pinnedSlot: 3, keptName: "Contract")
        let again = files([fact("a.pdf")])
        let merged = Clipboard.merging([old], with: again).first
        XCTAssertEqual(merged?.kind, .file)
        XCTAssertEqual(merged?.pinnedSlot, 3, "and keeps the place it was kept in")
        XCTAssertEqual(merged?.keptName, "Contract")
    }

    func testAKeepsakeOfFilesIsOfferedTheFirstFilesName() {
        XCTAssertEqual(Clipboard.offeredName(for: files([fact("Report.pdf"), fact("Beach.jpg")])), "Report.pdf")
        var unread = files([fact("a")])
        unread.fileFacts = nil
        XCTAssertEqual(Clipboard.offeredName(for: unread), "a", "the last part of the path before the facts arrive")
        var nameless = unread
        nameless.preview = ""
        XCTAssertEqual(Clipboard.offeredName(for: nameless), "Files")
    }

    func testFilesAreFoundByTheirNamesWithoutAnyRicherSearch() {
        let clip = files([fact("Quarterly Report.pdf")])
        XCTAssertNotNil(Clipboard.relevance(of: clip, to: "quarterly"), "the names are in what is searched")
        XCTAssertNil(Clipboard.relevance(of: clip, to: "zebra"))
    }
}
