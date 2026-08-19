import AppKit
import Foundation
import LodestarCore

/// Installed + running applications, searchable for the searcher.
final class AppIndex {
    struct Entry {
        let name: String
        let url: URL
        var isRunning: Bool
        var pid: pid_t?
        var bundleID: String?
    }

    private(set) var entries: [Entry] = []
    private var lastScan = Date.distantPast
    private var scanning = false
    /// Resolved icons, living exactly as long as the entries they came from.
    private var icons: [String: NSImage?] = [:]

    /// Frecency boost injected by the state store — usage ranks the results.
    var usageBoost: (String?) -> Double = { _ in 0 }

    private static let roots = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    /// A stale index refreshes off the main thread — the disk walk reads
    /// ~150 Info.plists, and the searcher's first keystroke after idle must
    /// not pay for it. Queries keep the current entries until the swap.
    func refreshIfStale() {
        guard Date().timeIntervalSince(lastScan) > 30, !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = AppIndex.scanDisk()
            DispatchQueue.main.async {
                guard let self else { return }
                self.entries = AppIndex.mergeRunning(into: found)
                self.icons.removeAll()
                self.lastScan = Date()
                self.scanning = false
            }
        }
    }

    /// Synchronous full scan — the boot path, before any panel exists.
    func refresh() {
        entries = AppIndex.mergeRunning(into: AppIndex.scanDisk())
        icons.removeAll()
        lastScan = Date()
    }

    /// An app's icon, resolved once per index.
    ///
    /// This sits on the chain guide's path, and `showGuide` draws that
    /// synchronously inside the event tap — so every letter of every chain
    /// was paying, per row, for a name lookup (a fuzzy rank across every app
    /// on the machine whenever the name is not an exact hit) and a
    /// LaunchServices icon load. Measured on a working machine at 3.5ms per
    /// icon cold and 0.24ms warm: a twelve-row guide cost about 42ms the
    /// first time and ~3ms every time after, inside the callback that holds
    /// the keyboard for every app on the machine.
    ///
    /// A miss is cached too, or an unresolvable name repeats the fuzzy rank
    /// forever. The whole table is dropped whenever `entries` is replaced,
    /// which is the only moment an icon here can have gone stale.
    func icon(named name: String) -> NSImage? {
        if let cached = icons[name] { return cached }
        let resolved = entry(named: name).map { NSWorkspace.shared.icon(forFile: $0.url.path) }
        icons[name] = resolved
        return resolved
    }

    private static func scanDisk() -> [String: Entry] {
        let fm = FileManager.default
        var found: [String: Entry] = [:]
        for root in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for item in names where item.hasSuffix(".app") {
                let path = root + "/" + item
                let url = URL(fileURLWithPath: path)
                let display = fm.displayName(atPath: path)
                let name = display.hasSuffix(".app") ? String(display.dropLast(4)) : display
                found[name.lowercased()] = Entry(
                    name: name, url: url, isRunning: false, pid: nil,
                    bundleID: Bundle(url: url)?.bundleIdentifier
                )
            }
        }
        return found
    }

    private static func mergeRunning(into scanned: [String: Entry]) -> [Entry] {
        var found = scanned
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let name = app.localizedName else { continue }
            let key = name.lowercased()
            if var entry = found[key] {
                entry.isRunning = true
                entry.pid = app.processIdentifier
                entry.bundleID = app.bundleIdentifier ?? entry.bundleID
                found[key] = entry
            } else if let url = app.bundleURL {
                found[key] = Entry(
                    name: name, url: url, isRunning: true,
                    pid: app.processIdentifier, bundleID: app.bundleIdentifier
                )
            }
        }
        return Array(found.values)
    }

    /// Best matches for a query. Empty query = what you actually use, by
    /// frecency; otherwise fuzzy score + frecency boost.
    func query(_ text: String, limit: Int = 8) -> [Entry] {
        refreshIfStale()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            // Boost once per entry, not once per comparison.
            let boosted = entries.map { (entry: $0, boost: usageBoost($0.bundleID)) }
            let ranked = boosted.sorted { a, b in
                if a.boost != b.boost { return a.boost > b.boost }
                if a.entry.isRunning != b.entry.isRunning { return a.entry.isRunning }
                return a.entry.name.lowercased() < b.entry.name.lowercased()
            }
            return Array(ranked.prefix(limit).map(\.entry))
        }
        let scored = entries.compactMap { entry -> (Entry, Double)? in
            guard let score = Fuzzy.score(query: trimmed, candidate: entry.name) else { return nil }
            return (entry, score + usageBoost(entry.bundleID))
        }
        return Array(scored.sorted { $0.1 > $1.1 }.map(\.0).prefix(limit))
    }

    func entry(named name: String) -> Entry? {
        refreshIfStale()
        let lowered = name.lowercased()
        if let exact = entries.first(where: { $0.name.lowercased() == lowered }) { return exact }
        return Fuzzy.rank(query: name, candidates: entries, key: \.name).first
    }
}
