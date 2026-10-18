import StoicApple
import StoicSealed
import StoicStore
import XCTest
@testable import LodestarCore

/// The sealed clipboard history's disk layer: what it holds, how a deletion
/// becomes real, what each state of the key does, and the migration of an
/// older history in (and the merge of one that an older build wrote after).
final class SealedClipboardTests: XCTestCase {
    private var directory: URL!
    private var root: URL { directory.appendingPathComponent("clipboard", isDirectory: true) }
    private var custody: InMemoryKeyCustody!
    private var vault: Vault!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sealed-clipboard-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        custody = InMemoryKeyCustody()
        vault = Vault(custody: custody, directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Helpers

    /// A folder nothing can be made in, even by its owner (a full disk, a
    /// volume gone read-only), whatever the clipboard does to its mode.
    private func lock(_ url: URL) { chflags(url.path, UInt32(UF_IMMUTABLE)) }
    private func unlock(_ url: URL) { chflags(url.path, 0) }

    private func clipboard(_ vault: Vault? = nil, fileSystem: any FileSystem = OwnerOnly.fileSystem) -> SealedClipboard {
        SealedClipboard(root: root, ring: (vault ?? self.vault).ring(.clipboard), fileSystem: fileSystem)
    }

    @discardableResult
    private func ready(_ store: SealedClipboard, file: StaticString = #filePath, line: UInt = #line) -> SealedClipboard.Opened {
        switch store.open() {
        case .ready(let opened): return opened
        case .unavailable(let why):
            XCTFail("unavailable: \(why.words)", file: file, line: line)
            return SealedClipboard.Opened(entries: [], unreadable: 0, orphansRemoved: 0, seconds: 0)
        }
    }

    private func clip(_ id: String, text: String? = nil, created: TimeInterval = 1_800_000_000, pinned: Int? = nil) -> Clipboard.Clip {
        let text = text ?? "text of \(id)"
        return Clipboard.Clip(id: id, kind: .text, created: Date(timeIntervalSince1970: created), sourceBundleID: nil,
                              sourceAppName: nil, preview: text, bytes: text.utf8.count, pinnedSlot: pinned)
    }

    /// A clip with its blob written, ready for a record.
    private func entry(_ store: SealedClipboard, _ clip: Clipboard.Clip, plain: String? = nil,
                       natives: [(type: String, data: Data)] = []) throws -> ClipEntry {
        let key = SealingKey.generate()
        let storage = ClipboardSealed.newStorage()
        try store.files.writeBlob(storage: storage, key: key,
                                  items: [.init(plain: Data((plain ?? clip.preview).utf8), natives: natives)])
        return ClipEntry(clip: clip, storage: storage, blobKey: Data(key.exportedForWrapping()))
    }

    private func plain(_ store: SealedClipboard, _ entry: ClipEntry) -> String? {
        guard let key = entry.key, case .items(let items) = store.files.readBlob(storage: entry.storage, key: key),
              let data = items.first?.plain else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: The container

    func testTheContainerRoundTripsEveryShape() {
        let shapes: [[ClipboardContent.Item]] = [
            [],
            [.init(plain: Data("text".utf8), natives: [])],
            [.init(plain: Data(), natives: [])],
            [.init(plain: nil, natives: [("public.png", Data([0, 1, 2, 255]))])],
            [.init(plain: Data("é日本".utf8), natives: [("public.html", Data("<b>x</b>".utf8)), ("public.rtf", Data())]),
             .init(plain: nil, natives: []),
             .init(plain: Data("third".utf8), natives: [("public.file-url", Data("file:///x".utf8))])],
        ]
        for shape in shapes {
            let decoded = ClipboardContent.decode(ClipboardContent.encode(shape))
            XCTAssertNotNil(decoded)
            XCTAssertTrue(ClipboardContent.sameBytes(decoded ?? [], shape), "\(shape.count) items")
        }
        XCTAssertNil(ClipboardContent.decode([]))
        XCTAssertNil(ClipboardContent.decode([2, 0, 0, 0, 0]), "another version")
        let whole = ClipboardContent.encode(shapes[4])
        XCTAssertNil(ClipboardContent.decode(Array(whole.dropLast())), "a cut container is not read as a shorter one")
        XCTAssertNil(ClipboardContent.decode(whole + [0]), "and neither is one with something after it")
    }

    func testAnEntryAndEveryOperationRoundTripThroughJSON() throws {
        let made = ClipboardSynth.make(count: 8)
        let entry = ClipEntry(clip: made.clips[0], storage: ClipboardSealed.newStorage(), blobKey: Data(SealingKey.generate().exportedForWrapping()))
        for op in [ClipboardOp.front(entry), .tail(entry), .ordered(entry), .set(entry), .replace(old: "a", entry),
                   .delete(["a", "b"]), .imported(digest: "abc")] {
            let bytes = try XCTUnwrap(ClipboardIndexState.encode(op))
            XCTAssertEqual(try JSONDecoder().decode(ClipboardOp.self, from: Data(bytes)), op)
        }
        XCTAssertNotNil(entry.key, "the key comes back out of its exported bytes")
        XCTAssertThrowsError(try JSONDecoder().decode(ClipboardOp.self, from: Data(#"{"op":"nope"}"#.utf8)))
    }

    // MARK: Opening

    func testAFreshHistoryOpensEmptyAndMakesItsRing() throws {
        XCTAssertEqual(custody.names, [])
        let store = clipboard()
        let first = ready(store)
        XCTAssertEqual(first.entries.count, 0)
        XCTAssertNil(first.movedAside)
        XCTAssertEqual(custody.names, ["lodestar.ring.clipboard"], "the ring is made")
        let modes = ClipboardSynth.modes(under: root)
        XCTAssertEqual(modes["v2"], 0o700)
        XCTAssertEqual(modes["v2/items"], 0o700)
        XCTAssertEqual(modes["v2/thumbs"], 0o700)
        XCTAssertEqual(modes[""], nil)
        XCTAssertEqual(((try FileManager.default.attributesOfItem(atPath: root.path))[.posixPermissions] as? Int), 0o700)
    }

    func testCopiesComeBackInOrderWithEverythingDoneToThem() throws {
        let store = clipboard()
        ready(store)
        let a = try entry(store, clip("a", created: 100)), b = try entry(store, clip("b", created: 200))
        let c = try entry(store, clip("c", created: 300))
        XCTAssertEqual(store.append([.front(a), .front(b), .front(c)]), .appended)
        var pinned = b
        pinned.clip.pinnedSlot = 3
        pinned.clip.keptName = "kept"
        XCTAssertEqual(store.append([.set(pinned)]), .appended)
        // A re-copy of `a` raises it, and a card that is deleted stays deleted.
        var again = a
        again.clip.preview = "a again"
        XCTAssertEqual(store.append([.front(again), .delete(["c"]), .set(c)]), .appended)
        store.close()

        let back = ready(clipboard())
        XCTAssertEqual(back.entries.map(\.clip.id), ["a", "b"])
        XCTAssertEqual(back.entries[0].clip.preview, "a again")
        XCTAssertEqual(back.entries[1].clip.pinnedSlot, 3)
        XCTAssertEqual(back.entries[1].clip.keptName, "kept")
        XCTAssertEqual(plain(clipboard(), back.entries[0]), "text of a", "the blob is the clip's own, and opens with the key in the record")
    }

    func testAnEditTakesItsCardsPlaceAndAnOpAboutAMissingCardChangesNothing() throws {
        let store = clipboard()
        ready(store)
        let a = try entry(store, clip("a", created: 100)), b = try entry(store, clip("b", created: 200))
        let c = try entry(store, clip("c", created: 300))
        store.append([.front(a), .front(b), .front(c)])
        var edited = try entry(store, clip("b2", created: 200, pinned: 4), plain: "edited")
        edited.clip.keptName = "name"
        store.append([.replace(old: "b", edited), .set(try entry(store, clip("ghost")))])
        store.close()
        let back = ready(clipboard())
        XCTAssertEqual(back.entries.map(\.clip.id), ["c", "b2", "a"], "in place, not at the top")
        XCTAssertEqual(back.entries[1].clip.pinnedSlot, 4)
    }

    func testAnEditToTextAnotherCardHasLeavesOneCardForIt() throws {
        let store = clipboard()
        ready(store)
        let a = try entry(store, clip("a", created: 100)), b = try entry(store, clip("b", created: 200))
        store.append([.front(a), .front(b)])
        let into = try entry(store, clip("a", created: 200))
        store.append([.replace(old: "b", into)])
        store.close()
        XCTAssertEqual(ready(clipboard()).entries.map(\.clip.id), ["a"])
    }

    // MARK: Making a deletion real

    func testADeletedClipCannotBeOpenedByAnyoneOnceTheNextCompactionHasRun() throws {
        let store = clipboard()
        ready(store)
        let keep = try entry(store, clip("keep", created: 100))
        let doomed = try entry(store, clip("doomed", created: 200), plain: "the doomed words")
        store.append([.front(keep), .front(doomed)])
        let journalFile = URL(fileURLWithPath: store.files.indexPath)
        let recordsBefore = try Data(contentsOf: journalFile)
        let blobBefore = try Data(contentsOf: store.files.itemURL(doomed.storage))
        XCTAssertNotNil(plain(store, doomed))

        store.append([.delete(["doomed"])])
        store.files.remove(storages: [doomed.storage])
        // Deleted, and not yet unrecoverable: the old record still opens.
        let ring = try XCTUnwrap(vault.ring(.clipboard).held)
        let early = try SealedJournal.readOnlyReplay(at: journalFile.path, context: ClipboardSealed.indexContext, keyring: ring,
                                                     options: ClipboardSealed.journalOptions)
        XCTAssertEqual(early.failures.count, 0)
        let idsBefore = ring.keyIDs

        guard case .compacted = store.compact(rotatingKey: true) else { return XCTFail("did not compact") }

        XCTAssertFalse(ring.keyIDs.contains(where: { idsBefore.contains($0) }), "every key that sealed the old records is retired")
        // The old journal's bytes, put back where anyone could read them,
        // do not open with the ring that remains: the clip's key was in them.
        let scratch = directory.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let old = scratch.appendingPathComponent("index.sj")
        try recordsBefore.write(to: old)
        let replay = try SealedJournal.readOnlyReplay(at: old.path, context: ClipboardSealed.indexContext, keyring: ring,
                                                      options: ClipboardSealed.journalOptions)
        XCTAssertEqual(replay.records.count, 0)
        XCTAssertEqual(replay.failures.count, 2)
        XCTAssertTrue(replay.failures.allSatisfy { if case .unknownKey = $0.error { true } else { false } })
        // And the blob copy has nothing that would open it: its key is in a record no key opens.
        XCTAssertNotNil(blobBefore.first)
        XCTAssertFalse(ClipboardSynth.everything(under: root).values.contains { $0.range(of: Data("the doomed words".utf8)) != nil })
        // What stays opens.
        store.close()
        let back = ready(clipboard())
        XCTAssertEqual(back.entries.map(\.clip.id), ["keep"])
        XCTAssertEqual(plain(clipboard(), back.entries[0]), "text of keep")
    }

    func testABlobOpensOnlyWithItsOwnKeyAndNameAndNeverWithTheRing() throws {
        let store = clipboard()
        ready(store)
        let one = try entry(store, clip("one"), plain: "one words"), two = try entry(store, clip("two"), plain: "two words")
        let bytes = [UInt8](try Data(contentsOf: store.files.itemURL(one.storage)))
        XCTAssertNoThrow(try Sealing.open(bytes, context: ClipboardSealed.blobContext(one.storage), key: try XCTUnwrap(one.key)))
        XCTAssertThrowsError(try Sealing.open(bytes, context: ClipboardSealed.blobContext(two.storage), key: try XCTUnwrap(one.key)),
                             "moved to another clip's name, it does not open")
        XCTAssertThrowsError(try Sealing.open(bytes, context: ClipboardSealed.blobContext(one.storage), key: try XCTUnwrap(two.key)),
                             "nor under another clip's key")
        let ring = try XCTUnwrap(vault.ring(.clipboard).held)
        XCTAssertThrowsError(try Sealing.open(bytes, context: ClipboardSealed.blobContext(one.storage), keyring: ring),
                             "the ring never sealed it: rotating the ring rewrites no blob")
        XCTAssertNotEqual(one.storage, two.storage)
        XCTAssertTrue(ClipboardSealed.isStorageName(one.storage))
        XCTAssertFalse(ClipboardSynth.everything(under: root).keys.contains { $0.contains("one") || $0.contains("two") }, "no file name says what is in it")
    }

    func testThumbnailsAreSealedUnderTheClipsKey() throws {
        let store = clipboard()
        ready(store)
        let e = try entry(store, clip("img"))
        try store.files.writeThumb(storage: e.storage, key: try XCTUnwrap(e.key), png: Data("PNGBYTES".utf8))
        XCTAssertEqual(store.files.readThumb(storage: e.storage, key: try XCTUnwrap(e.key)), Data("PNGBYTES".utf8))
        XCTAssertNil(store.files.readThumb(storage: e.storage, key: SealingKey.generate()))
        XCTAssertFalse(ClipboardSynth.plaintextHits(under: root, extra: ["PNGBYTES"]).contains { $0.contains("thumbs") })
    }

    func testCompactionFoldsTheLogAndTheHistoryIsTheSameAfter() throws {
        let store = clipboard()
        ready(store)
        var ops: [ClipboardOp] = []
        for n in 0..<30 { ops.append(.front(try entry(store, clip("c\(n)", created: Double(n))))) }
        store.append(ops)
        store.append([.delete(["c3", "c4"])])
        guard case .compacted(let records, _) = store.compact() else { return XCTFail() }
        XCTAssertEqual(records, 31)
        store.append([.front(try entry(store, clip("late", created: 99)))])
        store.close()
        let back = ready(clipboard())
        XCTAssertEqual(back.entries.count, 29)
        XCTAssertEqual(back.entries.first?.clip.id, "late")
        XCTAssertFalse(back.entries.contains { $0.clip.id == "c3" })
    }

    func testTheLogIsFoldedPastFiveHundredRecordsOrTwiceTheSnapshot() throws {
        let store = clipboard()
        ready(store)
        XCTAssertFalse(store.needsCompaction)
        let entries = (0..<400).map { ClipEntry(clip: clip("c\($0)"), storage: ClipboardSealed.newStorage(), blobKey: Data(SealingKey.generate().exportedForWrapping())) }
        store.append(entries.map { .front($0) })
        XCTAssertFalse(store.needsCompaction, "400 small records are not yet")
        store.append(entries.prefix(101).map { .set($0) })
        XCTAssertTrue(store.needsCompaction, "past 500")
        store.compact()
        XCTAssertFalse(store.needsCompaction)
    }

    // MARK: The key

    func testACustodyThatCannotBeAskedPausesTheHistoryAndTouchesNothing() throws {
        // A history, sealed under a ring that is in the custody.
        let first = clipboard()
        ready(first)
        first.append([.front(try entry(first, clip("a")))])
        first.close()
        let before = ClipboardSynth.everything(under: root)
        let ringBefore = custody.contents(of: "lodestar.ring.clipboard")
        // And an older plaintext history beside it, which must not be migrated.
        let made = ClipboardSynth.make(count: 6)
        try ClipboardSynth.write(made, to: root)
        let v1Before = ClipboardSynth.everything(under: root).filter { before[$0.key] == nil }

        let locked = LockedCustody(copying: custody)
        let lockedVault = Vault(custody: locked, directory: directory)
        let store = clipboard(lockedVault)
        guard case .unavailable(let why) = store.open() else { return XCTFail("opened with a locked keychain") }
        XCTAssertTrue(why.retryable)
        XCTAssertTrue(why.words.contains("locked"), why.words)
        XCTAssertEqual(ClipboardSynth.everything(under: root).filter { before[$0.key] == nil }, v1Before, "the old files are as they were")
        for (name, bytes) in before { XCTAssertEqual(ClipboardSynth.everything(under: root)[name], bytes, name) }
        XCTAssertEqual(custody.contents(of: "lodestar.ring.clipboard"), ringBefore, "no key made, none touched")
        XCTAssertEqual(store.append([.delete(["a"])]), .closed, "nothing is written while paused")
        XCTAssertEqual(store.compact(), .closed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("v2.migrating").path))

        // The screen unlocks: asked again, and it opens, and the older files are taken in.
        locked.unlock()
        XCTAssertTrue(lockedVault.ring(.clipboard).retry())
        let after = ready(store)
        XCTAssertEqual(Set(after.entries.map(\.clip.id)), Set(made.clips.map(\.id)).union(["a"]),
                       "what was sealed, and the older files taken in")
        XCTAssertEqual(ClipboardV1.plaintextFiles(root), [])
    }

    func testARefusedKeychainIsNotRetriedAndIsNotAMissingKey() throws {
        let first = clipboard()
        ready(first)
        first.append([.front(try entry(first, clip("a")))])
        first.close()
        let refusing = InMemoryKeyCustody(["lodestar.ring.clipboard": try XCTUnwrap(custody.contents(of: "lodestar.ring.clipboard"))])
        refusing.failNext(with: .unavailable(.accessDenied), on: .load)
        let store = clipboard(Vault(custody: refusing, directory: directory))
        guard case .unavailable(let why) = store.open() else { return XCTFail() }
        XCTAssertFalse(why.retryable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("v2").path), "v2 is where it was")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("clipboard-unreadable") }, [])
    }

    func testAMissingRingWithSealedDataMovesTheHistoryAsideAndStartsFresh() throws {
        let first = clipboard()
        ready(first)
        let e = try entry(first, clip("a"))
        first.append([.front(e)])
        first.close()
        let sealedBefore = ClipboardSynth.everything(under: root.appendingPathComponent("v2"))

        let lost = Vault(custody: InMemoryKeyCustody(), directory: directory)
        let store = clipboard(lost)
        let opened = ready(store)
        let folder = try XCTUnwrap(opened.movedAside)
        XCTAssertTrue(folder.hasPrefix("clipboard-unreadable-"), folder)
        XCTAssertEqual(opened.entries.count, 0, "a fresh history")
        XCTAssertEqual(ClipboardSynth.everything(under: root.appendingPathComponent(folder)), sealedBefore, "kept whole, never deleted")
        XCTAssertNotNil(lost.ring(.clipboard).held, "and a new ring is made")
        // The next launch says nothing more.
        store.close()
        XCTAssertNil(self.ready(clipboard(lost)).movedAside)
    }

    func testAMissingRingWithNothingSealedMakesOne() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("v2/items"), withIntermediateDirectories: true)
        let store = clipboard()
        XCTAssertNil(ready(store).movedAside)
        XCTAssertEqual(custody.names, ["lodestar.ring.clipboard"])
    }

    func testAHistoryNoneOfWhichOpensUnderTheRingThereIsMovesAside() throws {
        let first = clipboard()
        ready(first)
        first.append([.front(try entry(first, clip("a")))])
        first.close()
        // A ring that exists, and is not the one that sealed this.
        let other = Vault(custody: InMemoryKeyCustody(), directory: directory)
        _ = other.ring(.clipboard).keyring()
        let store = clipboard(other)
        let o = ready(store)
        XCTAssertNotNil(o.movedAside)
        XCTAssertEqual(o.entries.count, 0)
    }

    func testClearingDestroysTheRingAndRemovesEverythingAnOlderBuildLeftToo() throws {
        let store = clipboard()
        ready(store)
        store.append([.front(try entry(store, clip("a")))])
        try ClipboardSynth.write(ClipboardSynth.make(count: 3), to: root)
        try Data("x".utf8).write(to: root.appendingPathComponent("index.json.corrupt-2026"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("clipboard-unreadable-2026-01-01"), withIntermediateDirectories: true)
        let flag = root.appendingPathComponent("clear-requested")
        try Data().write(to: flag)

        XCTAssertTrue(store.clear())

        XCTAssertEqual(custody.names, [], "the ring is destroyed: whatever survives on a disk is noise")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["clear-requested"],
                       "the folder holds nothing of the history (the flag is the caller's)")
        // The next capture makes a new ring.
        let again = clipboard()
        XCTAssertEqual(ready(again).entries.count, 0)
        XCTAssertEqual(custody.names, ["lodestar.ring.clipboard"])
    }

    // MARK: Orphans

    func testABlobWhoseRecordNeverLandedIsRemovedAtLoadAndOnlyThat() throws {
        let store = clipboard()
        ready(store)
        let kept = try entry(store, clip("kept"))
        store.append([.front(kept)])
        let orphan = try entry(store, clip("orphan"))
        try store.files.writeThumb(storage: orphan.storage, key: try XCTUnwrap(orphan.key), png: Data("t".utf8))
        let torn = store.files.itemURL(ClipboardSealed.newStorage()).appendingPathExtension("1a2b3c4d")
        try Data("half".utf8).write(to: torn)
        let strange = store.files.items.appendingPathComponent("README")
        try Data("not ours".utf8).write(to: strange)
        store.close()

        let back = ready(clipboard())
        XCTAssertEqual(back.orphansRemoved, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.files.itemURL(orphan.storage).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.files.thumbURL(orphan.storage).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: torn.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: strange.path), "a name that is not a storage name is not ours")
        XCTAssertNotNil(plain(clipboard(), kept))
    }

    func testNothingIsCollectedAndNothingFoldedWhileSomeOfTheIndexDoesNotOpen() throws {
        let store = clipboard()
        ready(store)
        let old = try entry(store, clip("old"))
        store.append([.front(old)])
        let ring = try XCTUnwrap(vault.ring(.clipboard).held)
        let oldKey = ring.keyIDs
        // A key rotation that retires what sealed `old`'s record, and a record after it.
        _ = try ring.rotate()
        store.append([.front(try entry(store, clip("new")))])
        _ = try ring.retire(ids: oldKey)
        store.close()

        let orphan = ClipboardSealed.newStorage()
        try Data("whatever".utf8).write(to: ClipboardFiles(root: root).itemURL(orphan))
        let again = clipboard()
        let back = ready(again)
        XCTAssertEqual(back.unreadable, 1)
        XCTAssertEqual(back.entries.map(\.clip.id), ["new"])
        XCTAssertEqual(back.orphansRemoved, 0, "the blob of the record that would not open is kept, with every other file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ClipboardFiles(root: root).itemURL(old.storage).path))
        XCTAssertEqual(again.compact(), .refused(unreadable: 1), "a snapshot of the rest would destroy what could not be read")
    }

    // MARK: Migration

    private func migrate(_ made: ClipboardSynth.Made, fileSystem: any FileSystem = OwnerOnly.fileSystem) throws -> (SealedClipboard, SealedClipboard.Opened) {
        try ClipboardSynth.write(made, to: root)
        let store = clipboard(fileSystem: fileSystem)
        return (store, ready(store))
    }

    private func assertHolds(_ made: ClipboardSynth.Made, in store: SealedClipboard, _ opened: SealedClipboard.Opened,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(opened.entries.map(\.clip), made.clips, "the same cards in the same order, pins and names with them", file: file, line: line)
        for entry in opened.entries {
            let key = try XCTUnwrap(entry.key, file: file, line: line)
            guard case .items(let items) = store.files.readBlob(storage: entry.storage, key: key) else {
                return XCTFail("\(entry.clip.id): the blob does not open", file: file, line: line)
            }
            XCTAssertTrue(ClipboardContent.sameBytes(items, made.items[entry.clip.id] ?? []), entry.clip.id, file: file, line: line)
            XCTAssertEqual(store.files.readThumb(storage: entry.storage, key: key), made.thumbnails[entry.clip.id], file: file, line: line)
        }
    }

    func testAnOlderHistoryIsSealedReadBackAndItsPlaintextRemoved() throws {
        let made = ClipboardSynth.make(count: 60)
        try ClipboardSynth.write(made, to: root)
        try Data("quarantined \(ClipboardSynth.marker)".utf8).write(to: root.appendingPathComponent("index.json.corrupt-2026-10-01"))
        XCTAssertFalse(ClipboardSynth.plaintextHits(under: root).isEmpty, "the fixture is plaintext")

        let store = clipboard()
        let opened = ready(store)
        try assertHolds(made, in: store, opened)
        let report = try XCTUnwrap(opened.migration)
        XCTAssertEqual(report.kind, .migrated)
        XCTAssertEqual(report.clips, 60)
        XCTAssertEqual(report.unreadableFiles, 0)
        XCTAssertEqual(report.left, [])
        XCTAssertGreaterThan(report.removedFiles, 60)

        XCTAssertEqual(ClipboardV1.plaintextFiles(root), [], "index.json, items/, thumbs/ and the quarantine are gone")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(names, ["v2"], "and v2.migrating was renamed, not copied")
        XCTAssertEqual(ClipboardSynth.plaintextHits(under: root), [], "no file under the clipboard folder holds a word of any clip")
        // Every name under v2 is a storage name, or the journal.
        for name in try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("v2/items").path) {
            XCTAssertTrue(ClipboardSealed.isStorageName(name), name)
        }
        // And it is the owner's alone.
        for (name, mode) in ClipboardSynth.modes(under: root) {
            let isDirectory = (try? URL(fileURLWithPath: root.appendingPathComponent(name).path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            XCTAssertEqual(mode, isDirectory ? 0o700 : 0o600, name)
        }
        store.close()
        // A second launch finds nothing to do and the same history.
        let again = clipboard()
        let second = ready(again)
        XCTAssertNil(second.migration)
        try assertHolds(made, in: again, second)
    }

    func testAClipWhoseOldFilesAreMissingKeepsItsCardWithWhatIsReadable() throws {
        let made = ClipboardSynth.make(count: 12)
        try ClipboardSynth.write(made, to: root)
        let rich = made.clips[1]
        let image = made.clips[2]
        try FileManager.default.removeItem(at: ClipboardV1.nativeFile(root, id: rich.id, item: 0, offset: 0))   // the html
        try FileManager.default.removeItem(at: ClipboardV1.nativeFile(root, id: image.id, item: 0, offset: 0))  // the whole image
        try FileManager.default.removeItem(at: ClipboardV1.thumbFile(root, id: image.id))
        let store = clipboard()
        let opened = ready(store)
        let report = try XCTUnwrap(opened.migration)
        XCTAssertEqual(report.missingFiles, 2, "counted: the html and the image (an image has no plain form, and that is not a loss)")
        XCTAssertEqual(opened.entries.map(\.clip.id), made.clips.map(\.id), "every card is still there")
        func items(_ clip: Clipboard.Clip) throws -> [ClipboardContent.Item] {
            let entry = try XCTUnwrap(opened.entries.first { $0.clip.id == clip.id })
            guard case .items(let items) = store.files.readBlob(storage: entry.storage, key: try XCTUnwrap(entry.key)) else { return [] }
            return items
        }
        XCTAssertEqual(try items(rich)[0].natives.map(\.type), ["public.rtf"], "what could be read")
        XCTAssertNotNil(try items(rich)[0].plain)
        XCTAssertEqual(try items(image)[0].natives.count, 0)
        XCTAssertEqual(ClipboardV1.plaintextFiles(root), [])
    }

    func testAFileThatIsThereAndCannotBeReadIsLeftAndNamedNotRemoved() throws {
        let made = ClipboardSynth.make(count: 8)
        try ClipboardSynth.write(made, to: root)
        let victim = ClipboardV1.plainFile(root, id: made.clips[4].id, item: 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: victim.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: victim.path) }
        let store = clipboard()
        let opened = ready(store)
        let report = try XCTUnwrap(opened.migration)
        XCTAssertEqual(report.unreadableFiles, 1)
        XCTAssertEqual(report.left, ["items/" + victim.lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path), "never removed unread")
        XCTAssertEqual(opened.entries.count, 8)
    }

    func testAnIndexThatCannotBeReadIsLeftAloneWithEverythingBesideIt() throws {
        let made = ClipboardSynth.make(count: 5)
        try ClipboardSynth.write(made, to: root)
        let index = ClipboardV1.indexFile(root)
        let before = ClipboardSynth.everything(under: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: index.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path) }
        let store = clipboard()
        let opened = ready(store)
        XCTAssertNil(opened.migration)
        XCTAssertEqual(opened.entries.count, 0, "a fresh history in the meantime")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
        for (name, bytes) in before { XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), bytes, name) }
    }

    func testAnIndexThatWillNotDecodeIsSetAsideAndEverythingBesideItKept() throws {
        let made = ClipboardSynth.make(count: 5)
        try ClipboardSynth.write(made, to: root)
        let index = ClipboardV1.indexFile(root)
        let garbage = Data("{\"clips\": [{\"id\": 1".utf8)
        try garbage.write(to: index)
        let blobs = try FileManager.default.contentsOfDirectory(atPath: ClipboardV1.items(root).path).sorted()
        let store = clipboard()
        let opened = ready(store)
        let name = try XCTUnwrap(opened.quarantined)
        XCTAssertTrue(name.hasPrefix("index.json.corrupt-"))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), garbage, "kept byte for byte")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ClipboardV1.items(root).path).sorted(), blobs)
        XCTAssertNil(opened.migration)
        XCTAssertEqual(opened.entries.count, 0)
        store.close()
        // The next launch does not set it aside again, nor lose it.
        XCTAssertNil(self.ready(clipboard()).quarantined)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
    }

    func testAMigrationThatCannotWriteRemovesNothing() throws {
        let made = ClipboardSynth.make(count: 10)
        try ClipboardSynth.write(made, to: root)
        let before = ClipboardSynth.everything(under: root)
        lock(root)
        defer { unlock(root) }
        let store = clipboard()
        guard case .unavailable(let why) = store.open() else { return XCTFail("opened") }
        XCTAssertFalse(why.retryable)
        unlock(root)
        XCTAssertEqual(ClipboardSynth.everything(under: root), before, "every old file is where it was, and nothing new is left")
    }

    /// The crash table, swept: the migration run on a file system that dies
    /// after N calls, for every N, and then the next launch. At every point
    /// the history opens, and it holds every clip with every byte.
    func testACrashAtAnyPointOfTheMigrationLosesNothing() throws {
        let made = ClipboardSynth.make(count: 14)
        let counter = DyingFileSystem()
        try ClipboardSynth.write(made, to: root)
        _ = ready(clipboard(fileSystem: counter))
        let total = counter.calls
        XCTAssertGreaterThan(total, 10)
        try FileManager.default.removeItem(at: root)

        var sawBothHalves = (v1Kept: false, v1Gone: false)
        for limit in stride(from: 0, through: total, by: 1) {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("clipboard-unreadable-x"))
            custody = InMemoryKeyCustody()
            vault = Vault(custody: custody, directory: directory)
            try ClipboardSynth.write(made, to: root)

            let dying = DyingFileSystem(dyingAfter: limit)
            let doomed = clipboard(fileSystem: dying)
            _ = doomed.open()           // the process is "killed" wherever this stopped
            doomed.close()

            let state = (v1: FileManager.default.fileExists(atPath: ClipboardV1.indexFile(root).path),
                         v2: FileManager.default.fileExists(atPath: root.appendingPathComponent("v2/index.sj").path))
            // What a crash leaves is one of the table's rows; whatever it is, the next launch is whole.
            let next = clipboard()
            let reopened = ready(next)
            try assertHolds(made, in: next, reopened)
            next.close()
            if state.v1 { sawBothHalves.v1Kept = true } else { sawBothHalves.v1Gone = true }
            // And now there is nothing in the clear, whatever the crash was.
            XCTAssertEqual(ClipboardV1.plaintextFiles(root), [], "after the launch that follows a crash at call \(limit)")
            XCTAssertEqual(ClipboardSynth.plaintextHits(under: root), [], "call \(limit)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("v2.migrating").path))
        }
        XCTAssertTrue(sawBothHalves.v1Kept && sawBothHalves.v1Gone, "the sweep crossed the rename")
    }

    // MARK: A downgrade

    /// What an older build writes beside a sealed history: a fresh `index.json` and files.
    private func olderBuildCopies(_ clips: [Clipboard.Clip], items: [String: [ClipboardContent.Item]]) throws {
        for clip in clips { try ClipboardV1.write(clip, items: items[clip.id] ?? [], to: root) }
        try ClipboardV1.writeIndex(clips, to: root)
    }

    func testClipsAnOlderBuildCopiedAreMergedByAgeAndTheOldFilesRemoved() throws {
        let made = ClipboardSynth.make(count: 12)
        let (store, first) = try migrate(made)
        XCTAssertNotNil(first.migration)
        store.close()
        XCTAssertEqual(ClipboardV1.plaintextFiles(root), [])

        // The older build runs: two new copies, a re-copy of a card (newer), a
        // copy of one the history has with the same age, and keepsakes.
        let newest = made.clips[0].created
        var fresh1 = clip("fresh-1", text: "\(ClipboardSynth.marker) fresh one", created: newest.timeIntervalSince1970 + 500, pinned: 3)
        var fresh2 = clip("fresh-2", text: "\(ClipboardSynth.marker) fresh two", created: newest.timeIntervalSince1970 + 900, pinned: 4)
        fresh1.keptName = "free place"
        fresh2.keptName = "taken place"
        var recopy = made.clips[7]
        recopy = Clipboard.Clip(id: recopy.id, kind: recopy.kind, created: newest.addingTimeInterval(700), sourceBundleID: "older.build",
                                sourceAppName: "Older", preview: recopy.preview, bytes: recopy.bytes, nativeTypes: ["public.html"])
        let same = made.clips[9]
        let extra = Data("\(ClipboardSynth.marker) html".utf8)
        let older: [String: [ClipboardContent.Item]] = [
            "fresh-1": [.init(plain: Data(fresh1.preview.utf8), natives: [])],
            "fresh-2": [.init(plain: Data(fresh2.preview.utf8), natives: [])],
            recopy.id: [.init(plain: made.items[recopy.id]![0].plain, natives: [("public.html", extra)])],
            same.id: made.items[same.id]!,
        ]
        let pinnedBefore = made.clips[5]   // slot 2 in the sealed history
        try olderBuildCopies([fresh2, recopy, fresh1, same], items: older)
        let vault2Blobs = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("v2/items").path)

        let store2 = clipboard()
        let merged = ready(store2)
        let report = try XCTUnwrap(merged.migration)
        XCTAssertEqual(report.kind, .merged)
        XCTAssertEqual(report.clips, 3, "fresh-1, fresh-2 and the newer copy")
        XCTAssertEqual(report.superseded, 1, "the copy with the same age: the sealed card stays")
        XCTAssertEqual(report.replaced, 1)
        XCTAssertEqual(report.pinsDropped, 1, "slot 4 was taken")

        let ids = merged.entries.map(\.clip.id)
        XCTAssertEqual(ids.count, 14)
        XCTAssertEqual(Array(ids.prefix(3)), ["fresh-2", made.clips[7].id, "fresh-1"], "by age, newest first")
        let created = merged.entries.map(\.clip.created)
        XCTAssertEqual(created, created.sorted(by: >), "the order is the age order throughout")
        let byID = Dictionary(uniqueKeysWithValues: merged.entries.map { ($0.clip.id, $0) })
        XCTAssertEqual(byID["fresh-1"]?.clip.pinnedSlot, 3, "a keepsake keeps a place that is free")
        XCTAssertEqual(byID["fresh-1"]?.clip.keptName, "free place")
        XCTAssertNil(byID["fresh-2"]?.clip.pinnedSlot, "and is an ordinary clip when it is not")
        XCTAssertNil(byID["fresh-2"]?.clip.keptName)
        XCTAssertEqual(byID[made.clips[0].id]?.clip.pinnedSlot, 4, "the sealed history's own keepsake is not displaced")
        XCTAssertEqual(byID[pinnedBefore.id]?.clip.pinnedSlot, 2)
        XCTAssertEqual(byID[recopy.id]?.clip.sourceAppName, "Older", "the newer copy won whole")
        XCTAssertEqual(byID[same.id]?.clip.sourceAppName, same.sourceAppName, "the same age: the sealed one won")
        // The replaced card's content is the newer copy's, and the old blob is gone.
        guard case .items(let items) = store2.files.readBlob(storage: byID[recopy.id]!.storage, key: try XCTUnwrap(byID[recopy.id]?.key)) else { return XCTFail() }
        XCTAssertEqual(items[0].natives.map(\.data), [extra])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("v2/items").path).count,
                       vault2Blobs.count + 2, "two new, one replaced")
        XCTAssertEqual(ClipboardV1.plaintextFiles(root), [])
        XCTAssertEqual(ClipboardSynth.plaintextHits(under: root), [])
        store2.close()
        // Repeated, it is a no-op.
        let third = ready(clipboard())
        XCTAssertNil(third.migration)
        XCTAssertEqual(third.entries.map(\.clip), merged.entries.map(\.clip))
    }

    func testTheReplacedCardCannotBeOpenedAfterTheMergeCompacts() throws {
        let made = ClipboardSynth.make(count: 6)
        let (store, first) = try migrate(made)
        let old = try XCTUnwrap(first.entries.first { $0.clip.id == made.clips[3].id })
        let oldRecords = try Data(contentsOf: URL(fileURLWithPath: store.files.indexPath))
        store.close()
        var newer = made.clips[3]
        newer = Clipboard.Clip(id: newer.id, kind: newer.kind, created: newer.created.addingTimeInterval(99_999), sourceBundleID: nil,
                               sourceAppName: nil, preview: newer.preview, bytes: newer.bytes)
        try olderBuildCopies([newer], items: [newer.id: made.items[newer.id]!])
        let store2 = clipboard()
        let merged = ready(store2)
        XCTAssertEqual(merged.migration?.replaced, 1)
        let ring = try XCTUnwrap(vault.ring(.clipboard).held)
        // The first migration's journal (it held the old key) does not open any more.
        let scratch = directory.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try oldRecords.write(to: scratch.appendingPathComponent("index.sj"))
        let replay = try SealedJournal.readOnlyReplay(at: scratch.appendingPathComponent("index.sj").path, context: ClipboardSealed.indexContext,
                                                      keyring: ring, options: ClipboardSealed.journalOptions)
        XCTAssertEqual(replay.records.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store2.files.itemURL(old.storage).path))
    }

    func testAMergeThatCannotWriteLeavesTheOlderFilesWhereTheyAre() throws {
        let made = ClipboardSynth.make(count: 6)
        let (store, _) = try migrate(made)
        store.close()
        let fresh = clip("fresh", text: "\(ClipboardSynth.marker) fresh", created: made.clips[0].created.timeIntervalSince1970 + 10)
        try olderBuildCopies([fresh], items: ["fresh": [.init(plain: Data(fresh.preview.utf8), natives: [])]])
        let before = ClipboardSynth.everything(under: ClipboardV1.items(root))
        let items = root.appendingPathComponent("v2/items")
        lock(items)
        defer { unlock(items) }
        let store2 = clipboard()
        let opened = ready(store2)
        unlock(items)
        XCTAssertNil(opened.migration, "refused")
        XCTAssertEqual(opened.entries.count, 6, "the sealed history is intact")
        XCTAssertEqual(ClipboardSynth.everything(under: ClipboardV1.items(root)), before, "and nothing of the older files was removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ClipboardV1.indexFile(root).path))
    }

    /// Cut at every point of a merge: the older files are there until they
    /// are all in, and whichever launch finishes it leaves the same history.
    func testACrashAtAnyPointOfAMergeLosesNothing() throws {
        let made = ClipboardSynth.make(count: 8)
        let fresh = (0..<3).map { clip("fresh-\($0)", text: "\(ClipboardSynth.marker) fresh \($0)", created: made.clips[0].created.timeIntervalSince1970 + Double($0 + 1) * 10) }
        let freshItems = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, [ClipboardContent.Item(plain: Data($0.preview.utf8), natives: [])]) })
        func setUp() throws {
            try? FileManager.default.removeItem(at: root)
            custody = InMemoryKeyCustody()
            vault = Vault(custody: custody, directory: directory)
            let (store, _) = try migrate(made)
            store.close()
            try olderBuildCopies(fresh, items: freshItems)
        }
        try setUp()
        let counter = DyingFileSystem()
        _ = ready(clipboard(fileSystem: counter))
        let total = counter.calls
        for limit in 0...total {
            try setUp()
            let doomed = clipboard(fileSystem: DyingFileSystem(dyingAfter: limit))
            _ = doomed.open()
            doomed.close()
            let next = clipboard()
            let reopened = ready(next)
            XCTAssertEqual(Set(reopened.entries.map(\.clip.id)), Set(made.clips.map(\.id) + fresh.map(\.id)), "crash at call \(limit)")
            for entry in reopened.entries {
                guard case .items = next.files.readBlob(storage: entry.storage, key: try XCTUnwrap(entry.key)) else {
                    return XCTFail("\(entry.clip.id) does not open after a crash at call \(limit)")
                }
            }
            XCTAssertEqual(ClipboardV1.plaintextFiles(root), [], "call \(limit)")
            next.close()
        }
    }

    // MARK: What `diagnose` says

    func testDiagnoseSaysWhatIsSealedWhatIsLeftAndWhatWasMovedAside() throws {
        let made = ClipboardSynth.make(count: 9)
        try ClipboardSynth.write(made, to: root)
        // Paused: the older files are still there, and the report says why.
        let locked = Vault(custody: LockedCustody(copying: custody), directory: directory)
        let paused = RecordStatus.clipboard(vault: locked, root: root)
        XCTAssertEqual(paused.key, .paused("the login keychain is locked"))
        XCTAssertGreaterThan(paused.plaintextFiles, 9)
        XCTAssertTrue(RecordStatus.clipboardLines(paused).joined().contains("PAUSED"))

        let store = clipboard()
        ready(store)
        store.close()
        let sealed = RecordStatus.clipboard(vault: vault, root: root)
        XCTAssertEqual(sealed.key, .ready)
        XCTAssertEqual(sealed.clips, 9)
        XCTAssertEqual(sealed.plaintextFiles, 0)
        XCTAssertEqual(sealed.unreadable, 0)
        XCTAssertEqual(RecordStatus.clipboardLines(sealed), ["clipboard history: sealed, 9 clips, 9 sealed files"])

        let lost = Vault(custody: InMemoryKeyCustody(), directory: directory)
        ready(clipboard(lost))
        let after = RecordStatus.clipboard(vault: lost, root: root)
        XCTAssertEqual(after.movedAside.count, 1)
        XCTAssertTrue(RecordStatus.clipboardLines(after).joined().contains("clipboard-unreadable-"))
    }
}
