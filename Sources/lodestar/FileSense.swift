import AppKit
import AVFoundation
import ImageIO
import LodestarCore
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// What a copied file is and what it looks like, read once at the copy and
/// kept, so a card is drawn without touching the file and keeps its look
/// after the file has moved.
///
/// Everything here runs off the main thread, and nothing here trusts the
/// disk to answer: a network volume, a dead mount or a file that iCloud has
/// evicted can make a stat or a page count wait for as long as it likes, and
/// the card must not. Every read of a file is given a short deadline; the one
/// that overruns is answered with what is known without it (a name, a type's
/// icon) and left behind. No file's content is ever kept, and no name or path
/// is ever logged.
enum FileSense {
    /// How long one read of one file may take before the card goes on
    /// without it. A seam for the tests.
    nonisolated(unsafe) static var deadline: TimeInterval = 2

    /// A picture is 240 points at twice the pixels, as an image's thumbnail is.
    static let side = 480

    /// The system's thumbnail of a file, or nil. A seam for the tests, which
    /// stand in for QuickLook so a slow volume can be made to happen.
    nonisolated(unsafe) static var thumbnailer: (URL) -> CGImage? = quickLook

    /// Whether a file's content is somewhere else. A seam for the tests, which
    /// cannot make a file iCloud has evicted.
    nonisolated(unsafe) static var dataless: (URL, URLUbiquitousItemDownloadingStatus?) -> Bool = isDataless

    struct Picture {
        let png: Data
        /// The file's own face (a first page, a poster frame), not its icon.
        let pictured: Bool
    }

    // MARK: - The facts

    /// One file's name, folder, kind, size and one line more.
    static func fact(for url: URL) -> Clipboard.FileFact {
        let names = Clipboard.fileNames(of: url)
        guard let read = withDeadline(deadline, { basics(of: url) }) else {
            return Clipboard.FileFact(name: names.name, folder: names.folder, kind: "Document")
        }
        var fact = read.fact
        // Where a download came from is the Mac's own note on the file, not
        // anything in it, and is read even for a file not on this Mac yet.
        fact.site = withDeadline(deadline) { site(of: url) }
        // A file that is not on this Mac yet is described by what is known;
        // opening it to count its pages would download it.
        if !read.dataless, let type = read.type, !read.isFolder,
           let described = withDeadline(deadline, { detail(of: url, type: type) }) {
            fact.detail = described.detail
            fact.title = described.title
        }
        return fact
    }

    /// The host of the page or address a downloaded file came from, as the
    /// Mac recorded it at the download: `kMDItemWhereFroms`, kept on the
    /// file as an extended attribute (read here directly, so the answer
    /// does not wait on Spotlight having seen the folder), the address
    /// first. The host alone: a download's address can carry a private
    /// token, and the card has no use for one.
    static func site(of url: URL) -> String? {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0, size < 64 << 10 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, name, &bytes, size, 0, 0) == size,
              let froms = try? PropertyListSerialization.propertyList(from: Data(bytes), format: nil) as? [String]
        else { return nil }
        return Clipboard.siteName(froms)
    }

    private struct Basics {
        var fact: Clipboard.FileFact
        var type: UTType?
        var isFolder: Bool
        var dataless: Bool
    }

    private static func basics(of url: URL) -> Basics {
        let names = Clipboard.fileNames(of: url)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentTypeKey,
                                         .localizedTypeDescriptionKey, .ubiquitousItemDownloadingStatusKey]
        let values = try? url.resourceValues(forKeys: keys)
        let type = values?.contentType
        // A package (an app, a bundle) is one thing to the hand, whatever
        // it is made of; a folder holds things, counted one level deep and
        // never beneath, which is what the Finder says and what stays quick.
        let isFolder = values?.isDirectory == true && values?.isPackage != true
        // The Finder's own word for it ("Plain Text Document", "Folder"),
        // which is capitalised and what the hand has seen; a type's
        // description is the lowercase fallback when the system has none.
        let described = values?.localizedTypeDescription
            ?? type?.localizedDescription.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        var fact = Clipboard.FileFact(name: names.name, folder: names.folder, kind: described ?? "Document",
                                      type: type?.identifier)
        if isFolder {
            fact.items = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles))?.count
        } else {
            fact.bytes = values?.fileSize
        }
        return Basics(fact: fact, type: type, isFolder: isFolder,
                      dataless: dataless(url, values?.ubiquitousItemDownloadingStatus))
    }

    /// Whether the file's content is somewhere else: evicted from iCloud, or
    /// a placeholder a file provider has not filled. Reading it would fetch it.
    static func isDataless(_ url: URL, _ status: URLUbiquitousItemDownloadingStatus?) -> Bool {
        if let status, status != .current { return true }
        var info = stat()
        guard stat(url.path, &info) == 0 else { return false }
        return info.st_flags & 0x4000_0000 != 0  // SF_DATALESS
    }

    /// Pages for a PDF (and its title, when its maker gave it one), pixels
    /// for an image, minutes and seconds for sound and film. Header reads,
    /// every one: no content comes with them.
    private static func detail(of url: URL, type: UTType) -> (detail: String?, title: String?)? {
        if type.conforms(to: .pdf) {
            guard let document = PDFDocument(url: url) else { return nil }
            let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (Clipboard.pagesDetail(document.pageCount), title?.isEmpty == false ? title : nil)
        }
        if type.conforms(to: .image) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  var width = properties[kCGImagePropertyPixelWidth] as? Int,
                  var height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
            // Orientations 5 to 8 are turned on their side: the picture is
            // the way up it is shown, not the way it is stored.
            if let turn = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(turn) { swap(&width, &height) }
            return (Clipboard.dimensionsDetail(width: width, height: height), nil)
        }
        if type.conforms(to: .audiovisualContent) {
            return (duration(of: url).flatMap(Clipboard.durationDetail), nil)
        }
        return nil
    }

    private static func duration(of url: URL) -> Double? {
        let asset = AVURLAsset(url: url)
        let slot = Slot<Double>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            if let time = try? await asset.load(.duration) { slot.set(CMTimeGetSeconds(time)) }
            done.signal()
        }
        return done.wait(timeout: .now() + deadline) == .success ? slot.value : nil
    }

    // MARK: - The picture

    /// A file's picture as PNG: the system's thumbnail of it when there is
    /// one in time (a PDF's first page, a video's poster frame, an image
    /// itself), otherwise its icon, drawn at the same size. Nil only when
    /// not even an icon could be drawn.
    static func picture(of url: URL) -> Picture? {
        if !dataless(url, nil),
           let image = withDeadline(deadline, { thumbnailer(url) }), let png = png(image) {
            return Picture(png: png, pictured: true)
        }
        guard let icon = icon(of: url), let png = png(icon) else { return nil }
        return Picture(png: png, pictured: false)
    }

    static func quickLook(_ url: URL) -> CGImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side / 2, height: side / 2),
                                                   scale: 2, representationTypes: .thumbnail)
        let slot = Slot<CGImage>()
        let done = DispatchSemaphore(value: 0)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            slot.set(representation?.cgImage)
            done.signal()
        }
        if done.wait(timeout: .now() + deadline) == .timedOut {
            QLThumbnailGenerator.shared.cancel(request)
            return nil
        }
        return slot.value
    }

    /// The icon the Finder would show, drawn into the same square a
    /// thumbnail is: the system hands out icons of every size, and the
    /// store keeps one size.
    private static func icon(of url: URL) -> CGImage? {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        var rect = NSRect(x: 0, y: 0, width: side, height: side)
        guard let drawn = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(drawn, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    private static func png(_ image: CGImage) -> Data? {
        guard let out = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }

    // MARK: - A deadline

    /// `work` on another thread, given `seconds`. What overruns is left
    /// running and forgotten; the caller has its answer, which is nil.
    static func withDeadline<T>(_ seconds: TimeInterval, _ work: @escaping () -> T?) -> T? {
        let slot = Slot<T>()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            slot.set(work())
            group.leave()
        }
        return group.wait(timeout: .now() + seconds) == .success ? slot.value : nil
    }

    /// A value handed from one thread to another.
    private final class Slot<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?
        func set(_ value: T?) { lock.lock(); stored = value; lock.unlock() }
        var value: T? { lock.lock(); defer { lock.unlock() }; return stored }
    }
}
