import Foundation
import LodestarCore

/// Lodestar's alert sound, kept where Sound settings looks.
///
/// The strike is part of Lodestar's identity, so the app keeps a copy in
/// ~/Library/Sounds at every boot: missing, it is placed; changed by a
/// release, it is replaced. Whether the Mac's alert names it stays the
/// person's choice in Sound settings, and Lodestar never makes that
/// choice for them. Leaving, Lodestar takes the file with it and, when
/// the alert still named it, hands the alert back to the Mac's default.
enum AlertSound {
    static let name = "Lodestar"
    /// The global default that names the alert sound by path.
    static let selectionKey = "com.apple.sound.beep.sound"

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Sounds", isDirectory: true)
    }
    static var installed: URL { directory.appendingPathComponent("\(name).aiff") }

    /// The bundle's copy, or under `swift build`, which has no bundle,
    /// the packaging folder the app would have copied it from.
    static var bundled: URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "aiff") { return url }
        #if DEBUG
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dev = root.appendingPathComponent("packaging/\(name).aiff")
        if FileManager.default.fileExists(atPath: dev.path) { return dev }
        #endif
        return nil
    }

    /// Keep the installed copy current. Returns what was done, for the log.
    @discardableResult
    static func install(from source: URL, into directory: URL) -> String {
        let fm = FileManager.default
        let target = directory.appendingPathComponent(source.lastPathComponent)
        guard let fresh = try? Data(contentsOf: source) else { return "unreadable" }
        if let current = try? Data(contentsOf: target), current == fresh { return "current" }
        let existed = fm.fileExists(atPath: target.path)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try fresh.write(to: target, options: .atomic)
        } catch {
            return "failed: \(error.localizedDescription)"
        }
        return existed ? "replaced" : "installed"
    }

    /// At boot, off the main thread: a few hundred kilobytes compared.
    static func installAtBoot() {
        guard let source = bundled else { return }
        DispatchQueue.global(qos: .utility).async {
            let outcome = install(from: source, into: directory)
            Log.info("alert-sound", ["file": installed.path, "outcome": outcome])
        }
    }

    /// Whether the alert names the given file.
    static func isSelected(_ file: URL, selection: String?) -> Bool {
        guard let selection else { return false }
        return URL(fileURLWithPath: selection).standardizedFileURL.path
            == file.standardizedFileURL.path
    }

    static func currentSelection() -> String? {
        CFPreferencesCopyValue(selectionKey as CFString, kCFPreferencesAnyApplication,
                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
    }

    /// Back to the Mac's default alert.
    static func resetSelection() {
        CFPreferencesSetValue(selectionKey as CFString, nil, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
                                 kCFPreferencesAnyHost)
    }

    /// Remove the installed copy, and the selection if it named it.
    static func remove() {
        if isSelected(installed, selection: currentSelection()) { resetSelection() }
        try? FileManager.default.removeItem(at: installed)
    }
}
