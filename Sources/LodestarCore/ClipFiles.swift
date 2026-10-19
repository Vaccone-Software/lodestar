import Foundation

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

        public init(name: String, folder: String, kind: String, type: String? = nil,
                    bytes: Int? = nil, items: Int? = nil, detail: String? = nil, pictured: Bool? = nil) {
            self.name = name
            self.folder = folder
            self.kind = kind
            self.type = type
            self.bytes = bytes
            self.items = items
            self.detail = detail
            self.pictured = pictured
        }
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

    /// Whether a copied file is still there to paste. The Finder names a
    /// copied file by reference, so its address follows the file wherever
    /// it goes: moved, the card follows it; deleted, the address leads into
    /// the Trash, and a file in the Trash is gone to the hand that deleted
    /// it (the Finder will not paste it either, and makes a text clipping
    /// of its name instead).
    public static func isStillThere(_ url: URL, exists: (String) -> Bool) -> Bool {
        !isInTrash(url) && exists(url.path)
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
    public static func moreLine(_ count: Int) -> String { "and \(count) more" }

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
