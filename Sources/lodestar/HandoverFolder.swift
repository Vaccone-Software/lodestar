import Foundation
import LodestarCore

/// Where the PNGs handed to terminals live.
///
/// A terminal pastes a path, so an image going into one is written as a
/// file first. Those files are full-size copies of what the person copied,
/// and they sat loose in the temporary directory under the default mode.
/// They now live in a folder of their own under it, made 0700, and each
/// file is 0600; the folder is emptied when the app starts and when it
/// quits.
struct HandoverFolder {
    let parent: URL
    let url: URL

    init(parent: URL = FileManager.default.temporaryDirectory) {
        self.parent = parent
        url = parent.appendingPathComponent("lodestar-handover", isDirectory: true)
    }

    /// Is the folder, as it stands, a directory of this user's own? A link
    /// or a file in its place, or another user's folder, is not ours to put
    /// anything in or take anything out of.
    private func owned() -> Bool? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid()
    }

    /// The folder, made if it is not there and tightened if it is loose; nil
    /// when something else stands where it should be.
    func prepared() -> URL? {
        switch owned() {
        case true?:
            var info = stat()
            if lstat(url.path, &info) == 0, info.st_mode & 0o077 != 0 { chmod(url.path, 0o700) }
            return url
        case false?:
            return nil
        case nil:
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                return nil
            }
            return url
        }
    }

    /// The folder emptied and removed, and with it the files of this kind
    /// that earlier builds left loose in the temporary directory.
    func sweep() {
        let fm = FileManager.default
        if owned() == true {
            for name in (try? fm.contentsOfDirectory(atPath: url.path)) ?? [] {
                try? fm.removeItem(at: url.appendingPathComponent(name))
            }
            rmdir(url.path)
        }
        for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
        where name.hasPrefix(Clipboard.handoverPrefix) && name.hasSuffix(".\(Clipboard.pasteableImageExtension)") {
            let file = parent.appendingPathComponent(name)
            var info = stat()
            if lstat(file.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() {
                try? fm.removeItem(at: file)
            }
        }
    }
}
