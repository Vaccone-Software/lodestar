import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// What the clipboard costs on a history the size of a real one, so a change
/// to how it is stored can be shown to be no slower — or slower by exactly
/// what it says. On demand, never in the suite:
///
///     LODESTAR_CLIPBOARD_BENCH=1 swift test --filter ClipboardBenchTests
///
/// The history is synthetic and built in a temporary directory: 4,200 clips,
/// 3,800 of them text (previews of median 80 and at most 2,000 characters, a
/// quarter with rich forms beside the plain one, a few with tens of
/// kilobytes behind them) and 400 images whose previews carry what a
/// recognizer read, each with a thumbnail and a blob of
/// `LODESTAR_CLIPBOARD_BENCH_IMAGE_KB` kilobytes (512: about 200 MB in all).
/// The index lands near 2.4 MB, which is what the real one weighs. Nothing
/// here reads the person's own history: the store is given its own root and
/// the controller the test run's own pasteboard.
///
/// Every figure is wall time on the thread that asked, in milliseconds, as
/// median and 95th percentile over the repetitions
/// (`LODESTAR_CLIPBOARD_BENCH_REPS`, 15). A figure is the main thread's
/// portion unless it says "end to end", which waits for the io queue too.
/// `LODESTAR_CLIPBOARD_BENCH_OUT` names a file the table is also written to,
/// and `LODESTAR_CLIPBOARD_BENCH_ONLY` a comma-separated list of what to run
/// (`history`, `capture`, `paste`, `delete`; everything by default). A figure
/// is also given as the CPU time the thread spent, which a machine busy with
/// other things leaves much as it was while the wall time swells.
final class ClipboardBenchTests: XCTestCase {
    private var root: URL!
    private var lines: [String] = []

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Measuring

    private static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

    /// The calling thread's own CPU time, in milliseconds. On a machine
    /// that is busy with other things the wall time of a figure is the
    /// scheduler's as much as the code's; this is what the thread spent.
    private static func cpu() -> Double {
        var spec = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &spec)
        return Double(spec.tv_sec) * 1e3 + Double(spec.tv_nsec) / 1e6
    }

    /// The thread CPU time of each `milliseconds` call since the last
    /// report, for the report that follows to print beside its wall times.
    private var cpuSamples: [Double] = []

    /// What the block took, on the clock and on this thread.
    private func timed(_ block: () -> Void) -> (wall: Double, cpu: Double) {
        let (wall, cpu) = (Self.now(), Self.cpu())
        block()
        return (Self.now() - wall, Self.cpu() - cpu)
    }

    /// Milliseconds the block took.
    private func milliseconds(_ block: () -> Void) -> Double {
        let took = timed(block)
        cpuSamples.append(took.cpu)
        return took.wall
    }

    private static func median(_ samples: [Double]) -> Double { samples.sorted()[samples.count / 2] }

    /// A line of the table. `cpu` is what the thread spent, where the
    /// samples were taken with `milliseconds` or the caller says.
    private func report(_ name: String, _ samples: [Double], cpu explicit: [Double]? = nil, note: String = "") {
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        var cpu = explicit ?? (cpuSamples.count == samples.count ? cpuSamples : nil)
        if cpu?.isEmpty == true { cpu = nil }
        cpuSamples.removeAll()
        let line = "BENCH " + name.padding(toLength: 52, withPad: " ", startingAt: 0)
            + String(format: "median %9.3f ms   p95 %9.3f ms", median, p95)
            + (cpu.map { String(format: "   cpu median %9.3f ms", Self.median($0)) } ?? String(repeating: " ", count: 26))
            + String(format: "   n=%d", samples.count)
            + (note.isEmpty ? "" : "   " + note)
        lines.append(line)
        print(line)
    }

    private func note(_ text: String) {
        lines.append("BENCH " + text)
        print("BENCH " + text)
    }

    // MARK: - The synthetic history

    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        /// Standard normal, by Box–Muller.
        mutating func normal() -> Double {
            let a = max(unit(), 1e-12), b = unit()
            return (-2 * log(a)).squareRoot() * cos(2 * .pi * b)
        }
    }

    private static let words = [
        "the", "build", "deploy", "error", "kubectl", "swift", "func", "let", "return", "config",
        "commit", "branch", "merge", "pull", "request", "review", "meeting", "notes", "tomorrow",
        "invoice", "payment", "address", "street", "timeout", "retry", "exception", "stack", "trace",
        "https://github.com/example/project/pull/1234", "SELECT * FROM users WHERE id =", "README.md",
        "Sources/lodestar/ClipboardStore.swift", "a", "of", "and", "to", "in", "is", "that", "for",
        "with", "as", "on", "was", "at", "by", "an", "be", "this", "from", "or", "have", "not",
    ]

    private static func text(length: Int, _ rng: inout SplitMix, lines multiline: Bool) -> String {
        var out = ""
        while out.count < length {
            if rng.unit() < 0.2 {
                out += String((0..<Int(6 + rng.unit() * 10)).map { _ in
                    "abcdefghijklmnopqrstuvwxyz0123456789".randomElement(using: &rng)!
                })
            } else {
                out += words.randomElement(using: &rng)!
            }
            out += multiline && rng.unit() < 0.08 ? "\n" : " "
        }
        return String(out.prefix(length))
    }

    private static let apps: [(String, String)] = [
        ("com.apple.Safari", "Safari"), ("com.google.Chrome", "Google Chrome"),
        ("com.apple.dt.Xcode", "Xcode"), ("com.apple.Terminal", "Terminal"),
        ("com.mitchellh.ghostty", "Ghostty"), ("com.apple.mail", "Mail"),
        ("com.tinyspeck.slackmacgap", "Slack"), ("com.apple.Notes", "Notes"),
        ("com.microsoft.VSCode", "Code"), ("com.apple.finder", "Finder"),
        ("md.obsidian", "Obsidian"), ("com.figma.Desktop", "Figma"),
        ("com.apple.iCal", "Calendar"), ("com.spotify.client", "Spotify"),
    ]

    /// A PNG with some structure to it, so it compresses the way a
    /// screenshot does and not the way noise does.
    private static func png(width: Int, height: Int, seed: UInt64 = 7) -> Data {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var rng = SplitMix(state: seed)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8((x * 255 / width + Int(seed)) % 256)
                pixels[i + 1] = UInt8(y * 255 / height)
                pixels[i + 2] = UInt8(truncatingIfNeeded: (x / 8) ^ (y / 8)) &* 5
            }
        }
        for _ in 0..<400 {
            let (x0, y0) = (Int(rng.next() % UInt64(width - 60)), Int(rng.next() % UInt64(height - 20)))
            let shade = UInt8(truncatingIfNeeded: rng.next())
            for y in y0..<y0 + 14 { for x in x0..<x0 + 50 { pixels[(y * width + x) * 4 + 2] = shade } }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        let out = CFDataCreateMutable(nil, 0)!
        let destination = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    private var imageIDs: [String] = []
    private var textIDs: [String] = []

    private func seed(_ store: ClipboardStore, imageKilobytes: Int) {
        var rng = SplitMix(state: 20_261_017)
        // Two dozen different thumbnails, shared out among the images: the
        // system keeps what it has decoded, and identical bytes would make
        // every decode after the first look free.
        let thumbnails = (0..<24).map { ClipboardStore.thumbnail(from: Self.png(width: 1440, height: 900, seed: UInt64($0 + 7)))! }
        let blob = Data((0..<imageKilobytes * 1024).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        let thumbs = root.appendingPathComponent("thumbs")
        let imageEvery = 4200 / 400
        for n in 0..<4200 {
            let app = Self.apps[Int(rng.next() % UInt64(Self.apps.count))]
            let host = rng.unit() < 0.25 ? ["github.com", "stackoverflow.com", "docs.swift.org", "linear.app"]
                .randomElement(using: &rng) : nil
            if n % imageEvery == imageEvery - 1 {
                let id = ClipboardStore.identity(for: Data("image \(n)".utf8))
                let ocr = Self.text(length: 200 + Int(rng.unit() * 1300), &rng, lines: true)
                store.record(id: id, kind: .image,
                             items: [.init(plain: nil, natives: [("public.png", blob)])],
                             imageData: nil,
                             preview: Clipboard.imagePreview(width: 1440, height: 900, text: ocr),
                             sourceBundleID: app.0, sourceAppName: app.1, sourceHost: host)
                try? thumbnails[imageIDs.count % thumbnails.count].write(to: thumbs.appendingPathComponent("\(id).png"))
                imageIDs.append(id)
            } else {
                // Median 80 characters, a long tail, cut at the preview's cap.
                let length = max(1, Int(80 * exp(1.25 * rng.normal())))
                let long = rng.unit() < 0.03
                let body = Self.text(length: long ? 5_000 + Int(rng.unit() * 55_000) : min(length, 2_000),
                                     &rng, lines: rng.unit() < 0.3)
                let id = ClipboardStore.identity(for: Data("text \(n) \(body.prefix(20))".utf8))
                let rich: [(type: String, data: Data)] = rng.unit() < 0.25
                    ? [("public.html", Data(("<meta charset='utf-8'><span>" + body.prefix(1_500) + "</span>").utf8)),
                       ("public.rtf", Data(("{\\rtf1\\ansi " + body.prefix(1_000) + "}").utf8))]
                    : []
                let counted = Clipboard.counts(of: body)
                store.record(id: id, kind: .text,
                             items: [.init(plain: Data(body.utf8), natives: rich)],
                             imageData: nil, preview: Clipboard.preview(of: body),
                             sourceBundleID: app.0, sourceAppName: app.1, sourceHost: host,
                             lines: counted.lines, characters: counted.characters)
                textIDs.append(id)
            }
        }
        for slot in 1...3 { _ = store.pin(textIDs[slot * 100]) }
        store.saveNow()
        store.flushIO()
    }

    private func directoryBytes(_ url: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return names.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    // MARK: - The measurements

    func testTheClipboardOnARealHistory() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["LODESTAR_CLIPBOARD_BENCH"] != nil else {
            throw XCTSkip("LODESTAR_CLIPBOARD_BENCH=1 measures the clipboard on a synthetic history")
        }
        let reps = environment["LODESTAR_CLIPBOARD_BENCH_REPS"].flatMap(Int.init) ?? 15
        let only = environment["LODESTAR_CLIPBOARD_BENCH_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        func wanted(_ section: String) -> Bool { only?.contains(section) ?? true }
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        note("machine load average at the start: \(load.map { String(format: "%.1f", $0) }.joined(separator: " "))")
        let kilobytes = environment["LODESTAR_CLIPBOARD_BENCH_IMAGE_KB"].flatMap(Int.init) ?? 512
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-clipboard-bench-\(UUID().uuidString)", isDirectory: true)

        let store = ClipboardStore(root: root)
        let seeding = milliseconds { seed(store, imageKilobytes: kilobytes) }
        cpuSamples.removeAll()
        let indexFile = root.appendingPathComponent("index.json")
        let indexBytes = (try? Data(contentsOf: indexFile).count) ?? 0
        let items = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("items").path))?.count ?? 0
        note("history: \(store.clips.count) clips, index \(String(format: "%.2f", Double(indexBytes) / 1e6)) MB, "
             + "\(items) files in items/ (\(directoryBytes(root.appendingPathComponent("items")) / 1_000_000) MB), "
             + "\(directoryBytes(root.appendingPathComponent("thumbs")) / 1_000_000) MB of thumbnails; "
             + "seeded in \(Int(seeding)) ms; reps \(reps)")

        if wanted("history") {
            // The index, read and decoded the way boot does it.
            report("index: read the file", (0..<reps).map { _ in milliseconds { _ = try? Data(contentsOf: indexFile) } })
            report("index: load (read + decode + settle), store init",
                   (0..<reps).map { _ in milliseconds { _ = ClipboardStore(root: root) } })

            // The index, encoded and written durably: the main thread only
            // hands over, the io queue does the rest.
            report("index: save, main thread hands over", (0..<reps).map { _ in milliseconds { store.saveNow() } })
            store.flushIO()
            report("index: save, end to end (encode + durable write)",
                   (0..<reps).map { _ in milliseconds { store.saveNow(); store.flushIO() } })

            // Search.
            let all = store.clips
            var folding: [Double] = []
            for _ in 0..<min(reps, 7) {
                let index = ClipboardSearchIndex()
                folding.append(milliseconds { _ = Clipboard.search(all, query: "de", index: index) })
            }
            report("search: first fold of every clip", folding)
            let index = ClipboardSearchIndex()
            _ = Clipboard.search(all, query: "de", index: index)
            var keystrokes: [Double] = []
            for _ in 0..<reps {
                for typed in ["d", "de", "dep", "depl", "deplo", "deploy"] {
                    keystrokes.append(milliseconds { _ = Clipboard.search(all, query: typed, index: index) })
                }
            }
            report("search: one keystroke, warm index (d … deploy)", keystrokes)
            report("search: keystroke \"deploy\" with a source filter",
                   (0..<reps).map { _ in milliseconds {
                       let pool = all.filter { $0.sourceAppName == "Safari" }
                       _ = Clipboard.search(pool, query: "deploy", index: index)
                   } })

            // What a redraw does besides searching: the recents, the keepsakes
            // and the recents' count, from the history. Once as the first redraw
            // after a change to the index, and again as every redraw after it.
            var afterChange: [Double] = [], afterChangeCPU: [Double] = []
            var unchanged: [Double] = [], unchangedCPU: [Double] = []
            for _ in 0..<reps {
                store.name(textIDs[5], nil)
                let first = timed { Self.renderPasses(store) }
                let again = timed { Self.renderPasses(store) }
                afterChange.append(first.wall); afterChangeCPU.append(first.cpu)
                unchanged.append(again.wall); unchangedCPU.append(again.cpu)
            }
            report("render: the passes over all clips, after a change", afterChange, cpu: afterChangeCPU)
            report("render: the passes over all clips, nothing changed", unchanged, cpu: unchangedCPU)

            // Thumbnails of twelve image cards, none decoded yet.
            let twelve = Array(imageIDs.prefix(12))
            note("thumbnail files: \(directoryBytes(root.appendingPathComponent("thumbs")) / max(1, imageIDs.count) / 1024) KB each on average")
            var lookups: [Double] = [], lookupsCPU: [Double] = [], fills: [Double] = []
            var drawings: [Double] = [], drawingsCPU: [Double] = []
            for _ in 0..<reps {
                let fresh = ClipboardStore(root: root)
                let asked = timed { _ = twelve.map { fresh.thumbnail(for: $0) } }
                lookups.append(asked.wall); lookupsCPU.append(asked.cpu)
                let started = Self.now()
                while twelve.contains(where: { fresh.thumbnail(for: $0) == nil }), Self.now() - started < 5_000 {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.001))
                }
                fills.append(Self.now() - started)
                // What drawing the cards asks of the main thread: a decode,
                // unless it already happened elsewhere.
                let shown = twelve.compactMap { fresh.thumbnail(for: $0) }
                let drawn = timed { for image in shown { _ = image.cgImage(forProposedRect: nil, context: nil, hints: nil) } }
                drawings.append(drawn.wall); drawingsCPU.append(drawn.cpu)
            }
            report("thumbnails: ask for 12 cold ones, main thread", lookups, cpu: lookupsCPU)
            report("thumbnails: until all 12 are there", fills)
            report("thumbnails: first draw of 12 (decode if not yet)", drawings, cpu: drawingsCPU)
        }

        if wanted("capture") { try capture(store: store, reps: reps) }
        if wanted("paste") { try paste(store: store, reps: reps) }
        if wanted("delete") { try deleting(store: store, reps: reps) }

        if let out = environment["LODESTAR_CLIPBOARD_BENCH_OUT"] {
            try lines.joined(separator: "\n").appending("\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
    }

    /// What `renderStrip` asks of the history on every redraw with nothing
    /// typed: the recents, the keepsakes, the recents again for the
    /// session's statistics.
    private static func renderPasses(_ store: ClipboardStore) {
        _ = store.recents
        _ = store.pins
        _ = store.recents.count
    }

    // MARK: - A copy, from the pasteboard to the index

    private func capture(store: ClipboardStore, reps: Int) throws {
        let controller = ClipboardController(store: store)
        let board = SystemEvents.pasteboard
        controller.pasteboard = board
        var serial = 0
        /// One copy, taken the way the poll takes it: the board is written
        /// outside the clock, `capture` is what the main thread pays.
        func copy(_ label: String, repetitions: Int, patterns: [String] = [],
                  _ make: (Int) -> [(NSPasteboard.PasteboardType, Data)]) {
            controller.excludedPatterns = patterns
            var main: [Double] = [], mainCPU: [Double] = [], endToEnd: [Double] = []
            for _ in 0..<repetitions {
                serial += 1
                board.clearContents()
                for (type, data) in make(serial) {
                    if type == .string { board.setString(String(decoding: data, as: UTF8.self), forType: .string) }
                    else { board.setData(data, forType: type) }
                }
                let before = store.clips.count
                let started = Self.now()
                let took = timed { controller.capture() }
                main.append(took.wall)
                mainCPU.append(took.cpu)
                store.flushIO()
                endToEnd.append(Self.now() - started)
                if store.clips.count != before + 1 { note("  (a copy of \(label) did not become a card)") }
                // Let a thumbnail or a caption land before the next one.
                RunLoop.main.run(until: Date().addingTimeInterval(label.hasPrefix("image") ? 2.5 : 0.01))
            }
            report("capture: \(label), main thread", main, cpu: mainCPU)
            report("capture: \(label), end to end", endToEnd)
            controller.excludedPatterns = []
        }
        var rng = SplitMix(state: 99)
        func utf8(_ length: Int) -> Data {
            Data(Self.text(length: length, &rng, lines: true).utf8)
        }
        copy("a 300-char text", repetitions: reps * 2) { n in [(.string, Data("copy \(n) ".utf8) + utf8(300))] }
        copy("a 300-char text with html and rtf", repetitions: reps) { n in
            [(.string, Data("copy \(n) ".utf8) + utf8(300)), (.html, utf8(2_000)), (.rtf, utf8(1_500))]
        }
        let big = utf8(1_000_000)
        copy("a 1 MB text", repetitions: reps) { n in [(.string, Data("copy \(n) ".utf8) + big)] }
        let huge = (0..<19).reduce(into: Data()) { out, _ in out.append(big) }
        copy("a 19 MB text", repetitions: 5) { n in [(.string, Data("copy \(n) ".utf8) + huge)] }
        copy("a 19 MB text, one exclude pattern set", repetitions: 5, patterns: ["hunter2"]) { n in
            [(.string, Data("copy \(n) ".utf8) + huge)]
        }
        let screenshot = Self.png(width: 1440, height: 900)
        note("image capture uses a \(screenshot.count / 1024) KB PNG, 1440x900; each waits 2.5 s for the recognizer")
        copy("image 1440x900 PNG", repetitions: 5) { n in
            [(.png, screenshot + Data("\(n)".utf8))]
        }

        // What the poll does between the pasteboard and the index, a step at
        // a time, on a 19 MB text: where the main thread's second goes.
        let data19 = Data("copy ".utf8) + huge
        let text19 = String(decoding: data19, as: UTF8.self)
        func parts(_ what: String, _ text: String, _ data: Data, repetitions: Int) {
            report("capture parts: SHA-256 of \(what)", (0..<repetitions).map { _ in milliseconds { _ = ClipboardStore.identity(for: data) } })
            report("capture parts: Data(text.utf8) of \(what)", (0..<repetitions).map { _ in milliseconds { _ = Data(text.utf8) } })
            report("capture parts: isOwnHandoverPath of \(what)", (0..<repetitions).map { _ in milliseconds {
                _ = Clipboard.isOwnHandoverPath(text, temporaryDirectory: NSTemporaryDirectory())
            } })
            for patterns in [[], ["hunter2"]] {
                report("capture parts: refusal, \(patterns.count) pattern(s), \(what)", (0..<repetitions).map { _ in milliseconds {
                    _ = Clipboard.refusal(types: ["public.utf8-plain-text"], sourceBundleID: nil, text: text,
                                          bytes: data.count, excludedApps: [], excludedPatterns: patterns,
                                          maxItemBytes: 20_000_000)
                } })
            }
            report("capture parts: preview of \(what)", (0..<repetitions).map { _ in milliseconds { _ = Clipboard.preview(of: text) } })
            report("capture parts: counts of \(what)", (0..<repetitions).map { _ in milliseconds { _ = Clipboard.counts(of: text) } })
        }
        parts("19 MB ASCII", text19, data19, repetitions: 5)
        let accented = String(repeating: "café ünïcode 日本語 text, with some more words and a line\r\nof its own. ", count: 19_000_000 / 80)
        parts("19 MB with accents and CRLF", accented, Data(accented.utf8), repetitions: 3)
        let data1 = Data("copy ".utf8) + big
        report("capture parts: SHA-256 of 1 MB", (0..<reps).map { _ in milliseconds { _ = ClipboardStore.identity(for: data1) } })
        board.clearContents()
        board.setString(text19, forType: .string)
        report("capture parts: pasteboard string read, 19 MB", (0..<5).map { _ in milliseconds { _ = board.string(forType: .string) } })
        report("capture parts: pasteboardItems + string read, 19 MB", (0..<5).map { _ in milliseconds {
            _ = board.pasteboardItems?.first?.string(forType: .string)
        } })

        // The record itself and the trim after it, for a copy that is small.
        var recordSamples: [Double] = [], recordCPU: [Double] = []
        var trimSamples: [Double] = [], trimCPU: [Double] = []
        for n in 0..<reps * 2 {
            let body = "recorded \(n) " + Self.text(length: 200, &rng, lines: false)
            let data = Data(body.utf8)
            let id = ClipboardStore.identity(for: data)
            let recorded = timed {
                store.record(id: id, kind: .text, items: [.init(plain: data, natives: [])],
                             imageData: nil, preview: body, sourceBundleID: "com.apple.Safari",
                             sourceAppName: "Safari", lines: 1, characters: body.count)
            }
            let trimmed = timed { store.trim(maxBytes: 500_000_000, maxItems: 10_000) }
            recordSamples.append(recorded.wall); recordCPU.append(recorded.cpu)
            trimSamples.append(trimmed.wall); trimCPU.append(trimmed.cpu)
            store.flushIO()
        }
        report("record: a small text, main thread", recordSamples, cpu: recordCPU)
        report("trim: the check after a capture that trims nothing", trimSamples, cpu: trimCPU)
    }

    // MARK: - A paste

    private func paste(store: ClipboardStore, reps: Int) throws {
        var rng = SplitMix(state: 5)
        let controller = ClipboardController(store: store)
        // The test run's own board, never the general one.
        controller.pasteboard = SystemEvents.pasteboard
        controller.postPaste = {}
        controller.secureInput = { false }
        let megabyte = Data(Self.text(length: 1_000_000, &rng, lines: true).utf8)
        let png = Data((0..<1_000_000).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
        func seeded(_ id: String, kind: Clipboard.Kind, plain: Data?, native: Data?) -> Clipboard.Clip {
            store.record(id: id, kind: kind,
                         items: [.init(plain: plain, natives: native.map { [("public.png", $0)] } ?? [])],
                         imageData: nil, preview: kind == .image ? "image 1000×1000" : "one megabyte",
                         sourceBundleID: nil, sourceAppName: nil)
            store.flushIO()
            return store.clips.first { $0.id == id }!
        }
        let text = seeded("bench-1mb-text", kind: .text, plain: megabyte, native: nil)
        let image = seeded("bench-1mb-image", kind: .image, plain: nil, native: png)
        report("paste: read a 1 MB text clip off disk (itemData)", (0..<reps).map { _ in milliseconds { _ = store.itemData(text) } })
        report("paste: read a 1 MB image clip off disk (itemData)", (0..<reps).map { _ in milliseconds { _ = store.itemData(image) } })
        report("paste: a 1 MB text clip, read + board write", (0..<reps).map { _ in milliseconds { controller.paste(text, action: .plain) } })
        report("paste: a 1 MB image clip, read + board write", (0..<reps).map { _ in milliseconds { controller.paste(image, action: .plain) } })
    }

    // MARK: - Forgetting

    private func deleting(store: ClipboardStore, reps: Int) throws {
        let victims = store.clips.filter { !$0.isPinned && $0.kind == .text }.dropFirst(500).prefix(reps).map(\.id)
        var main: [Double] = [], mainCPU: [Double] = [], endToEnd: [Double] = []
        for id in victims {
            store.flushIO()
            let started = Self.now()
            let took = timed { store.delete(id) }
            main.append(took.wall)
            mainCPU.append(took.cpu)
            store.flushIO()
            endToEnd.append(Self.now() - started)
        }
        report("delete: one clip, main thread", main, cpu: mainCPU)
        report("delete: one clip, end to end (files removed)", endToEnd)

        var trimMain: [Double] = [], trimMainCPU: [Double] = [], trimEnd: [Double] = []
        for round in 0..<min(reps, 10) {
            for n in 0..<50 {
                let body = "to be trimmed \(round) \(n)"
                let data = Data(body.utf8)
                store.record(id: ClipboardStore.identity(for: data), kind: .text,
                             items: [.init(plain: data, natives: [])], imageData: nil, preview: body,
                             sourceBundleID: nil, sourceAppName: nil)
            }
            store.flushIO()
            let ceiling = store.clips.filter { !$0.isPinned }.count - 50
            let started = Self.now()
            let took = timed { store.trim(maxBytes: Int.max, maxItems: ceiling) }
            trimMain.append(took.wall)
            trimMainCPU.append(took.cpu)
            store.flushIO()
            trimEnd.append(Self.now() - started)
        }
        report("trim: 50 clips, main thread", trimMain, cpu: trimMainCPU)
        report("trim: 50 clips, end to end (files removed)", trimEnd)
    }
}
