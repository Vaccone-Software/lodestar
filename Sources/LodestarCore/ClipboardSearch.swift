import Foundation

/// What a strip search reads of each clip, folded once and kept, so that a
/// keystroke only compares bytes.
///
/// The search had been folding case on every keystroke: Foundation's
/// case-insensitive `range(of:)` folds the whole preview by Unicode rules
/// each time it looks, and the fuzzy tier built an array of characters
/// from every preview that survived the gate. Over a real history of 2,780
/// clips (832 thousand characters) a two-letter query cost about 120 ms,
/// 88 of them in that one call. Here each clip is folded the first time it
/// is searched — ASCII capitals to lowercase, every other byte as it is —
/// and every stage of a query in ASCII (nearly every query typed) runs on
/// those bytes: the in-order gate, the literal hit by `memmem`, and the
/// letters-in-order score. A query outside ASCII keeps the Unicode path,
/// which folds what bytes cannot.
///
/// A clip's key is found by its id and kept while its text is the same,
/// so a clip edited in the door is folded again, and keys for clips the
/// history has dropped are cleared as the cache outgrows the history.
public final class ClipboardSearchIndex {
    struct Key {
        let preview: String
        /// The preview's bytes, ASCII capitals folded. The bytes as copied
        /// are read from the preview itself when the letters-in-order
        /// score wants a capital, so the index holds one copy, not two:
        /// a full history is twenty megabytes of text.
        let folded: [UInt8]
        let ascii: Bool
        /// A color's name, folded: a search for "orange" finds the orange
        /// that was copied as a hex.
        let name: [UInt8]?
    }

    private var keys: [String: Key] = [:]

    public init() {}

    func key(for clip: Clipboard.Clip) -> Key {
        if let key = keys[clip.id], key.preview == clip.preview { return key }
        var folded = Array(clip.preview.utf8)
        var ascii = true
        folded.withUnsafeMutableBufferPointer { bytes in
            for i in bytes.indices {
                let byte = bytes[i]
                if byte &- 0x41 < 26 { bytes[i] = byte | 0x20 } else if byte >= 0x80 { ascii = false }
            }
        }
        let key = Key(preview: clip.preview, folded: folded, ascii: ascii,
                      name: clip.color.map { Array($0.name.utf8).map(Self.fold) })
        keys[clip.id] = key
        return key
    }

    public func search(_ clips: [Clipboard.Clip], query: String) -> [Clipboard.Clip] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let recents = Clipboard.recents(clips)
        guard !needle.isEmpty else { return recents }
        defer { if keys.count > clips.count * 2 + 64 { prune(keeping: clips) } }
        let bytes = Array(needle.utf8)
        let ascii = bytes.allSatisfy { $0 < 128 }
        return recents
            .enumerated()
            .compactMap { position, clip -> (Clipboard.Clip, Double, Int)? in
                let score = ascii ? relevance(of: clip, to: bytes, needle: needle)
                                  : Clipboard.relevance(of: clip, to: needle)
                return score.map { (clip, $0, position) }
            }
            .sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 > $1.1 }
            .map(\.0)
    }

    /// `Clipboard.relevance(of:to:)` on the folded bytes, with the same
    /// scores: a literal hit by its position, the page it came from and a
    /// color's name under every literal hit, letters in order under those.
    func relevance(of clip: Clipboard.Clip, to needle: [UInt8], needle text: String) -> Double? {
        let key = key(for: clip)
        var score = Self.textRelevance(key, needle)
        if let host = clip.sourceHost, host.contains(text) { score = max(score ?? 0, Clipboard.hostRelevance) }
        if let name = key.name, Self.find(needle, in: name) != nil {
            score = max(score ?? 0, Clipboard.nameRelevance)
        }
        return score
    }

    static func textRelevance(_ key: Key, _ needle: [UInt8]) -> Double? {
        guard containsInOrder(needle, in: key.folded) else { return nil }
        if let offset = find(needle, in: key.folded) {
            return 1000 - Double(min(characterPosition(offset, in: key), 800)) * 0.5
        }
        guard needle.count >= 2 else { return nil }
        return lettersInOrder(needle, key)
    }

    /// The literal hit's place in characters, as the scorer has always
    /// counted it: the byte offset itself for ASCII text, which is nearly
    /// all of it.
    private static func characterPosition(_ offset: Int, in key: Key) -> Int {
        if key.ascii { return offset }
        let preview = key.preview
        let index = preview.utf8.index(preview.utf8.startIndex, offsetBy: offset)
        return preview.distance(from: preview.startIndex, to: index)
    }

    /// `Fuzzy.score` with no length penalty, walked over bytes: the same
    /// gains, for the start, for a word's start after a space, dash, dot or
    /// underscore, for a capital after a lowercase letter, and for a run.
    static func lettersInOrder(_ needle: [UInt8], _ key: Key) -> Double? {
        var preview = key.preview
        if let score = preview.utf8.withContiguousStorageIfAvailable({ lettersInOrder(needle, key.folded, $0) }) {
            return score
        }
        preview.makeContiguousUTF8()
        return preview.utf8.withContiguousStorageIfAvailable { lettersInOrder(needle, key.folded, $0) } ?? nil
    }

    private static func lettersInOrder(_ needle: [UInt8], _ folded: [UInt8],
                                       _ original: UnsafeBufferPointer<UInt8>) -> Double? {
        var matched = 0, score = 0.0, last = -10
        for i in folded.indices where matched < needle.count && folded[i] == needle[matched] {
            var gain = 1.0
            if i == 0 {
                gain += 3
            } else {
                let previous = folded[i - 1]
                if previous == 0x20 || previous == 0x2D || previous == 0x2E || previous == 0x5F {
                    gain += 2.5
                } else if (0x41...0x5A).contains(original[i]), (0x61...0x7A).contains(original[i - 1]) {
                    gain += 2
                }
            }
            if i == last + 1 { gain += 1.5 }
            score += gain
            last = i
            matched += 1
        }
        guard matched == needle.count else { return nil }
        if folded.starts(with: needle) { score += 2 }
        return score
    }

    /// Each of the needle's bytes found after the last by `memchr`, which
    /// skips to the next occurrence at the speed of memory: the gate that
    /// turns away most of the history reads it once, fast in any build.
    private static func containsInOrder(_ needle: [UInt8], in hay: [UInt8]) -> Bool {
        hay.withUnsafeBufferPointer { (buffer: UnsafeBufferPointer<UInt8>) -> Bool in
            guard let start = buffer.baseAddress else { return false }
            var offset = 0
            for byte in needle {
                let remaining = buffer.count - offset
                guard remaining > 0, let hit = memchr(start + offset, Int32(byte), remaining) else { return false }
                offset = UnsafeRawPointer(start).distance(to: UnsafeRawPointer(hit)) + 1
            }
            return true
        }
    }

    /// The first place `needle` stands in `hay`, by the C library's search.
    static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        return hay.withUnsafeBytes { h in
            needle.withUnsafeBytes { n in
                memmem(h.baseAddress, h.count, n.baseAddress, n.count)
                    .map { h.baseAddress!.distance(to: UnsafeRawPointer($0)) }
            }
        }
    }

    private static func fold(_ byte: UInt8) -> UInt8 { (0x41...0x5A).contains(byte) ? byte + 32 : byte }

    private func prune(keeping clips: [Clipboard.Clip]) {
        let live = Set(clips.map(\.id))
        keys = keys.filter { live.contains($0.key) }
    }
}
