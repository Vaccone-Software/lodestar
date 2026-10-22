import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// Every surface, drawn offscreen to a PNG at twice its size, in day and
/// night. Skipped unless `LODESTAR_RENDER` names a directory
/// (scripts/render-gallery.sh sets it): the pictures are for a person to
/// look at, and the harness is how a layer-drawn key, row or shadow is seen
/// without running the app.
final class RenderGalleryTests: XCTestCase {
    override func tearDown() {
        GalleryLook.reset()
        ActivePolicy.frameOverride = nil
    }

    func testRenderEverySurface() throws {
        guard let directory = GalleryRender.outputDirectory else { throw XCTSkip("set LODESTAR_RENDER to a directory") }
        let only = ProcessInfo.processInfo.environment["LODESTAR_RENDER_ONLY"].flatMap { $0.isEmpty ? nil : $0 }
        var made: [(file: String, caption: String, surface: String)] = []
        var failed: [String] = []
        for look in GalleryLook.all {
            look.apply()
            for shot in GalleryShots.all where shot.looks.contains(look) {
                let name = shot.name(in: look)
                if let only, !name.contains(only) { continue }
                do {
                    let (view, keep) = try shot.build(look)
                    var rep = GalleryRender.bitmap(of: view)
                    if shot.trim { rep = GalleryRender.trimmed(rep) }
                    try GalleryRender.write(GalleryRender.onDesktop(rep, margin: shot.trim ? 0 : 8), name: name)
                    made.append((name + ".png", "\(shot.surface): \(shot.state) (\(look.name))", shot.surface))
                    _ = keep
                } catch {
                    failed.append("\(name): \(error)")
                }
            }
        }
        try GalleryIndex.write(made, in: directory)
        if !failed.isEmpty { print("gallery: not rendered:\n" + failed.joined(separator: "\n")) }
        XCTAssertTrue(failed.isEmpty, "every surface renders: \(failed)")
    }
}

/// `index.html`: every picture in a grid, grouped by surface, with its caption.
enum GalleryIndex {
    static func write(_ pictures: [(file: String, caption: String, surface: String)], in directory: URL) throws {
        // Pictures kept from before a fix (before-<name>.png, made by hand
        // from the code as it stood) stand beside their after.
        var pictures = pictures
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in kept.sorted() where file.hasPrefix("before-") && file.hasSuffix(".png") {
            pictures.append((file, "before the fix: " + file.dropFirst(7).dropLast(4), "before the fixes"))
        }
        var surfaces: [String] = []
        for picture in pictures where !surfaces.contains(picture.surface) { surfaces.append(picture.surface) }
        var html = """
        <!doctype html><meta charset="utf-8"><title>Lodestar gallery</title>
        <style>
        body{font:14px -apple-system,sans-serif;margin:24px;background:#777;color:#111}
        h2{margin:32px 0 8px;font-size:15px;color:#fff;text-transform:uppercase;letter-spacing:.06em}
        .grid{display:flex;flex-wrap:wrap;gap:20px;align-items:flex-start}
        figure{margin:0}
        img{display:block;max-width:760px;height:auto;image-rendering:auto}
        figcaption{margin-top:6px;color:#eee;font-size:12px}
        </style><h1 style="color:#fff">Lodestar gallery</h1>
        """
        for surface in surfaces {
            html += "<h2>\(surface)</h2><div class=\"grid\">"
            for picture in pictures where picture.surface == surface {
                html += "<figure><a href=\"../\(picture.file)\"><img src=\"../\(picture.file)\"></a><figcaption>\(picture.caption)</figcaption></figure>"
            }
            html += "</div>"
        }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("gallery"), withIntermediateDirectories: true)
        try html.write(to: directory.appendingPathComponent("gallery/index.html"), atomically: true, encoding: .utf8)
    }
}
