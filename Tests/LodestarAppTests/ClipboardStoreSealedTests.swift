import AppKit
import StoicSealed
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The sealed history as the store lives it: opened off the main thread with
/// copies queued behind it, paused when the key cannot be asked for, moved
/// aside when the key is gone, and every deletion made real by the fold that
/// follows it.
final class ClipboardStoreSealedTests: XCTestCase {
    private var directory: URL!
    private var root: URL { directory.appendingPathComponent("clipboard", isDirectory: true) }
    private var custody: InMemoryKeyCustody!
    private var vault: Vault!
    private var savedDeletionDelay: TimeInterval = 0
    private var savedFoldDelay: TimeInterval = 0

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lodestar-sealedstore-\(UUID().uuidString)", isDirectory: true)
        custody = InMemoryKeyCustody()
        vault = SealedFixture.vault(root, custody: custody)
        savedDeletionDelay = ClipboardStore.deletionDelay
        savedFoldDelay = ClipboardStore.foldDelay
        ClipboardStore.deletionDelay = 0.05
        ClipboardStore.foldDelay = 0.05
    }

    override func tearDown() {
        ClipboardStore.deletionDelay = savedDeletionDelay
        ClipboardStore.foldDelay = savedFoldDelay
        try? FileManager.default.removeItem(at: directory)
    }

    private func wait(_ what: String, timeout: TimeInterval = 10, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), what)
    }

    @discardableResult
    private func copy(_ store: ClipboardStore, _ text: String, rich: String? = nil) -> String {
        let data = Data(text.utf8)
        let id = ClipboardStore.identity(for: data)
        store.record(id: id, kind: .text,
                     items: [.init(plain: data, natives: rich.map { [("public.html", Data($0.utf8))] } ?? [])],
                     imageData: nil, preview: text, sourceBundleID: nil, sourceAppName: nil)
        return id
    }

    private func older(_ count: Int) throws -> [Clipboard.Clip] {
        var clips: [Clipboard.Clip] = []
        for n in 0..<count {
            let text = "\(ClipboardSynth.marker) old \(n)"
            let clip = Clipboard.Clip(id: "old\(n)", kind: .text, created: Date(timeIntervalSince1970: 1_700_000_000 - Double(n)),
                                      sourceBundleID: nil, sourceAppName: nil, preview: text, bytes: text.utf8.count)
            try ClipboardV1.write(clip, items: [.init(plain: Data(text.utf8), natives: [])], to: root)
            clips.append(clip)
        }
        try ClipboardV1.writeIndex(clips, to: root)
        return clips
    }

    // MARK: Opening off the main thread

    func testTheHistoryOpensOffTheMainThreadAndACopyMadeMeanwhileIsKeptInOrder() throws {
        let clips = try older(200)
        let store = ClipboardStore(root: root, vault: vault)
        // Nothing has been published: init returned before the journal was read, or even the migration begun.
        XCTAssertEqual(store.phase, .opening)
        XCTAssertEqual(store.clips.count, 0, "an honest empty strip")
        XCTAssertEqual(store.statusLine, "⌂ clipboard history is opening — a moment")
        let first = copy(store, "first copy while opening")
        let second = copy(store, "second copy while opening")
        XCTAssertEqual(store.clips.count, 0, "queued, not applied, not written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: SealedFixture.v2(root).path), "nothing is written before the index is open")

        XCTAssertEqual(store.waitUntilOpen(), .ready)
        XCTAssertNil(store.statusLine)
        XCTAssertEqual(store.clips.count, 202)
        XCTAssertEqual(store.clips.prefix(2).map(\.id), [second, first], "applied after the load, in order, on top of the history")
        XCTAssertEqual(Set(store.clips.dropFirst(2).map(\.id)), Set(clips.map(\.id)))
        XCTAssertEqual(store.plainText(first), "first copy while opening")
        store.close()

        let again = SealedFixture.clipboardStore(root)
        XCTAssertEqual(again.clips.count, 202, "and written: they survive a launch")
        XCTAssertEqual(again.plainText(second), "second copy while opening")
        again.close()
    }

    func testTheOpeningHappensOnABackgroundQueue() throws {
        _ = try older(5)
        var thread: Thread?
        let store = ClipboardStore(root: root, vault: vault)
        // The load is not on this thread: it is done by the io queue, and published here a turn later.
        XCTAssertEqual(store.phase, .opening)
        store.onThumbnail = { thread = Thread.current }
        store.waitUntilOpen()
        XCTAssertTrue(thread?.isMainThread == true, "published on the main thread")
        XCTAssertEqual(store.clips.count, 5)
        store.close()
    }

    // MARK: Key states

    func testAHistoryWhoseKeychainDidNotOpenIsPausedAndNothingIsReadWrittenOrDeleted() throws {
        let first = SealedFixture.clipboardStore(root)
        copy(first, "sealed before")
        first.close()
        _ = try older(3)
        let before = ClipboardSynth.everything(under: root)
        let ringBefore = custody.contents(of: "lodestar.ring.clipboard")

        let locked = LockedCustody(copying: custody)
        let lockedVault = SealedFixture.vault(root, custody: locked)
        let store = ClipboardStore(root: root, vault: lockedVault)
        store.waitUntilOpen()
        XCTAssertTrue(store.isPaused)
        XCTAssertEqual(store.clips.count, 0)
        XCTAssertEqual(store.statusLine, "⌂ clipboard history is unavailable — the keychain didn't open\ntry again after unlocking, or at the next launch")
        // No capture.
        copy(store, "copied while paused")
        store.delete("nothing")
        XCTAssertFalse(store.clearAll(), "no clear")
        store.saveNow()
        store.flushIO()
        XCTAssertEqual(store.clips.count, 0)
        XCTAssertNil(store.plainData("anything"), "no reads")
        XCTAssertEqual(ClipboardSynth.everything(under: root), before, "not a byte written, moved or removed, and the older files not migrated")
        XCTAssertEqual(custody.contents(of: "lodestar.ring.clipboard"), ringBefore)

        // The controller does not even read the pasteboard.
        let controller = ClipboardController(store: store)
        let board = NSPasteboard(name: NSPasteboard.Name("lodestar-paused-\(UUID().uuidString)"))
        controller.pasteboard = board
        SystemEvents.pasteboard.clearContents()
        SystemEvents.pasteboard.setString("secret while paused", forType: .string)
        controller.capture()
        XCTAssertEqual(store.clips.count, 0)

        // Unlocking asks again.
        locked.unlock()
        store.retryAfterUnlock()
        XCTAssertEqual(store.waitUntilOpen(), .ready)
        XCTAssertEqual(store.clips.count, 1 + 3, "the history, and the older files taken in")
        XCTAssertEqual(ClipboardV1.plaintextFiles(root), [])
        store.close()
    }

    func testARefusedKeychainIsNotAskedAgainAfterAnUnlock() throws {
        let first = SealedFixture.clipboardStore(root)
        copy(first, "x")
        first.close()
        let refusing = InMemoryKeyCustody(["lodestar.ring.clipboard": try XCTUnwrap(custody.contents(of: "lodestar.ring.clipboard"))])
        refusing.failNext(with: .unavailable(.accessDenied), on: .load)
        let store = ClipboardStore(root: root, vault: SealedFixture.vault(root, custody: refusing))
        store.waitUntilOpen()
        XCTAssertTrue(store.isPaused)
        XCTAssertEqual(store.statusLine, "⌂ clipboard history is unavailable — the keychain didn't open\nit is tried again at the next launch")
        store.retryAfterUnlock()
        XCTAssertTrue(store.isPaused, "a refusal is not a lock")
    }

    func testAMissingKeyMovesTheHistoryAsideStartsFreshAndSaysSoOnce() throws {
        let first = SealedFixture.clipboardStore(root)
        copy(first, "sealed under a key that will be gone")
        first.close()
        var notices: [String] = []
        let store = ClipboardStore(root: root, vault: SealedFixture.vault(root, custody: InMemoryKeyCustody()))
        store.onNotice = { notices.append($0) }
        store.waitUntilOpen()
        XCTAssertEqual(store.phase, .ready)
        XCTAssertEqual(store.clips.count, 0, "a fresh history")
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].contains("clipboard-unreadable-"), notices[0])
        XCTAssertNotNil(store.bootWarning)
        let aside = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("clipboard-unreadable-") }
        XCTAssertEqual(aside.count, 1, "kept, never deleted")
        copy(store, "and a new history works")
        store.close()
        let again = ClipboardStore(root: root, vault: SealedFixture.vault(root, custody: InMemoryKeyCustody()))
        var again1: [String] = []
        again.onNotice = { again1.append($0) }
        again.waitUntilOpen()
        // (A different custody again: but the point is the first launch told once, and the folder stayed.)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("clipboard-unreadable-") }.count, 2)
        again.close()
    }

    // MARK: Making a deletion real

    func testADeletedClipsKeyIsGoneOnceTheFoldAfterTheDeleteHasRun() throws {
        let store = SealedFixture.clipboardStore(root)
        let keep = copy(store, "keeper")
        let doomed = copy(store, "doomed")
        store.saveNow()
        store.flushIO()
        let journal = SealedFixture.v2(root).appendingPathComponent("index.sj")
        let recordsBefore = try Data(contentsOf: journal)
        let blob = try XCTUnwrap(store.blobURL(for: doomed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path))

        store.delete(doomed)
        wait("the fold runs") { store.compactions >= 1 }
        store.flushIO()
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob.path), "the blob was unlinked at once")
        // The records that held its key can no longer be opened by anyone.
        let scratch = directory.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try recordsBefore.write(to: scratch.appendingPathComponent("index.sj"))
        let ring = try XCTUnwrap(vault.ring(.clipboard).held)
        let replay = try SealedJournal.readOnlyReplay(at: scratch.appendingPathComponent("index.sj").path,
                                                      context: ClipboardSealed.indexContext, keyring: ring,
                                                      options: ClipboardSealed.journalOptions)
        XCTAssertEqual(replay.records.count, 0)
        XCTAssertEqual(replay.failures.count, 2)
        XCTAssertEqual(store.plainText(keep), "keeper", "the rest is as it was")
        store.close()
        XCTAssertEqual(SealedFixture.clipboardStore(root).clips.map(\.id), [keep])
    }

    func testATrimAndAnEditAreFoldedToo() throws {
        let store = SealedFixture.clipboardStore(root)
        let ids = (0..<6).map { copy(store, "clip \($0)") }
        store.flushIO()
        store.trim(maxBytes: Int.max, maxItems: 3)
        wait("trimmed and folded") { store.compactions >= 1 }
        XCTAssertEqual(store.clips.count, 3)
        let before = store.compactions
        let edited = store.replace(store.clips[0], withText: "edited")
        XCTAssertNotNil(edited)
        wait("the edit's old words are folded away") { store.compactions > before }
        XCTAssertNil(store.blobURL(for: ids[5]).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
        store.close()
    }

    func testAGrownLogIsFoldedAtIdle() throws {
        let store = SealedFixture.clipboardStore(root)
        let id = copy(store, "pinned and renamed")
        for n in 0..<600 { store.name(id, "name \(n)") }
        store.saveNow()
        wait("folded because the log grew") { store.compactions >= 1 }
        let log = (try? FileManager.default.attributesOfItem(atPath: SealedFixture.v2(root).appendingPathComponent("index.sj").path)[.size] as? Int) ?? -1
        XCTAssertLessThan(log, 4_096, "the log is short again")
        store.close()
        XCTAssertEqual(SealedFixture.clipboardStore(root).clips.first?.keptName, "name 599")
    }

    func testAQuitFinishesADeleteThatWasStillOwed() throws {
        ClipboardStore.deletionDelay = 60
        let store = SealedFixture.clipboardStore(root)
        let doomed = copy(store, "doomed")
        store.flushIO()
        let journal = SealedFixture.v2(root).appendingPathComponent("index.sj")
        let before = try Data(contentsOf: journal)
        store.delete(doomed)
        store.finishForQuit()
        XCTAssertEqual(store.compactions, 0, "the quit did it synchronously, not the timer")
        let scratch = directory.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try before.write(to: scratch.appendingPathComponent("index.sj"))
        let replay = try SealedJournal.readOnlyReplay(at: scratch.appendingPathComponent("index.sj").path,
                                                      context: ClipboardSealed.indexContext,
                                                      keyring: try XCTUnwrap(vault.ring(.clipboard).held), options: ClipboardSealed.journalOptions)
        XCTAssertEqual(replay.records.count, 0)
        store.close()
    }

    /// A crash between a delete and its fold must not leave the key readable
    /// for ever: the next launch knows a deletion is owed and does it.
    func testADeleteCutShortByACrashIsFinishedAtTheNextLaunch() throws {
        ClipboardStore.deletionDelay = 600
        let store = SealedFixture.clipboardStore(root)
        let doomed = copy(store, "doomed words")
        copy(store, "kept words")
        store.flushIO()
        let journal = SealedFixture.v2(root).appendingPathComponent("index.sj")
        let before = try Data(contentsOf: journal)
        store.delete(doomed)
        store.saveNow()
        store.flushIO()          // the record is on disk, the fold has not run: the process "dies" here
        XCTAssertEqual(store.compactions, 0)

        ClipboardStore.deletionDelay = 0.05
        let next = SealedFixture.clipboardStore(root)
        XCTAssertEqual(next.clips.count, 1)
        wait("the fold owed by the delete runs") { next.compactions >= 1 }
        let scratch = directory.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try before.write(to: scratch.appendingPathComponent("index.sj"))
        let replay = try SealedJournal.readOnlyReplay(at: scratch.appendingPathComponent("index.sj").path,
                                                      context: ClipboardSealed.indexContext,
                                                      keyring: try XCTUnwrap(vault.ring(.clipboard).held), options: ClipboardSealed.journalOptions)
        XCTAssertEqual(replay.records.count, 0, "the doomed clip's key is gone")
        next.close()
    }

    // MARK: Plaintext

    func testNothingUnderTheClipboardFolderHoldsAWordOfAClipAfterACopyAnImageAndAMigration() throws {
        _ = try older(10)
        let store = SealedFixture.clipboardStore(root)
        store.readText = { _ in "SCREENSHOT-OCR-WORDS" }
        copy(store, "\(ClipboardSynth.marker) fresh copy", rich: "<b>\(ClipboardSynth.marker) rich</b>")
        let png = Stage.pngData(width: 30, height: 20)
        store.record(id: "img", kind: .image, items: [.init(plain: nil, natives: [("public.png", png)])],
                     imageData: png, preview: "image 30×20", sourceBundleID: nil, sourceAppName: nil)
        wait("captioned") { store.clips.first { $0.id == "img" }?.preview.contains("SCREENSHOT") == true }
        store.saveNow()
        store.flushIO()
        store.close()
        XCTAssertEqual(ClipboardSynth.plaintextHits(under: root, extra: ["SCREENSHOT-OCR-WORDS", "fresh copy"]), [])
        XCTAssertEqual(ClipboardSynth.everything(under: root).values.filter { $0.range(of: png.prefix(16)) != nil }.count, 0, "nor a PNG header")
    }

    // MARK: A paste reads what it wrote

    func testAPasteReadsBackEveryKindOfClipExactly() throws {
        let store = SealedFixture.clipboardStore(root)
        let png = Stage.pngData(width: 30, height: 20)
        store.record(id: "multi", kind: .text,
                     items: [.init(plain: Data("a".utf8), natives: [("public.file-url", Data("file:///a".utf8))]),
                             .init(plain: Data("b".utf8), natives: [("public.file-url", Data("file:///b".utf8))])],
                     imageData: nil, preview: "a\nb", sourceBundleID: nil, sourceAppName: nil)
        store.record(id: "img", kind: .image, items: [.init(plain: nil, natives: [("public.png", png)])],
                     imageData: nil, preview: "image", sourceBundleID: nil, sourceAppName: nil)
        // Read at once, with the writes perhaps still in flight: the read waits for them.
        let multi = try XCTUnwrap(store.clips.first { $0.id == "multi" })
        let items = store.itemData(multi)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.map { String(decoding: $0.plain ?? Data(), as: UTF8.self) }, ["a", "b"])
        XCTAssertEqual(items[1].natives.first?.type, "public.file-url")
        XCTAssertEqual(store.itemData(try XCTUnwrap(store.clips.first { $0.id == "img" })).first?.natives.first?.data, png)
        store.close()
    }
}
