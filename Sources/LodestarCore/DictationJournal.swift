import Foundation

/// What dictation heard and what it did with it, kept for a few days to
/// make it better: the one record in Lodestar that holds words, so only a
/// development build keeps it (`forThisBuild`), never a release. It is an
/// instrument for the person making dictation better, not a feature.
///
/// One line a dictation, in a folder of its own: each phrase the live
/// recognizer settled and what the pipeline made of it, each time the
/// second ear heard the run again and whether its words went in, and the
/// text that left — so what the hand changed before sending is the
/// difference between the last of the machine's text and that. Owner-only,
/// out of backups, and every file older than the days kept is deleted, at
/// launch and with each write.
public final class DictationJournal: @unchecked Sendable {
    public let folder: URL
    public let days: Int
    private let lock = NSLock()
    private var current: [String: Any]?
    private var events: [[String: Any]] = []

    /// Two weeks in a development build (one stamped `LodestarDevelopment`
    /// by scripts/dev-build.sh), or the days `LODESTAR_JOURNAL_DAYS` says;
    /// none in a release.
    public static func forThisBuild(bundle: Bundle = .main,
                                    environment: [String: String] = ProcessInfo.processInfo.environment) -> DictationJournal? {
        if let days = environment["LODESTAR_JOURNAL_DAYS"].flatMap(Int.init) {
            return days > 0 ? DictationJournal(days: days) : nil
        }
        guard bundle.object(forInfoDictionaryKey: "LodestarDevelopment") as? Bool == true else { return nil }
        return DictationJournal(days: 14)
    }

    public init(folder: URL = Paths.data.appendingPathComponent("dictation-journal", isDirectory: true), days: Int) {
        self.folder = folder
        self.days = days
        prune(now: Date())
    }

    /// A dictation begins, going to `app`.
    public func begin(app: String?, at now: Date) {
        lock.lock()
        defer { lock.unlock() }
        current = ["began": Self.stamp(now), "app": app ?? NSNull()]
        events = []
    }

    /// A phrase the live recognizer settled, and the words that landed.
    public func heard(_ heard: Heard, landed: String, at now: Date) {
        add(["kind": "heard", "at": Self.stamp(now), "text": heard.text, "landed": landed,
             "start": heard.start ?? NSNull(), "end": heard.end ?? NSNull()])
    }

    /// The second ear heard the run again: what it heard, what stood, and
    /// what went in (nil when nothing did).
    public func earHeard(_ ear: String, heard: String, stood: String, placed: String?, seconds: Double, at now: Date) {
        add(["kind": "ear", "at": Self.stamp(now), "ear": ear, "heard": heard, "stood": stood,
             "placed": placed ?? NSNull(), "ms": Int(seconds * 1000)])
    }

    /// The intent pass: what was sent, the model's answer, what went in
    /// (nil when nothing did) and, when the checker refused, why.
    public func intent(sent: String, answer: String?, placed: String?, refused: String?, seconds: Double, at now: Date) {
        add(["kind": "intent", "at": Self.stamp(now), "sent": sent, "answer": answer ?? NSNull(),
             "placed": placed ?? NSNull(), "refused": refused ?? NSNull(), "ms": Int(seconds * 1000)])
    }

    /// Any other step worth seeing: a pass that changed the text.
    public func note(_ kind: String, before: String, after: String, at now: Date) {
        add(["kind": kind, "at": Self.stamp(now), "before": before, "after": after])
    }

    /// The dictation ended: how, and the text that left.
    public func finish(_ outcome: String, text: String, at now: Date) {
        lock.lock()
        guard var entry = current else { lock.unlock(); return }
        entry["ended"] = Self.stamp(now)
        entry["outcome"] = outcome
        entry["text"] = text
        entry["events"] = events
        current = nil
        events = []
        lock.unlock()
        // A dictation that heard nothing has nothing to learn from.
        guard (entry["events"] as? [Any])?.isEmpty == false else { return }
        write(entry, now: now)
    }

    private func add(_ event: [String: Any]) {
        lock.lock()
        if current != nil { events.append(event) }
        lock.unlock()
    }

    private func write(_ entry: [String: Any], now: Date) {
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        Paths.excludeFromBackup(folder)
        let file = folder.appendingPathComponent(Self.day(now) + ".jsonl")
        let line = data + Data("\n".utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: file)
            Paths.restrict(file)
        }
        prune(now: now)
    }

    /// Delete every day older than the days kept.
    public func prune(now: Date) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        let oldest = Self.day(now.addingTimeInterval(-Double(max(0, days)) * 86_400))
        for name in names where name.hasSuffix(".jsonl") && String(name.dropLast(6)) < oldest {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
