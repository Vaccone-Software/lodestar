import Foundation

/// The clipboard history, extracted pure: what may be recorded, what a clip
/// is, which slot a pin occupies, and what gets trimmed. The effectful half
/// — polling the pasteboard, writing files, synthesizing ⌘V — lives in the
/// app target. Everything here is deterministic and tested.
public enum Clipboard {
    /// What a clip is made of. `plain` is what a bare label pastes; `native`
    /// is what ⇧label pastes — the richest thing the source app offered,
    /// whether that is RTF, HTML, or something only Figma understands.
    public enum Kind: String, Codable, Equatable {
        case text
        case image
        /// A copy of files: every item is a file's address, and the card
        /// shows the files themselves (see `FileFact`), not a path as text.
        case file

        /// A kind this build does not know decodes as text. The index is
        /// one journal, and a clip that will not decode takes the whole
        /// history down with it: an older build meeting a kind a newer one
        /// wrote, or the reverse, must lose a card's look and never the
        /// cards. The raw strings are the file format and never change.
        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .text
        }
    }

    public struct Clip: Codable, Equatable {
        public let id: String
        public let kind: Kind
        public let created: Date
        /// The app that put it on the pasteboard, for recognition.
        public let sourceBundleID: String?
        public let sourceAppName: String?
        /// Rendered on the card and searched against — never the whole clip.
        /// A var, because an image's caption grows once its text has been
        /// read, a beat after the card exists.
        public var preview: String
        /// Bytes on disk across every representation, for the size cap.
        public let bytes: Int
        /// The first item's pasteboard types, stored alongside its plain
        /// form, richest first.
        public let nativeTypes: [String]
        /// Every item after the first, by the types each one carries.
        ///
        /// A copy is not always one thing. Three files selected in Finder
        /// go on the pasteboard as three items, and a clip that kept only
        /// the first pasted one file where three were copied. The shape is
        /// lopsided because the first item's types were on disk under
        /// `nativeTypes` long before the rest were kept, and this decodes
        /// as absent for every clip written back then — a clip that will
        /// not decode takes the whole index down with it.
        public let otherItemTypes: [[String]]?
        /// nil when the clip is not pinned; otherwise its permanent slot.
        public var pinnedSlot: Int?
        /// A keepsake's name, as the hand left it. Absent for a clip that
        /// was never kept, and for one kept before names existed, which
        /// shows the name its first words give it.
        public var keptName: String?
        /// The page a browser copy came from, host only — the address a
        /// hand remembers a clip by, "the one from GitHub" — read from the
        /// source-url type Chromium puts beside every copy. Never the path,
        /// and absent for every clip that did not come from a page.
        public var sourceHost: String?
        /// How long the text is, in lines and characters, so a card can
        /// say when it holds more than it shows. Optional because clips
        /// recorded before the counts existed decode without them and are
        /// counted once, later, off the main thread.
        public var lines: Int?
        public var characters: Int?
        /// What each file of a file copy is, in copy order, so the card
        /// can show it without reading the file again: gathered a beat
        /// after the card exists, off the main thread, and absent for every
        /// clip written before files were a kind of their own.
        public var fileFacts: [FileFact]?

        public init(id: String, kind: Kind, created: Date,
                    sourceBundleID: String?, sourceAppName: String?,
                    preview: String, bytes: Int,
                    nativeTypes: [String] = [], otherItemTypes: [[String]] = [],
                    pinnedSlot: Int? = nil, sourceHost: String? = nil,
                    lines: Int? = nil, characters: Int? = nil, keptName: String? = nil,
                    fileFacts: [FileFact]? = nil) {
            self.id = id
            self.kind = kind
            self.created = created
            self.sourceBundleID = sourceBundleID
            self.sourceAppName = sourceAppName
            self.preview = preview
            self.bytes = bytes
            self.sourceHost = sourceHost
            self.lines = lines
            self.characters = characters
            self.nativeTypes = nativeTypes
            // Absent rather than empty for the single-item copy, which is
            // almost every copy: the index is rewritten on a timer for the
            // life of the app, and a key that says nothing is a key not
            // worth writing ten thousand times.
            self.otherItemTypes = otherItemTypes.isEmpty ? nil : otherItemTypes
            self.pinnedSlot = pinnedSlot
            self.keptName = keptName
            self.fileFacts = fileFacts
        }

        public var isPinned: Bool { pinnedSlot != nil }
        /// Every item's types, first to last — the whole copy, which is
        /// what a paste has to put back.
        public var itemTypes: [[String]] { [nativeTypes] + (otherItemTypes ?? []) }
        public var itemCount: Int { 1 + (otherItemTypes?.count ?? 0) }
        /// Whether pasting this clip must put its files on the board. A
        /// file clip is, and so is a copy of files recorded before files
        /// were a kind, told by every item carrying a file's address. The
        /// plain form of such an item is only the file's name, and pasted
        /// alone it makes a text file of that name in the Finder.
        public var pastesAsFiles: Bool {
            kind == .file || (kind == .text && itemTypes.allSatisfy { $0.contains(Clipboard.fileURLType) })
        }
        /// ⇧label differs from label only when the source offered more than
        /// plain text.
        public var hasNativeForm: Bool { itemTypes.contains { !$0.isEmpty } }
        /// What the card says it is holding, or nil for the ordinary copy
        /// of one thing. Files by name, because a copy of several things
        /// usually is files and "3 files" is what the hand remembers doing.
        public var itemsLabel: String? { Clipboard.itemsLabel(itemTypes: itemTypes) }
        /// A card whose text can be opened in the draft and edited: one
        /// text item that is the text itself. A copy of files carries its
        /// paths as its plain form, and editing a path is not editing the
        /// copy (a file clip is never text, and a text clip recorded before
        /// files had a kind is told by its file-url type); an image has no
        /// text to edit.
        public var isEditable: Bool {
            kind == .text && itemCount == 1 && !nativeTypes.contains(Clipboard.fileURLType)
        }
    }

    // MARK: - How long a clip is

    /// The text's length as the card states it.
    public static func counts(of text: String) -> (lines: Int, characters: Int) {
        var lines = 1
        for character in text where character == "\n" { lines += 1 }
        return (lines, text.count)
    }

    /// What the card shows past its five lines. The card draws about 220
    /// characters, so the badge appears only when the text runs past what
    /// is drawn — and then it says lines for prose and code, characters
    /// for the one long line a URL or a paragraph is. Nil for a card that
    /// shows all of itself, which must stay unadorned: the badge is a
    /// signal, and a signal on every card is furniture.
    public static let cardCharacters = 220
    public static let cardLines = 5

    public static func lengthBadge(lines: Int?, characters: Int?) -> String? {
        guard let lines, let characters else { return nil }
        guard lines > cardLines || characters > cardCharacters else { return nil }
        if lines > 1 { return "\(lines) lines" }
        return "\(compact(characters)) chars"
    }

    /// The badge for a card, from its counts when it has them and from
    /// the preview when it does not — a preview cut at the cap means the
    /// text is at least that long, and the badge says so.
    public static func lengthBadge(for clip: Clip) -> String? {
        // A card of files says how many files, beside its key; it holds no
        // text that could run past five lines.
        guard clip.kind != .file else { return nil }
        if let lines = clip.lines, let characters = clip.characters {
            return lengthBadge(lines: lines, characters: characters)
        }
        guard clip.kind == .text else { return nil }
        let counted = counts(of: clip.preview)
        return lengthBadge(lines: counted.lines, characters: counted.characters)
    }

    static func compact(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 100_000 {
            let tenths = (Double(n) / 100).rounded() / 10
            return tenths == tenths.rounded() ? "\(Int(tenths))k" : String(format: "%.1fk", tenths)
        }
        return "\(n / 1000)k"
    }

    // MARK: - Editing a card

    /// A card replaced in place: the same position, the same pin slot,
    /// the same age. The edit is the card's text, not a new copy, which
    /// is why nothing moves — `merging` would have put it at the top.
    /// A replacement for an id that is not there changes nothing.
    public static func replacing(_ clips: [Clip], id: String, with replacement: Clip) -> [Clip] {
        guard let position = clips.firstIndex(where: { $0.id == id }) else { return clips }
        var out = clips
        var kept = replacement
        kept.pinnedSlot = clips[position].pinnedSlot
        kept.keptName = clips[position].keptName
        out[position] = kept
        return out
    }

    // MARK: - What may be recorded

    /// Pasteboard types that mark content as none of our business. A
    /// password manager sets the concealed type precisely so tools like this
    /// one look away; transient and auto-generated say the same in weaker
    /// words. Recording any of them once is a breach that cannot be undone,
    /// so this is checked before anything is read, let alone written.
    public static let refusedTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
    ]

    /// Password managers, by bundle id, lowercased. Most mark what they
    /// copy as concealed, and that mark is honoured first; but not every
    /// copy out of one carries it — a note, a username, a recovery code —
    /// and none of it belongs in a history. Their copies are refused the
    /// way an excluded app's are, before a byte is read.
    public static let passwordApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.apple.passwords", "com.apple.keychainaccess",
        "com.bitwarden.desktop", "com.lastpass.lastpass", "com.dashlane.dashlanephonefinal",
        "org.keepassxc.keepassxc", "in.sinew.enpass-desktop", "me.proton.pass.electron",
    ]

    /// How many items one copy may bring into the history.
    ///
    /// A copy of a whole folder can put thousands of items on the
    /// pasteboard, and every one of them is a file written, bytes counted,
    /// and an index rewritten on a timer. Past this the copy is left alone
    /// entirely rather than kept in part: a card that pastes some of what
    /// you copied is worse than no card at all, because it looks like it
    /// worked.
    public static let maxItemsPerClip = 32

    public enum Refusal: Equatable {
        case concealed(String)
        case excludedApp(String)
        case excludedPattern(String)
        case tooLarge(Int)
        case tooManyItems(Int)
        case empty
    }

    /// The half of the verdict that can be reached from the pasteboard's
    /// type list and its owner alone — no byte of content required.
    ///
    /// This exists so the caller can honour the promise below literally.
    /// A password manager marks its clip concealed precisely so tools like
    /// this look away, and "look away" has to mean before the read, not
    /// before the write: content pulled into this process has already left
    /// the boundary the mark was asking us to respect.
    public static func refusalBeforeReading(types: [String],
                                            sourceBundleID: String?,
                                            excludedApps: Set<String>,
                                            itemCount: Int = 1) -> Refusal? {
        if let concealed = types.first(where: { refusedTypes.contains($0) }) {
            return .concealed(concealed)
        }
        if let bundleID = sourceBundleID?.lowercased(),
           excludedApps.contains(bundleID) || passwordApps.contains(bundleID) {
            return .excludedApp(bundleID)
        }
        // How many items are on the board is metadata like the rest of
        // this, so the copy nobody can hold faithfully is refused without
        // a byte of it being read either.
        if itemCount > maxItemsPerClip { return .tooManyItems(itemCount) }
        return nil
    }

    /// Everything standing between the pasteboard and the disk. Order is
    /// deliberate: the cheapest and most sensitive checks first, so a
    /// concealed clip is refused before its content is ever examined.
    public static func refusal(types: [String],
                               sourceBundleID: String?,
                               text: String?,
                               bytes: Int,
                               excludedApps: Set<String>,
                               excludedPatterns: [String],
                               maxItemBytes: Int) -> Refusal? {
        if let early = refusalBeforeReading(types: types, sourceBundleID: sourceBundleID,
                                            excludedApps: excludedApps) {
            return early
        }
        if let text, !excludedPatterns.isEmpty,
           let pattern = firstExcludedPattern(in: text, of: excludedPatterns) {
            return .excludedPattern(pattern)
        }
        if bytes > maxItemBytes { return .tooLarge(bytes) }
        if let text, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, bytes == 0 {
            return .empty
        }
        return nil
    }

    /// The first of `patterns` the text contains, without regard to case.
    ///
    /// Foundation's search is the meaning of "contains", and over a copy of
    /// megabytes it is also most of a second of the main thread each, with
    /// the keys held. Where the answer cannot differ — a long text of plain
    /// ASCII and patterns of plain ASCII with no line break in them, where
    /// a character is a byte and folding case is adding 32 to a capital —
    /// the bytes are searched directly. Anything else, and every short
    /// text, takes the search it always had.
    static func firstExcludedPattern(in text: String, of patterns: [String]) -> String? {
        if text.utf8.count >= fastSearchFloor, let bytes = foldedASCII(text) {
            let needles = patterns.map { Array($0.lowercased().utf8) }
            if needles.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 < 0x80 && $0 != 0x0A && $0 != 0x0D } }) {
                let hit = bytes.withUnsafeBytes { hay in
                    needles.firstIndex { needle in
                        needle.withUnsafeBytes { memmem(hay.baseAddress, hay.count, $0.baseAddress, $0.count) != nil }
                    }
                }
                return hit.map { patterns[$0] }
            }
        }
        let haystack = text.lowercased()
        return patterns.first { haystack.contains($0.lowercased()) }
    }

    /// Below this a text is searched the long way: nothing is gained, and
    /// the common copy keeps exactly the behaviour it had.
    static let fastSearchFloor = 65_536

    /// The text's bytes with capitals folded, or nil if any is not ASCII.
    private static func foldedASCII(_ text: String) -> [UInt8]? {
        var bytes = Array(text.utf8)
        var ascii = true
        bytes.withUnsafeMutableBufferPointer { buffer in
            for i in buffer.indices {
                let byte = buffer[i]
                if byte &- 0x41 < 26 { buffer[i] = byte | 0x20 } else if byte >= 0x80 { ascii = false; return }
            }
        }
        return ascii ? bytes : nil
    }

    // MARK: - A restore is not a copy

    /// Types a clipboard manager stamps on the previous contents when it
    /// puts them back after a paste of its own. The bytes are not a new
    /// copy — the card is already in the history — so the list must not
    /// reorder for them: copies reorder, pastes do not, and neither does
    /// a restore. A restore of something the history never saw is still
    /// recorded, because then it is news.
    public static let restoreTypes: Set<String> = ["com.raycast.RestoredType"]

    public static func isRestore(types: [String]) -> Bool {
        types.contains { restoreTypes.contains($0) }
    }

    // MARK: - Where a copy came from

    /// The pasteboard type Chromium browsers put beside a copy, carrying
    /// the page it was made on.
    public static let sourceURLType = "org.chromium.source-url"

    /// The host of a page, as the card shows it and the search reads it:
    /// lowercased, the leading www dropped. Nil for anything that is not
    /// a URL with a host — a path, a fragment, an empty string.
    public static func sourceHost(fromURL string: String?) -> String? {
        guard let string,
              let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    // MARK: - An image says what it shows

    /// An image card's preview: its size, and under it every line the
    /// recognizer read — what a screenshot of an error message is found
    /// by. The size line stays first so a card whose text arrives a beat
    /// later still reads as the same card.
    public static func imagePreview(width: Int, height: Int, text: String? = nil) -> String {
        let head = "image \(width)×\(height)"
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return head }
        return head + "\n" + preview(of: text, limit: 1500)
    }

    /// An image card's caption, arriving a beat after the card: the size
    /// line it already had stays first, so the card is the card it was,
    /// and the text goes under it for the search to read.
    public static func captioned(_ preview: String, with text: String) -> String {
        let head = preview.split(separator: "\n", maxSplits: 1,
                                 omittingEmptySubsequences: false).first.map(String.init) ?? preview
        let body = self.preview(of: text, limit: 1500)
        return body.isEmpty ? head : head + "\n" + body
    }

    // MARK: - Pasting into a search

    /// What ⌘V puts into a search band: the pasteboard's text with every
    /// run of whitespace, newlines included, folded to one space, and cut
    /// to a length a band can hold. A band is one line; a pasted paragraph
    /// searches by its first two hundred characters.
    public static func pastedQuery(_ text: String, limit: Int = 200) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.prefix(limit))
    }

    // MARK: - A copy is its items

    /// The pasteboard's word for a file, which is what a copy of several
    /// things almost always holds.
    public static let fileURLType = "public.file-url"

    /// What a card says it is holding when one copy brought several things,
    /// and nil for the ordinary copy of one thing, which says nothing
    /// because there is nothing to say.
    public static func itemsLabel(itemTypes: [[String]]) -> String? {
        guard itemTypes.count > 1 else { return nil }
        let files = itemTypes.allSatisfy { $0.contains(fileURLType) }
        return "\(itemTypes.count) \(files ? "files" : "items")"
    }

    /// The bytes a copy is named by, so copying the same thing again lands
    /// on the card it already has instead of growing a second one.
    ///
    /// One item is hashed exactly as it always was — every clip already on
    /// disk was named that way, and changing it would give everything in a
    /// user's history a stranger's name the next time they copied it.
    /// Several items are length-prefixed rather than run together, so two
    /// files copied side by side can never hash as their contents joined.
    public static func identityData(items: [Data]) -> Data {
        guard items.count > 1 else { return items.first ?? Data() }
        var joined = Data()
        for item in items {
            var length = UInt64(item.count).littleEndian
            withUnsafeBytes(of: &length) { joined.append(contentsOf: $0) }
            joined.append(item)
        }
        return joined
    }

    // MARK: - Pasting into a terminal

    /// A terminal delivers a paste as bytes down a pty, and a pty has no way
    /// to carry an image — so ⌘V into one can never land a picture, however
    /// rich the pasteboard is.
    ///
    /// What every terminal *does* paste is text, and a path is text. The
    /// tools you run in one read the image back off it: Claude Code turns a
    /// pasted `.png` path into an attachment. So for an image into a
    /// terminal the clip also goes on the pasteboard as a file, and the path
    /// is what ⌘V delivers. Graphical apps never see this — they take the
    /// picture itself, which is what they can actually accept.
    public static let terminalBundleIDs: Set<String> = [
        "com.mitchellh.ghostty",
        "com.googlecode.iterm2",
        "com.apple.terminal",
        "org.alacritty",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "dev.warp.warp-stable",
        "co.zeit.hyper",
        "com.raphaelamorim.rio",
    ]

    /// Only images, and only into a terminal: text pastes down a pty exactly
    /// as it should, so nothing changes for the common case.
    public static func pastesAsFilePath(kind: Kind, frontmostBundleID: String?) -> Bool {
        guard kind == .image, let id = frontmostBundleID?.lowercased() else { return false }
        return terminalBundleIDs.contains(id)
    }

    /// Extensions the far side will recognise as an image. A path only works
    /// if it is named like a picture — the reader checks the extension
    /// before it ever opens the file.
    public static let pasteableImageExtension = "png"

    /// The name Lodestar gives the files it hands to terminals.
    public static let handoverPrefix = "lodestar-"

    /// Is this clip merely one of those paths coming back to us?
    ///
    /// After a terminal paste the pasteboard holds our own file path, so the
    /// next launch — which reads whatever is already on the pasteboard —
    /// would file it as a clip. It is worth nothing to the user, and worse
    /// than nothing once the temp file behind it is pruned and the path
    /// pastes dead.
    public static func isOwnHandoverPath(_ text: String?, temporaryDirectory: String) -> Bool {
        guard let text else { return false }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix(temporaryDirectory) else { return false }
        return (path as NSString).lastPathComponent.hasPrefix(handoverPrefix)
    }

    /// The card's line of text: collapsed whitespace, bounded, so a clip of
    /// a whole file does not become a giant index entry.
    ///
    /// Only the front of the text is read. It is trimmed of whitespace at
    /// both ends, and as many scalars of what is left are folded (CRLF to
    /// LF) as it takes to be sure of the first `limit` characters: the same
    /// line as folding all of it and cutting that, which for 19 MB was most
    /// of half a second of the main thread.
    public static func preview(of text: String, limit: Int = 2000) -> String {
        let scalars = text.unicodeScalars
        let edge = CharacterSet.whitespacesAndNewlines
        guard let start = scalars.firstIndex(where: { !edge.contains($0) }) else { return "" }
        var end = scalars.endIndex
        while end > start {
            let before = scalars.index(before: end)
            guard edge.contains(scalars[before]) else { break }
            end = before
        }
        let kept = scalars[start..<end]
        var count = limit * 4 + 8
        while true {
            let cut = kept.index(kept.startIndex, offsetBy: count, limitedBy: kept.endIndex) ?? kept.endIndex
            let folded = String(kept[kept.startIndex..<cut]).replacingOccurrences(of: "\r\n", with: "\n")
            // All of the text, or enough of it that the cut cannot have
            // changed the first `limit` characters: a cut between a CR and
            // the LF after it leaves the last two characters other than
            // they will be (a CR before "\r\n" folds into a CRLF of its
            // own), and nothing before them is touched.
            if cut == kept.endIndex || folded.count >= limit + 2 { return String(folded.prefix(limit)) }
            count *= 2
        }
    }

    /// ⌥⌫ — drop the last word, and any whitespace trailing it, the way
    /// every macOS text field does: "a big cat " and "a big cat" both
    /// become "a big ".
    public static func droppingLastWord(_ query: String) -> String {
        var remaining = Substring(query)
        while let last = remaining.last, last.isWhitespace { remaining = remaining.dropLast() }
        while let last = remaining.last, !last.isWhitespace { remaining = remaining.dropLast() }
        return String(remaining)
    }

    /// How long ago, in the shortest honest form. You reach for old clips
    /// temporally — "the one from this morning" — and a preview alone
    /// cannot say that. "Ago" is the word that makes the letter mean
    /// something to a hand that has never seen the card: "3m" could be
    /// a size; "3m ago" is a time.
    public static func age(of clip: Clip, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(clip.created))
        if seconds < 45 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    /// The recents alphabet, in rank order: the newest under the right
    /// index finger, then out along the right hand, then the left hand's
    /// from its index finger out. Keep opens with the left hand, so the
    /// right takes the clips it most often wants, and each card stands
    /// over the key that pastes it. Ordinal, unlike the hints alphabet,
    /// whose labels are arbitrary assignments to screen positions.
    public static let recentLabels = Array("jkl;fdsa").map(String.init)

    // MARK: - Keepsakes

    /// Keepsakes are places, not a list. A place's meaning must never
    /// change, or the blind paste they exist for never becomes automatic.
    /// Four, on the number keys over the left hand's four fingers.
    public static let pinSlots = 4

    /// Where the next keepsake goes: the highest free place, so the first
    /// thing kept sits on 4 under the index finger and the little finger
    /// gets the place most often free. Letting one go leaves a hole; the
    /// others never move.
    public static func nextFreeSlot(taken: Set<Int>, slots: Int = pinSlots) -> Int? {
        (1...slots).reversed().first { !taken.contains($0) }
    }

    /// Places outside the four, from when there were five, settled once:
    /// each moves to the highest free place, and one with nowhere to go
    /// stops being a keepsake and stays in the history as a clip. Two
    /// clips claiming one place keep the first.
    public static func settlingSlots(_ clips: [Clip], slots: Int = pinSlots) -> [Clip] {
        var out = clips
        var taken = Set<Int>()
        var homeless: [Int] = []
        for index in out.indices {
            guard let slot = out[index].pinnedSlot else { continue }
            if (1...slots).contains(slot), taken.insert(slot).inserted { continue }
            homeless.append(index)
        }
        for index in homeless {
            let slot = nextFreeSlot(taken: taken, slots: slots)
            out[index].pinnedSlot = slot
            if let slot { taken.insert(slot) } else { out[index].keptName = nil }
        }
        return out
    }

    /// A keepsake's name, offered when it is kept: its first words, as
    /// many as fit a short name, never cut inside a word. An image is
    /// named by what was read off it, or simply "Image".
    public static func offeredName(for clip: Clip, limit: Int = 24) -> String {
        if clip.kind == .file {
            // The first file's name, not the start of its path.
            let first = clip.fileFacts?.first?.name
                ?? clip.preview.split(separator: "\n").first.map { ($0 as NSString).lastPathComponent }
            return first.map { offeredName(fromText: $0, limit: limit) } ?? "Files"
        }
        if clip.kind == .image {
            // Under the size line, whatever the recognizer read.
            let lines = clip.preview.split(separator: "\n", maxSplits: 1)
            let caption = lines.count > 1 ? String(lines[1]) : ""
            return caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Image" : offeredName(fromText: caption, limit: limit)
        }
        return offeredName(fromText: clip.preview, limit: limit)
    }

    static func offeredName(fromText raw: String, limit: Int) -> String {
        // A name is drawn whole and spoken aloud, so it never holds a
        // secret: only the words before the first one count, and a clip
        // that opens on a secret is called what it is.
        var text = raw
        if let first = ClipSecret.spans(in: raw).first {
            text = (raw as NSString).substring(to: first.range.location)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Secret" }
        }
        let words = text.split(whereSeparator: { $0.isWhitespace })
        var name = ""
        for word in words {
            let next = name.isEmpty ? String(word) : name + " " + word
            if next.count > limit { break }
            name = next
        }
        if name.isEmpty, let first = words.first { name = String(first.prefix(limit)) }
        return name.isEmpty ? "Keepsake" : name
    }

    /// The name a keepsake shows: the hand's, or the one its words give.
    public static func name(of clip: Clip) -> String {
        clip.keptName ?? offeredName(for: clip)
    }

    // MARK: - Retention

    /// What to drop, oldest first, until the store fits. Pins are exempt
    /// entirely — that is most of what pinning means.
    ///
    /// Two ceilings: the bytes the user chose, and an item count they never
    /// see. The count is a guard on the design rather than on them — the
    /// index is held in memory and rewritten on a coalesced timer, and a
    /// byte cap alone does not bound how many text clips fit under it.
    public static func trim(_ clips: [Clip],
                            maxBytes: Int,
                            maxItems: Int) -> [String] {
        let pinned = clips.filter(\.isPinned)
        var loose = clips.filter { !$0.isPinned }.sorted { $0.created > $1.created }

        var doomed: [String] = []
        if loose.count > maxItems {
            doomed += loose[maxItems...].map(\.id)
            loose = Array(loose[..<maxItems])
        }
        // Pinned bytes count toward the ceiling but can never be evicted, so
        // the loose clips absorb the whole overage.
        var total = pinned.reduce(0) { $0 + $1.bytes } + loose.reduce(0) { $0 + $1.bytes }
        while total > maxBytes, let oldest = loose.popLast() {
            doomed.append(oldest.id)
            total -= oldest.bytes
        }
        return doomed
    }

    /// Copying the same thing again is a new copy: it rises to the top and
    /// the source updates. Pasting never reorders — the list is your copy
    /// history, which is the only reading that stays true while you use it.
    ///
    /// The id is the content, so what was already read off it is still true:
    /// the card keeps its preview — an image's caption above all, which the
    /// arrival cannot have yet, a recognizer pass being most of a second —
    /// and its counts. Left to the arrival, a re-copied screenshot lost the
    /// words it was found by until the recognizer came back.
    public static func merging(_ existing: [Clip], with arrival: Clip) -> [Clip] {
        var out = existing
        if let index = out.firstIndex(where: { $0.id == arrival.id }) {
            let known = out[index]
            out.remove(at: index)
            var promoted = arrival
            promoted.pinnedSlot = known.pinnedSlot
            promoted.keptName = known.keptName
            if known.kind == arrival.kind {
                promoted.preview = known.preview
                promoted.lines = known.lines ?? arrival.lines
                promoted.characters = known.characters ?? arrival.characters
                // The files are read again after every copy, and until that
                // lands the card is the card it was.
                promoted.fileFacts = arrival.fileFacts ?? known.fileFacts
            }
            out.insert(promoted, at: 0)
            return out
        }
        out.insert(arrival, at: 0)
        return out
    }

    /// Newest first, pins excluded — pins have their own zone and their own
    /// addresses, so a pinned clip never also occupies a recent card.
    ///
    /// No sort: `merging` inserts every arrival at the front, so the list
    /// is newest-first by construction, and this runs on every keystroke
    /// of a strip search over a history capped at ten thousand. A test
    /// stands on the invariant so a future merge cannot quietly break it.
    public static func recents(_ clips: [Clip]) -> [Clip] {
        clips.filter { !$0.isPinned }
    }

    public static func pins(_ clips: [Clip]) -> [Clip] {
        clips.filter(\.isPinned).sorted { ($0.pinnedSlot ?? 0) < ($1.pinnedSlot ?? 0) }
    }

    /// How many of the recents each app copied, by the name its cards wear:
    /// what the source list counts. Keepsakes are not counted, and neither
    /// is a clip that never said where it came from.
    public static func sourceCounts(_ clips: [Clip]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for clip in clips where !clip.isPinned {
            if let name = clip.sourceAppName { counts[name, default: 0] += 1 }
        }
        return counts
    }

    /// How well a clip answers a query, or nil when it does not.
    ///
    /// Two tiers, because they mean different things. A literal hit is what
    /// you typed, sitting in the text — the strongest possible signal, and
    /// the earlier it sits the more the clip is *about* it. Failing that,
    /// the letters in order: this is what lets "gitcom" find a commit
    /// command, which is the whole reason to want more than substring.
    ///
    /// A subsequence over long text is permissive by nature, so it is scored
    /// far below any literal hit rather than mixed in with one. It also
    /// wants two characters: a single letter appears in order in nearly
    /// every clip ever copied, which is noise rather than a search.
    /// `needle` must already be lowercased and trimmed.
    public static func relevance(of preview: String, to needle: String) -> Double? {
        guard !needle.isEmpty else { return 0 }
        // One cheap pass gates both tiers: a literal hit is necessarily also
        // a subsequence, so anything this rejects cannot match either way.
        // It is what keeps the expensive search off the 99% of clips that
        // have nothing to do with the query. Only for an ASCII needle —
        // byte folding is not Unicode case folding, and the correct search
        // below is worth its cost on the rare query that needs it.
        let ascii = isASCII(needle)
        if ascii, !containsInOrder(needle, in: preview) { return nil }
        if let position = literalPosition(of: needle, in: preview) {
            return 1000 - Double(min(position, 800)) * 0.5
        }
        // An ASCII needle that reached this line already passed the gate's
        // scan, and a non-ASCII needle never owed it one — byte folding is
        // not Unicode case folding, and a gate that cannot fold Ü would
        // veto the very match the scorer below exists to find.
        guard needle.count >= 2 else { return nil }
        // Only the survivors pay for scoring. No length penalty either: a
        // clip is not worse for being long. The preview goes in as copied —
        // the scorer folds case once itself.
        return Fuzzy.score(query: needle, candidate: preview, lengthPenalty: 0)
    }

    /// Foundation's search, deliberately. A hand-rolled byte scan looked
    /// tempting for the hot loop, but a single-pointer one is wrong on
    /// repeats — it cannot find "aab" inside "aaab", because the failed
    /// third byte has already consumed the second "a" the match needed —
    /// and getting that right means KMP for a gain that measurement did not
    /// support. This allocates nothing over the haystack, and the cheap
    /// subsequence reject below is what actually keeps the loop fast.
    private static func literalPosition(of needle: String, in hay: String) -> Int? {
        guard let hit = hay.range(of: needle, options: [.caseInsensitive]) else { return nil }
        return hay.distance(from: hay.startIndex, to: hit.lowerBound)
    }

    /// Byte-wise, ASCII-folded, allocation free — and correct greedily,
    /// unlike substring: a subsequence never needs to give back a character
    /// it has already matched.
    ///
    /// This is the hot loop. It runs against every clip on every keystroke,
    /// and a history is capped at ten thousand previews of up to two
    /// thousand characters. Reaching `lowercased()` and `Array(candidate)`
    /// first — building two grapheme-cluster arrays per clip merely to
    /// discover it does not match — measured 3.6s on a full history.
    private static func isASCII(_ text: String) -> Bool {
        text.utf8.allSatisfy { $0 < 128 }
    }

    private static func containsInOrder(_ needle: String, in hay: String) -> Bool {
        let n = Array(needle.utf8)
        var matched = 0
        for byte in hay.utf8 {
            let folded = (byte >= 65 && byte <= 90) ? byte + 32 : byte
            if folded == n[matched] {
                matched += 1
                if matched == n.count { return true }
            }
        }
        return false
    }

    /// A host hit's score: under every literal hit in the preview, which
    /// is what you typed sitting in the text, and above a letters-in-order
    /// match, which is a guess.
    static let hostRelevance = 550.0
    /// A color's name — "orange" finds the orange copied as a hex — is
    /// scored as the page is: what the clip is, not what it says.
    static let nameRelevance = hostRelevance

    /// How well a clip answers a query: its preview first, and then the
    /// page it came from — "github" finds the clips copied on GitHub even
    /// when none of them says so.
    public static func relevance(of clip: Clip, to needle: String) -> Double? {
        let text = relevance(of: clip.preview, to: needle)
        var score = text
        if let host = clip.sourceHost, !needle.isEmpty, host.contains(needle) {
            score = max(score ?? 0, hostRelevance)
        }
        if !needle.isEmpty, let name = clip.color?.name.lowercased(), name.contains(needle) {
            score = max(score ?? 0, nameRelevance)
        }
        return score
    }

    /// Newest-first among equals, so an untyped strip and a searched one
    /// order the same way and the labels stay where the eye expects them.
    /// The strip keeps one index for the life of the app, so each clip is
    /// folded once; a caller without one gets a fresh index, which folds
    /// what it searches and gives the same answer.
    public static func search(_ clips: [Clip], query: String,
                              index: ClipboardSearchIndex = ClipboardSearchIndex()) -> [Clip] {
        index.search(clips, query: query)
    }
}

// MARK: - Saving an image

public extension Clipboard {
    /// What an image is written as, decided by the name's extension. The
    /// three every Mac app reads; anything else is treated as part of the
    /// name and the file is a PNG.
    enum ImageFormat: String, Equatable {
        case png, jpeg, tiff

        public static func forExtension(_ ext: String) -> ImageFormat? {
            switch ext.lowercased() {
            case "png": return .png
            case "jpg", "jpeg": return .jpeg
            case "tif", "tiff": return .tiff
            default: return nil
            }
        }
    }

    /// The name offered for an image being saved: where it came from and
    /// when, the way macOS names a screenshot. "github.com 2026-09-06 at
    /// 12.04.31.png" is found again by the host and sorts by time; a
    /// stamp alone is found by nothing.
    static func imageFileName(for clip: Clip, timeZone: TimeZone = .current) -> String {
        let source = (clip.sourceHost ?? clip.sourceAppName ?? "Image")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: clip.created)
        return "\(source.isEmpty ? "Image" : source) \(stamp).png"
    }

    /// Where a typed name lands. Nothing typed takes the offered name in
    /// the folder; a leading `/` or `~` is an absolute path; a slash
    /// inside the name is a subfolder of the folder; a trailing slash is
    /// a folder that takes the offered name. A name with no image
    /// extension gets `.png`, so "v1.2" is "v1.2.png" and never a file
    /// nothing opens.
    static func saveDestination(typed: String, offered: String, folder: String,
                                home: String) -> String {
        var name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = offered }
        if name.hasSuffix("/") { name += offered }
        let expanded = expandingHome(name, home: home)
        let path: String
        if expanded.hasPrefix("/") {
            path = expanded
        } else {
            path = expandingHome(folder, home: home) + "/" + expanded
        }
        var parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if let last = parts.last {
            let ext = (last as NSString).pathExtension
            if ImageFormat.forExtension(ext) == nil { parts[parts.count - 1] = last + ".png" }
        }
        return "/" + parts.joined(separator: "/")
    }

    static func expandingHome(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst() }
        return path
    }

    /// The format a destination is written in.
    static func saveFormat(of path: String) -> ImageFormat {
        ImageFormat.forExtension((path as NSString).pathExtension) ?? .png
    }

    /// The folder a destination lands in, said the short way a flash can
    /// carry: the home folder's child by name, anything deeper by its
    /// last component.
    static func folderName(of path: String, home: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        if folder == home { return "home" }
        return (folder as NSString).lastPathComponent
    }
}

// MARK: - The reading, as a paste

public extension Clipboard {
    /// What `⌃` and a card's key paste: Lodestar's reading of the card, in
    /// the words the card's note leads with, or nil when the card has none.
    /// A colour pastes its name, a time the moment in your own zone, a
    /// measurement its conversion (exact where the note carries an exact
    /// line), a column its sum. The card shows this same text while `⌃`
    /// is held, so what is seen is what pastes.
    static func reading(of clip: Clip, units: ClipQuantity.System,
                        zones: [TimeZone] = [], now: Date = Date()) -> String? {
        if let color = clip.color { return color.name }
        if let time = clip.time { return time.note(zones: zones, now: now).local }
        if let read = clip.quantity?.note(into: units) { return read.exact ?? read.voice }
        if let sum = clip.sum { return sum.voice() }
        return nil
    }
}
