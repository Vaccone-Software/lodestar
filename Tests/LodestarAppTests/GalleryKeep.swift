import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// Keep, the clipboard strip: clips as the keys they paste with, the chosen
/// one the slab, the keepsakes, and the menu of sources.
enum GalleryKeep {
    private static func clip(_ id: String, _ text: String, slot: Int? = nil, app bundle: String? = nil,
                             minutes: Double = 3, kind: Clipboard.Kind = .text) -> Clipboard.Clip {
        Clipboard.Clip(id: id, kind: kind, created: Date().addingTimeInterval(-60 * minutes),
                       sourceBundleID: bundle, sourceAppName: bundle == nil ? nil : "Ghostty",
                       preview: text, bytes: text.utf8.count, nativeTypes: [], pinnedSlot: slot)
    }

    private static func files(_ id: String, _ names: [String], minutes: Double = 3) -> Clipboard.Clip {
        let facts = names.map {
            Clipboard.FileFact(name: $0, folder: "Documents", kind: "PDF document", type: "com.adobe.pdf",
                               bytes: 3_000_000, detail: names.count == 1 ? "12 pages" : nil, pictured: nil)
        }
        return Clipboard.Clip(id: id, kind: .file, created: Date().addingTimeInterval(-60 * minutes),
                              sourceBundleID: "com.apple.finder", sourceAppName: "Finder",
                              preview: names.map { "/Users/you/Documents/\($0)" }.joined(separator: "\n"),
                              bytes: 600, nativeTypes: [Clipboard.fileURLType],
                              otherItemTypes: Array(repeating: [Clipboard.fileURLType], count: max(0, names.count - 1)),
                              fileFacts: facts)
    }

    private static var pins: [Clipboard.Clip] {
        [clip("p1", "https://lodestar.vaccone.software", slot: 1, app: "com.mitchellh.ghostty"),
         clip("p2", "hello@example.com", slot: 2),
         clip("p4", "image 1200×800", slot: 4, kind: .image)]
    }

    private static var recents: [Clipboard.Clip] {
        [clip("r0", "swift build -c release --arch arm64", app: "com.mitchellh.ghostty", minutes: 0.2),
         files("r1", ["Q3 report.pdf", "Q3 notes.pdf", "chart.pdf"], minutes: 1),
         clip("r2", "The quick brown fox jumps over the lazy dog and keeps going well past the edge of the card.", minutes: 8),
         clip("r3", "image 1600×1000", kind: .image),
         files("r4", ["Annual report.pdf"], minutes: 30),
         clip("r5", "git commit -m \"Actions open where the card is\"", app: "com.mitchellh.ghostty", minutes: 40),
         clip("r6", "AB12CD34EF", minutes: 300)]
    }

    /// Every place full: a clip being kept has no place of its own until a
    /// number is chosen, so its name is written on the band's place.
    private static var pinsFull: [Clipboard.Clip] {
        pins + [clip("p3", "https://example.com/pricing", slot: 3)]
    }

    /// What Bring finds in another window: three lines holding "inv", the
    /// foot of each saying which app and window.
    static func bring(_ strip: ClipboardStrip, query: String, source: String? = nil) {
        let sources = [Bring.Source(app: "Mail", window: "Inbox, 3 new", rank: 0),
                       Bring.Source(app: "Safari", window: "Billing", rank: 1)]
        let lines = [Bring.Line(source: 0, text: "Invoice 2026-0412 is attached"),
                     Bring.Line(source: 0, text: "Please pay the invoice by 30 October"),
                     Bring.Line(source: 1, text: "Download invoice (PDF)")]
        let found = Bring.search(lines, sources: sources, query: query)
        strip.showBring(query: query, matches: found.matches, total: found.total, sources: sources,
                        reading: false, source: source, sourceMenu: nil)
    }

    static func strip(look: GalleryLook, _ show: @escaping (ClipboardStrip) -> Void) throws -> (NSView, [AnyObject]) {
        try withPresentationFrame(NSRect(x: 0, y: 0, width: 1500, height: 820)) {
            try GalleryHost.surface(made: {
                let strip = ClipboardStrip()
                show(strip)
                return [strip]
            })
        }
    }

    static var shots: [GalleryShot] {
        let thumbnail: (String) -> NSImage? = { id in
            id == "r3" || id == "p4" ? StripPreview.sampleImage(width: 640, height: 400) : nil
        }
        func keep(_ state: String, looks: [GalleryLook] = GalleryLook.all,
                  _ show: @escaping (ClipboardStrip) -> Void) -> GalleryShot {
            var shot = GalleryShot(surface: "keep", state: state, looks: looks) { look in
                try strip(look: look, show)
            }
            shot.trim = true
            shot.bySiblings = true
            return shot
        }
        return [
            keep("clips-newest-chosen") {
                $0.show(recents: recents, pins: pins, thumbnail: thumbnail,
                        filesPresent: { _ in nil }, band: .none, selection: 0)
            },
            keep("third-chosen-search") {
                $0.show(recents: Array(recents.prefix(4)), pins: pins, thumbnail: thumbnail, band: .search("re"),
                        selection: 2, matches: 4)
            },
            keep("missing-file-quiet") {
                $0.show(recents: recents, pins: pins, thumbnail: thumbnail,
                        filesPresent: { $0 == "r4" ? [false] : ($0 == "r1" ? [true, false, true] : nil) },
                        band: .none, selection: 1)
            },
            keep("empty-keepsakes-no-clips") {
                $0.show(recents: [], pins: [], thumbnail: { _ in nil }, band: .none, selection: 0)
            },
            keep("source-menu") {
                $0.show(recents: Array(recents.prefix(4)), pins: pins, thumbnail: thumbnail, band: .search("build"),
                        selection: 0, matches: 3,
                        sourceMenu: .init(typed: "", rows: [.init(name: "All apps", count: 214), .init(name: "Brave", count: 38),
                                                             .init(name: "Ghostty", count: 71), .init(name: "Mail", count: 6),
                                                             .init(name: "Notes", count: 12)], selection: 1))
            },
            keep("search-empty") {
                $0.show(recents: Array(recents.prefix(4)), pins: pins, thumbnail: thumbnail, band: .search(""),
                        selection: 0, matches: nil)
            },
            keep("save-band") {
                $0.show(recents: Array(recents.prefix(4)), pins: pins, thumbnail: thumbnail,
                        band: .save(name: "", offered: "Screenshot 2026-10-23 at 14.02", folder: "Pictures"), selection: 0)
            },
            keep("save-band-typed") {
                $0.show(recents: Array(recents.prefix(4)), pins: pins, thumbnail: thumbnail,
                        band: .save(name: "wireframe", offered: "Screenshot 2026-10-23 at 14.02", folder: "Pictures"),
                        selection: 0)
            },
            keep("naming-keepsake") {
                $0.show(recents: Array(recents.prefix(4)), pins: pins, thumbnail: thumbnail, band: .none, selection: 0,
                        naming: .init(id: "p1", text: "Lodestar site", selected: true))
            },
            keep("naming-keepsake-typed") {
                $0.show(recents: Array(recents.prefix(4)), pins: pins, thumbnail: thumbnail, band: .none, selection: 0,
                        naming: .init(id: "p2", text: "My email", selected: false))
            },
            keep("naming-unkept-clip") {
                $0.show(recents: Array(recents.prefix(4)), pins: pinsFull, thumbnail: thumbnail, band: .none,
                        selection: 0, naming: .init(id: "r0", text: "Release build", selected: false))
            },
            keep("bring-search") { bring($0, query: "inv") },
            keep("card-actions") {
                $0.show(recents: recents, pins: pins, thumbnail: thumbnail,
                        band: .actions(HotkeyEngine.panelActions(for: recents[0])), selection: 0, actingOn: "r0")
            },
            keep("held-option") {
                $0.show(recents: recents, pins: pins, thumbnail: thumbnail, band: .none, selection: 0, held: .option)
            },
        ]
    }
}
