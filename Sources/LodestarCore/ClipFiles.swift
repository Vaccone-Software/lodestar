import Foundation
import UniformTypeIdentifiers

/// A copy of files, as the history knows it: what makes a copy a file clip,
/// what the card says about each file, and how it says it. Pure; the reading
/// of the files themselves (their sizes, their pictures) is the app's, off the
/// main thread, and what it learns is kept on the clip as `FileFact`s so a
/// card is drawn without touching a file.
extension Clipboard {
    /// How many files' facts one clip keeps. The count of every item is
    /// already known from the types, so a copy of a hundred files stores a
    /// dozen facts and still says "100 files".
    public static let fileFactsKept = 12

    /// How many files of a copy get a picture of their own: the card draws
    /// a stack of at most four sheets.
    public static let thumbnailedFiles = 4

    /// The most names a file card lists. More files than this, and the
    /// third line gives way to "and N more".
    public static let fileCardNames = 3

    /// What one file is, as it was when it was copied.
    public struct FileFact: Codable, Equatable {
        public var name: String
        /// The folder it sits in, by its own name, never the whole path.
        public var folder: String
        /// The system's word for what it is ("PDF document").
        public var kind: String
        /// The uniform type identifier behind `kind`, which is what a
        /// card's icon is looked up by before the picture arrives.
        public var type: String?
        /// Its size, or nil for a folder, which says how many things it
        /// holds instead (`items`, counted one level deep, never beneath).
        public var bytes: Int?
        public var items: Int?
        /// One short line more: pages, pixels, or minutes and seconds.
        public var detail: String?
        /// Whether the picture kept for it is the file's own (a first page,
        /// a poster frame) rather than its icon, which is drawn another way.
        public var pictured: Bool?
        /// The site a downloaded file came from, by its host alone, as the
        /// Mac recorded the download: a search for "github" finds it.
        public var site: String?
        /// A PDF's own title, when its maker gave it one.
        public var title: String?

        public init(name: String, folder: String, kind: String, type: String? = nil,
                    bytes: Int? = nil, items: Int? = nil, detail: String? = nil, pictured: Bool? = nil,
                    site: String? = nil, title: String? = nil) {
            self.name = name
            self.folder = folder
            self.kind = kind
            self.type = type
            self.bytes = bytes
            self.items = items
            self.detail = detail
            self.pictured = pictured
            self.site = site
            self.title = title
        }
    }

    // MARK: - What a card of files is found by

    /// The words a card of files is searched by beyond what its text says:
    /// each file's name and extension, its folder, what kind of file it is
    /// in the words a hand types ("pdf", "photo", "video", "folder"), the
    /// site it was downloaded from, and a PDF's title. Lowercased, from the
    /// facts kept at the copy, so a search never reads a disk; never what
    /// is inside a file. Nil for any other card.
    static func searchTerms(of clip: Clip) -> String? {
        guard clip.pastesAsFiles, let facts = clip.fileFacts, !facts.isEmpty else { return nil }
        return facts.map { fact -> String in
            var words = [fact.name, (fact.name as NSString).pathExtension, fact.folder, fact.kind]
            words += kindWords(type: fact.type, folder: fact.items != nil)
            if let site = fact.site { words.append(site) }
            if let title = fact.title { words.append(title) }
            return words.filter { !$0.isEmpty }.joined(separator: " ")
        }.joined(separator: "\n").lowercased()
    }

    /// The site a download came from, out of the addresses the Mac kept for
    /// it (the file's own address first, then the page it was on): the
    /// first web host, without its `www.`. A host only, never a path or a
    /// query, which can carry a private token.
    public static func siteName(_ addresses: [String]) -> String? {
        addresses.lazy.compactMap { URL(string: $0) }
            .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
            .compactMap(\.host).first
            .map { $0.lowercased().hasPrefix("www.") ? String($0.dropFirst(4)) : $0.lowercased() }
    }

    /// What a hand calls a kind of file, by the type it is.
    static func kindWords(type identifier: String?, folder: Bool) -> [String] {
        if folder { return ["folder"] }
        guard let type = identifier.flatMap(UTType.init) else { return [] }
        let kinds: [(UTType, [String])] = [
            (.pdf, ["pdf", "document"]), (.image, ["image", "photo", "picture"]),
            (.movie, ["video", "movie"]), (.audio, ["audio", "sound", "music"]),
            (.archive, ["archive", "zip"]), (.sourceCode, ["code"]), (.text, ["text", "document"]),
            (.presentation, ["presentation", "slides"]), (.spreadsheet, ["spreadsheet"]),
            (.application, ["app"]),
        ]
        return kinds.filter { type.conforms(to: $0.0) }.flatMap(\.1)
    }

    // MARK: - What a copy is

    /// The types a picture travels as on the pasteboard.
    public static let imageTypes: Set<String> = ["public.png", "public.tiff"]

    /// What a copy becomes. A picture stays a picture, whatever else rides
    /// beside it, as it always has: it is read, captioned and opened large.
    /// Otherwise it is files exactly when **every** item is a file's address
    /// — a copy that mixes files with anything else is not a copy of files,
    /// and the card must not claim it is — and text when it is anything else.
    /// `itemTypes` is each pasteboard item's types, in board order.
    public static func kind(ofCopy itemTypes: [[String]]) -> Kind {
        guard let first = itemTypes.first else { return .text }
        if first.contains(where: { imageTypes.contains($0) }) { return .image }
        return itemTypes.allSatisfy({ $0.contains(fileURLType) }) ? .file : .text
    }

    /// The file a `public.file-url` item names. A file reference URL
    /// (`/.file/id=…`, which names the file by identity, not by place) is
    /// resolved to its path, and what cannot be is not a file we can show.
    public static func fileURL(from data: Data) -> URL? {
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))),
              let url = URL(string: text), url.isFileURL,
              let resolved = (url as NSURL).filePathURL, !resolved.path.hasPrefix("/.file/")
        else { return nil }
        return resolved
    }

    // MARK: - Where a copied file is now

    /// How many files of one copy are remembered by bookmark. A copy of
    /// more pastes the rest by the Finder's own address, which is good for
    /// as long as the Finder's reference lasts.
    public static let fileBookmarksKept = 200

    /// Where a copied file is now, which is what a paste has to know: a
    /// card can stand for weeks, and its file is moved, renamed, deleted or
    /// left on a disk that is not plugged in.
    public enum FilePlace: Equatable {
        /// Where it is, under the name it has now.
        case here(URL)
        /// In a Trash: deleted, and still there until the Trash is emptied.
        /// It does not paste: the Finder refuses a file in the Trash and
        /// pastes the next thing on the board instead, its icon as a file.
        case trashed(URL)
        /// Its disk is here and the file is not.
        case gone
        /// Its disk is not connected, or where it was cannot be told, so
        /// nothing is known either way.
        case away

        /// Where it pastes from, when it can be pasted at all.
        public var url: URL? {
            switch self {
            case .here(let url): return url
            case .trashed, .gone, .away: return nil
            }
        }
    }

    /// The Finder's address for an item of a copy, as it was written.
    public static func fileAddress(in item: ClipboardContent.Item) -> Data? {
        item.natives.first { $0.type == fileURLType }?.data
    }

    /// A bookmark of a file: what the system keeps to find a file again
    /// after it has been moved or renamed, and across restarts, which the
    /// Finder's reference is not made for. It names the file, never holds
    /// any of it, and keeps its disk so a disk that is not plugged in can
    /// be told from a file that is gone.
    public static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: [.volumeURLKey], relativeTo: nil)
    }

    /// Where the file an item of a copy names is now: by its bookmark when
    /// it has one, otherwise by the Finder's address. A bookmark that has
    /// gone stale, or a clip from before bookmarks whose file is still
    /// found, comes back with a fresh one to keep.
    public static func place(bookmark: Data?, address: Data?,
                             exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> (place: FilePlace, bookmark: Data?) {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                let found = place(of: url, exists: exists)
                return (found, stale && found.url != nil ? Self.bookmark(for: url) : nil)
            }
            // Not found: either its disk is away, or the file is.
            if let volume = URL.resourceValues(forKeys: [.volumeURLKey], fromBookmarkData: bookmark)?.volume,
               !exists(volume.path) {
                return (.away, nil)
            }
            return (.gone, nil)
        }
        // A reference that no longer resolves says nothing of where its file
        // went, so it is away rather than gone: nothing is decided on it.
        guard let address, let url = fileURL(from: address) else { return (.away, nil) }
        let found = place(of: url, exists: exists)
        return (found, found.url != nil ? Self.bookmark(for: url) : nil)
    }

    /// What a path says: here, in a Trash, or not there, and then whether
    /// its disk is.
    static func place(of url: URL, exists: (String) -> Bool) -> FilePlace {
        if exists(url.path) { return isInTrash(url) ? .trashed(url) : .here(url) }
        return diskIsHere(for: url, exists: exists) ? .gone : .away
    }

    /// A path under `/Volumes` is on a disk of its own, there only while it
    /// is mounted; anything else is on the startup disk, which always is.
    static func diskIsHere(for url: URL, exists: (String) -> Bool) -> Bool {
        let parts = url.pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return true }
        return exists("/Volumes/\(parts[2])")
    }

    /// A Trash is `.Trash` in a home folder and `.Trashes` on any other volume.
    public static func isInTrash(_ url: URL) -> Bool {
        url.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    /// Every item's file, in copy order. An item that names none is left
    /// out, so the list can be shorter than the copy.
    public static func fileURLs(in items: [ClipboardContent.Item]) -> [URL] {
        items.compactMap { item in
            item.natives.first { $0.type == fileURLType }.flatMap { fileURL(from: $0.data) }
        }
    }

    /// A file's name and the name of the folder it is in.
    public static func fileNames(of url: URL) -> (name: String, folder: String) {
        (url.lastPathComponent, url.deletingLastPathComponent().lastPathComponent)
    }

    // MARK: - What the card says

    /// The names a card has to show: the files' own once they have been read,
    /// and until then the last part of each path its preview holds, so a
    /// card made a moment ago already says what it is.
    public static func namesOnCard(of clip: Clip) -> [String] {
        if let facts = clip.fileFacts, !facts.isEmpty { return facts.map(\.name) }
        return clip.preview.split(separator: "\n").map { ($0 as NSString).lastPathComponent }.filter { !$0.isEmpty }
    }

    /// "and 5 more", the grey line under the names a card has room for.
    /// "+5" where "and 5 more" does not fit beside a stack.
    public static func moreLine(_ count: Int, short: Bool = false) -> String {
        short ? "+\(count)" : "and \(count) more"
    }

    /// The names a card lists beside its stack: all of them when three or
    /// fewer files were copied, otherwise the first two and how many more.
    /// `total` is how many files were copied, which can be more than there
    /// are names.
    public static func nameLines(names: [String], total: Int) -> [(text: String, grey: Bool)] {
        guard total > fileCardNames else { return names.prefix(total).map { ($0, false) } }
        return names.prefix(fileCardNames - 1).map { ($0, false) } + [(moreLine(total - (fileCardNames - 1)), true)]
    }

    /// A size as the Finder says it. Never "Zero KB": a card says "0 bytes".
    public static func byteText(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(bytes))
    }

    public static func itemsText(_ count: Int) -> String { count == 1 ? "1 item" : "\(count) items" }

    /// How big one file is: its bytes, or for a folder what it holds.
    public static func sizeText(of fact: FileFact) -> String? {
        if let bytes = fact.bytes { return byteText(bytes) }
        return fact.items.map(itemsText)
    }

    /// What the files weigh together, or nil when that cannot be said
    /// honestly: some are not known yet, a folder has no size here, or the
    /// facts stop short of the copy (only a dozen are kept).
    public static func totalBytes(of facts: [FileFact], itemCount: Int) -> Int? {
        guard !facts.isEmpty, facts.count == itemCount else { return nil }
        var total = 0
        for fact in facts {
            guard let bytes = fact.bytes else { return nil }
            total += bytes
        }
        return total
    }

    /// Whether every file of a card is gone. `present` is the answer per
    /// file, nil until asked; one that is still there, or not yet known,
    /// keeps the card as it is.
    public static func allMissing(_ present: [Bool]?) -> Bool {
        guard let present, !present.isEmpty else { return false }
        return present.allSatisfy { !$0 }
    }

    /// The foot's right side: size and age for several files, kind and size
    /// and age for one (`withKind` false drops the kind, which is what gives
    /// way first on a card too narrow for it), and "Missing" alone when
    /// every file is gone, since there is nothing left to describe.
    public static func fileCaption(of clip: Clip, age: String, withKind: Bool = true,
                                   missing: Bool = false) -> String {
        if missing { return "Missing" }
        guard let facts = clip.fileFacts, !facts.isEmpty else { return Caption.line([age]) }
        if clip.itemCount > 1 {
            return Caption.line([totalBytes(of: facts, itemCount: clip.itemCount).map(byteText), age])
        }
        let fact = facts[0]
        return Caption.line([withKind ? fact.kind : nil, sizeText(of: fact), age])
    }

    /// The line under a file opened large: its name, the folder it sits in,
    /// what kind it is, how big, and the one line more (pages, pixels,
    /// minutes), as they were when it was copied. Before the file has been
    /// read the name is the card's own and the rest is left out.
    public static func fileDoorCaption(of clip: Clip) -> String {
        let fact = clip.fileFacts?.first
        return Caption.line([fact?.name ?? namesOnCard(of: clip).first, fact?.folder, fact?.kind,
                             fact.flatMap(sizeText), fact?.detail])
    }

    /// What VoiceOver says a file card holds.
    public static func fileSpeech(of clip: Clip, missing: Bool = false) -> String {
        let count = clip.itemCount
        let names = namesOnCard(of: clip)
        var said: String
        if count == 1 {
            let fact = clip.fileFacts?.first
            said = Caption.line(["File " + (names.first ?? "copied"), fact.map { "in " + $0.folder }, fact?.kind,
                                 fact?.detail])
        } else {
            let lines = nameLines(names: names, total: count)
            said = "\(count) files" + (lines.isEmpty ? "" : ": " + lines.map(\.text).joined(separator: ", "))
        }
        if missing { said += ", missing" }
        return said
    }

    // MARK: - The line under a file's name

    public static func pagesDetail(_ pages: Int) -> String? {
        pages > 0 ? (pages == 1 ? "1 page" : "\(pages) pages") : nil
    }

    public static func dimensionsDetail(width: Int, height: Int) -> String? {
        width > 0 && height > 0 ? "\(width) × \(height)" : nil
    }

    /// Minutes and seconds ("0:42"), with hours when there are some
    /// ("1:02:03"). Whole seconds, rounded down: a clip of 59.9 seconds
    /// has not yet run a minute.
    public static func durationDetail(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let whole = Int(seconds)
        let (hours, minutes, rest) = (whole / 3600, whole % 3600 / 60, whole % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest)
                         : String(format: "%d:%02d", minutes, rest)
    }
}
