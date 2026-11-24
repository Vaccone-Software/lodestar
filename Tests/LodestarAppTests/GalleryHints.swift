import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// A screen of click hints, the dense case the key contract puts on trial
/// (design/10-key.md, Open): a page of links, buttons and list rows, every
/// target wearing its two-letter hint, laid over as the door lays them.
///
/// The page under the hints is a stand-in for any busy web page: a nav bar,
/// a sidebar of links, tabs and filters, a list of rows with a title and an
/// author each, a rail of settings. Targets are the frames a page's links
/// really have (a text link is its text, a button its box, a sidebar row its
/// whole row), and the hints are the door's own: `SelectOverlay.compose` places
/// them, pinned at each target's top-left corner, with labels from
/// `HintLabels` on the home row. A hint is one key with its letters set tight.
final class MockPage: NSView {
    override var isFlipped: Bool { true }

    let night: Bool
    /// What a hand can press, in the page's own coordinates (top left origin).
    private(set) var targets: [CGRect] = []

    private var ground: NSColor { night ? NSColor(srgbRed: 0.05, green: 0.07, blue: 0.09, alpha: 1) : .white }
    private var panel: NSColor { night ? NSColor(srgbRed: 0.09, green: 0.11, blue: 0.14, alpha: 1) : NSColor(srgbRed: 0.97, green: 0.98, blue: 0.98, alpha: 1) }
    private var rule: NSColor { night ? NSColor(srgbRed: 0.19, green: 0.21, blue: 0.24, alpha: 1) : NSColor(srgbRed: 0.82, green: 0.84, blue: 0.87, alpha: 1) }
    private var text: NSColor { night ? NSColor(srgbRed: 0.90, green: 0.93, blue: 0.95, alpha: 1) : NSColor(srgbRed: 0.12, green: 0.14, blue: 0.16, alpha: 1) }
    private var quiet: NSColor { night ? NSColor(srgbRed: 0.55, green: 0.58, blue: 0.62, alpha: 1) : NSColor(srgbRed: 0.40, green: 0.44, blue: 0.48, alpha: 1) }
    private var link: NSColor { night ? NSColor(srgbRed: 0.27, green: 0.58, blue: 0.97, alpha: 1) : NSColor(srgbRed: 0.04, green: 0.41, blue: 0.85, alpha: 1) }
    private var fill: NSColor { night ? NSColor(srgbRed: 0.14, green: 0.45, blue: 0.27, alpha: 1) : NSColor(srgbRed: 0.10, green: 0.50, blue: 0.22, alpha: 1) }

    init(size: NSSize, night: Bool) {
        self.night = night
        super.init(frame: NSRect(origin: .zero, size: size))
        layoutTargets()
    }

    required init?(coder: NSCoder) { nil }

    private func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }

    /// One drawing pass records the targets and draws the page; `drawing` off
    /// only records.
    private var drawing = false

    private func layoutTargets() {
        targets = []
        paint(drawing: false)
    }

    override func draw(_ dirtyRect: NSRect) {
        paint(drawing: true)
    }

    private func paint(drawing: Bool) {
        self.drawing = drawing
        let width = bounds.width
        if drawing {
            ground.setFill(); bounds.fill()
        }
        // Nav bar.
        if drawing {
            panel.setFill(); NSRect(x: 0, y: 0, width: width, height: 56).fill()
            rule.setFill(); NSRect(x: 0, y: 56, width: width, height: 1).fill()
            fill.setFill()
            NSBezierPath(roundedRect: NSRect(x: 24, y: 14, width: 28, height: 28), xRadius: 7, yRadius: 7).fill()
        }
        var x: CGFloat = 72
        for name in ["Product", "Solutions", "Pricing", "Docs", "Blog"] {
            x += item(name, at: NSPoint(x: x, y: 18), size: 14, color: text, target: true).width + 28
        }
        box(NSRect(x: 640, y: 12, width: 280, height: 32), "Search the docs", radius: 8, text: quiet, border: true)
        _ = item("Sign in", at: NSPoint(x: 996, y: 18), size: 14, color: text, target: true)
        button(NSRect(x: 1084, y: 11, width: 96, height: 34), "Sign up", filled: true)

        // Sidebar.
        let side = ["Overview", "Issues", "Pull requests", "Actions", "Projects", "Wiki", "Security", "Insights", "Settings", "Releases"]
        for (index, name) in side.enumerated() {
            let row = NSRect(x: 16, y: 84 + CGFloat(index) * 36, width: 200, height: 32)
            if drawing, index == 2 {
                (night ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.06)).setFill()
                NSBezierPath(roundedRect: row, xRadius: 7, yRadius: 7).fill()
            }
            if drawing {
                quiet.setFill()
                NSBezierPath(roundedRect: NSRect(x: row.minX + 10, y: row.minY + 9, width: 14, height: 14), xRadius: 3, yRadius: 3).fill()
            }
            _ = item(name, at: NSPoint(x: row.minX + 34, y: row.minY + 7), size: 14, color: text, weight: index == 2 ? .semibold : .regular)
            record(row)
        }

        // Header, tabs, filters.
        _ = item("Pull requests", at: NSPoint(x: 256, y: 88), size: 24, color: text, weight: .semibold)
        button(NSRect(x: 1020, y: 84, width: 180, height: 36), "New pull request", filled: true)
        let open = tab("Open  12", at: NSPoint(x: 256, y: 144), selected: true)
        _ = tab("Closed  148", at: NSPoint(x: open.maxX + 12, y: 144), selected: false)
        var fx: CGFloat = 744
        for name in ["Author", "Label", "Projects", "Sort"] {
            let w = measure(name + "  ▾", 13) + 24
            button(NSRect(x: fx, y: 142, width: w, height: 30), name + "  ▾", filled: false)
            fx += w + 8
        }
        if drawing { rule.setFill(); NSRect(x: 256, y: 182, width: 744, height: 1).fill() }

        // The list: a title and an author a row, a label on some.
        let rows: [(String, String, String?)] = [
            ("Fix the retry loop when the queue drains", "#412 opened 2 days ago by mara", "bug"),
            ("Add pagination to the activity feed", "#409 opened 3 days ago by joel", nil),
            ("Upgrade the build image to the new toolchain", "#407 opened 3 days ago by ines", "infra"),
            ("Document the export format", "#403 opened 5 days ago by sam", "docs"),
            ("Stop logging the full request body", "#401 opened last week by priya", "security"),
            ("Cache the project list for a minute", "#398 opened last week by joel", nil),
            ("Rename the settings page route", "#396 opened last week by mara", nil),
            ("Handle an empty team in the invite flow", "#392 opened 2 weeks ago by ines", "bug"),
            ("Move the avatar upload off the main thread", "#390 opened 2 weeks ago by sam", nil),
            ("Show the last sync time on the dashboard", "#388 opened 2 weeks ago by priya", "ux"),
        ]
        for (index, row) in rows.enumerated() {
            let y = 192 + CGFloat(index) * 54
            let title = item(row.0, at: NSPoint(x: 256, y: y + 8), size: 15, color: text, weight: .semibold, target: true)
            if let label = row.2 {
                let w = measure(label, 12) + 16
                let pill = NSRect(x: 256 + title.width + 12, y: y + 8, width: w, height: 22)
                if drawing {
                    (night ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.07)).setFill()
                    NSBezierPath(roundedRect: pill, xRadius: 11, yRadius: 11).fill()
                    row.2!.draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + 3), withAttributes: [.font: font(12), .foregroundColor: text])
                }
                record(pill)
            }
            let by = row.1
            let name = String(by.split(separator: " ").last ?? "")
            let before = String(by.dropLast(name.count))
            let beforeWidth = measure(before, 13)
            _ = item(before, at: NSPoint(x: 256, y: y + 32), size: 13, color: quiet)
            _ = item(name, at: NSPoint(x: 256 + beforeWidth, y: y + 32), size: 13, color: link, target: true)
            if drawing { rule.setFill(); NSRect(x: 256, y: y + 52, width: 744, height: 1).fill() }
        }

        // The rail.
        for (index, name) in ["Assignees", "Labels", "Projects", "Milestone"].enumerated() {
            let y = 200 + CGFloat(index) * 64
            let row = NSRect(x: 1032, y: y, width: 220, height: 28)
            _ = item(name, at: NSPoint(x: row.minX, y: y + 5), size: 13, color: quiet, weight: .semibold)
            record(row)
            if drawing {
                _ = item(index == 0 ? "No one" : "None yet", at: NSPoint(x: row.minX, y: y + 30), size: 13, color: quiet)
            }
        }
    }

    // MARK: pieces

    private func measure(_ string: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font(size, weight)]).width)
    }

    private func record(_ rect: CGRect) { if !drawing { targets.append(rect) } }

    /// Text at a point; a link when `target`, whose frame is its text.
    @discardableResult
    private func item(_ string: String, at point: NSPoint, size: CGFloat, color: NSColor,
                      weight: NSFont.Weight = .regular, target: Bool = false) -> NSRect {
        let width = measure(string, size, weight)
        let height = ceil(size * 1.3)
        if drawing {
            (string as NSString).draw(at: point, withAttributes: [.font: font(size, weight), .foregroundColor: color])
        }
        let frame = NSRect(x: point.x, y: point.y, width: width, height: height)
        if target { record(frame) }
        return frame
    }

    private func box(_ rect: NSRect, _ label: String, radius: CGFloat, text color: NSColor, border: Bool) {
        if drawing {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            ground.setFill(); path.fill()
            rule.setStroke(); path.stroke()
            label.draw(at: NSPoint(x: rect.minX + 12, y: rect.minY + 8), withAttributes: [.font: font(14), .foregroundColor: color])
        }
        record(rect)
    }

    private func button(_ rect: NSRect, _ label: String, filled: Bool) {
        if drawing {
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            (filled ? fill : panel).setFill(); path.fill()
            if !filled { rule.setStroke(); path.stroke() }
            let size = (label as NSString).size(withAttributes: [.font: font(13, .semibold)])
            label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                       withAttributes: [.font: font(13, .semibold), .foregroundColor: filled ? NSColor.white : text])
        }
        record(rect)
    }

    private func tab(_ label: String, at point: NSPoint, selected: Bool) -> NSRect {
        let width = measure(label, 14, selected ? .semibold : .regular) + 24
        let rect = NSRect(x: point.x, y: point.y, width: width, height: 30)
        if drawing {
            label.draw(at: NSPoint(x: rect.minX + 12, y: rect.minY + 6),
                       withAttributes: [.font: font(14, selected ? .semibold : .regular), .foregroundColor: selected ? text : quiet])
            if selected { link.setFill(); NSRect(x: rect.minX, y: rect.maxY + 6, width: rect.width, height: 2).fill() }
        }
        record(rect)
        return rect
    }
}

enum GalleryHints {
    static let size = NSSize(width: 1280, height: 760)

    /// The door's own labels, on the home row, in reading order.
    static func labels(_ count: Int) -> [String] { HintLabels.labels(count: count, alphabet: HintLabels.homeRow) }

    /// The page with its hints. `typed` is what the hand has typed of them:
    /// only the hints it can still complete stand, their letters so far quiet.
    static func screen(night: Bool, typed: String) -> (NSView, [AnyObject]) {
        let page = MockPage(size: size, night: night)
        let rects = page.targets
        // Reading order: top to bottom, then left to right, in bands of a line.
        let ordered = rects.enumerated().sorted {
            let a = $0.element, b = $1.element
            if abs(a.minY - b.minY) > 10 { return a.minY < b.minY }
            return a.minX < b.minX
        }.map(\.element)
        let names = labels(ordered.count)
        let chips = zip(names, ordered).map { SelectOverlay.Chip(label: $0, frames: [$1], style: .target) }
        let overlay = NSView(frame: page.bounds)
        let made = SelectOverlay.compose(
            chips: chips, anchor: [], typed: typed, bounds: page.bounds, look: overlay,
            local: { NSRect(x: $0.minX, y: size.height - $0.maxY, width: $0.width, height: $0.height) })
        let marks = made.marks
        for view in made.underlays + marks { overlay.addSubview(view) }
        let host = NSView(frame: page.bounds)
        host.addSubview(page)
        host.addSubview(overlay)
        return (host, [page, overlay])
    }

    static func shot(_ state: String, typed: String) -> GalleryShot {
        GalleryShot(surface: "hints", state: state, looks: GalleryLook.all) { look in
            let (host, keep) = screen(night: look == .night, typed: typed)
            let window = GalleryHost.window(host, size: size, look: look)
            return (window.contentView!, keep + [window])
        }
    }

    static var shots: [GalleryShot] {
        [shot("dense", typed: ""), shot("dense-typed", typed: "j")]
    }
}
