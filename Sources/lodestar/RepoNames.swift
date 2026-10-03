import ApplicationServices
import Foundation
import LodestarCore

/// The names of the code being talked about, for the draft to write as the
/// code does: "draft controller dot swift" → `DraftController.swift`.
///
/// Only where code is written — a terminal or a code editor in front — and
/// only from the repository its window is in: the folder the window shows
/// as its document (`AXDocument`, which Ghostty sets to the shell's folder
/// and editors to the open file), up to the folder holding `.git`. The
/// names are the repository's own files, the symbols its source declares,
/// and its branches; nothing is kept but the list, which lives in memory
/// and is read again after ten minutes.
enum RepoNames {
    /// Terminals and editors, by bundle identifier.
    static let codeApps: Set<String> = [
        "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.apple.dt.Xcode",
        "com.panic.Nova", "com.sublimetext.4", "com.jetbrains.intellij", "com.exafunction.windsurf",
    ]

    /// The repository the app's focused window is in, when the app is
    /// where code is written.
    static func repository(pid: pid_t, bundleID: String?) -> URL? {
        guard let bundleID, codeApps.contains(bundleID) else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let window = AX.element(app, kAXFocusedWindowAttribute as String),
              let document = AX.string(window, kAXDocumentAttribute as String),
              let url = URL(string: document), url.isFileURL else { return nil }
        var folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) { return folder }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path || folder.standardizedFileURL.path == home { return nil }
            folder = parent
        }
        return nil
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (at: Date, index: CodeNames.Index)] = [:]
    private static let freshFor: TimeInterval = 600

    /// The repository's names, read off the main thread when they are not
    /// already fresh; `done` runs on the main thread.
    static func index(for root: URL, done: @escaping (CodeNames.Index?) -> Void) {
        lock.lock()
        let cached = cache[root.path]
        lock.unlock()
        if let cached, Date().timeIntervalSince(cached.at) < freshFor { done(cached.index); return }
        DispatchQueue.global(qos: .utility).async {
            let began = Date()
            let names = CodeNames.gather(root)
            let index = CodeNames.Index(names: names, pronouncer: DictationLexicon.pronouncer)
            lock.lock()
            cache[root.path] = (Date(), index)
            lock.unlock()
            Log.info("draft", ["code names": index.count, "repository": root.lastPathComponent,
                               "ms": Int(Date().timeIntervalSince(began) * 1000)])
            DispatchQueue.main.async { done(index) }
        }
    }
}
