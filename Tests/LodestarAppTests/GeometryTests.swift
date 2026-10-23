import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// design/03-geometry.md: one curve, one grid and the sizes everything is
/// cut to. The values are held here; the rules are held on the sources (no
/// literal geometry outside the tokens) and on every surface of the gallery
/// (nothing draws outside its frame, keys hug, a row's parts share a line).
final class GeometryTests: XCTestCase {
    override func tearDown() { GalleryLook.reset() }

    // MARK: - The values

    /// The ladder is anchored on the pill's own curve and each rung is the one
    /// above over φ²: 22, 8.40, 3.21.
    func testTheRadiiAreTheLadderOnThePillsCurve() {
        let phi = BarTheme.phi
        XCTAssertEqual(BarTheme.pillHeight, 44)
        XCTAssertEqual(BarTheme.surfaceRadius, 22)
        XCTAssertEqual(BarTheme.surfaceRadius, BarTheme.pillHeight / 2, "the pill's ends are the surface")
        XCTAssertEqual(BarTheme.controlRadius, BarTheme.surfaceRadius / (phi * phi), accuracy: 0.001)
        XCTAssertEqual(BarTheme.markRadius, BarTheme.controlRadius / (phi * phi), accuracy: 0.001)
        XCTAssertEqual(BarTheme.controlRadius, 8.40, accuracy: 0.01)
        XCTAssertEqual(BarTheme.markRadius, 3.21, accuracy: 0.01)
        XCTAssertEqual(BarTheme.hairlineRadius(width: 1.5), 0.75, "half its width")
    }

    func testANestedThingRoundsAtTheOuterRadiusLessItsInset() {
        let surface = BarTheme.surfaceRadius, control = BarTheme.controlRadius
        XCTAssertEqual(BarTheme.nested(outer: surface, inset: 12, rung: control), 10, "a row or a field 12 inside a pane")
        XCTAssertEqual(BarTheme.paneRowRadius, 10)
        XCTAssertEqual(BarTheme.nested(outer: 10, inset: 12, rung: control), control,
                       "a key in a row falls below its own rung and keeps it")
        XCTAssertEqual(BarTheme.nested(outer: surface, inset: 40, rung: BarTheme.markRadius), BarTheme.markRadius)
        // The gap between the two curves is even all the way round.
        for inset in Grid.steps where inset < surface - control {
            XCTAssertEqual(surface - BarTheme.nested(outer: surface, inset: inset, rung: control), inset, accuracy: 0.001)
        }
    }

    func testAViewShorterThanTwiceItsRadiusIsAStadium() {
        XCTAssertEqual(BarTheme.radius(BarTheme.surfaceRadius, height: 44), 22)
        XCTAssertEqual(BarTheme.radius(BarTheme.surfaceRadius, height: 28), 14)
        XCTAssertEqual(BarTheme.radius(BarTheme.surfaceRadius, height: 96), 22)
    }

    func testAControlThatHoldsWordsPadsTwelveAndAChevronStandsEightFromThem() {
        XCTAssertEqual(BarTheme.wordPadding, 12)
        XCTAssertEqual(BarTheme.wordPadding, Grid.part)
        XCTAssertEqual(BarTheme.chevronGap, 8)
        XCTAssertEqual(BarTheme.chevronGap, Grid.close)
        let button = RoomButton(title: "Open", target: nil, action: nil)
        let words = button.attributedTitle.size().width
        XCTAssertEqual(button.intrinsicContentSize.width, (words + 24).rounded(.up), "12 at each side")
        XCTAssertEqual(Grid.half, 6, "a key or a chip keeps the half-step")
    }

    func testTheGridIsTheStepsOfTheContract() {
        XCTAssertEqual(Grid.steps, [2, 4, 8, 12, 16, 24, 32, 48])
        XCTAssertEqual(Grid.half, 6)
        XCTAssertFalse(Grid.steps.contains(Grid.half), "the half-step is only inside a control")
    }

    func testTheSizesAreTheContractsTable() {
        XCTAssertEqual(BarTheme.panelWidth, 640)
        XCTAssertEqual(BarTheme.inputHeight, 60)
        XCTAssertEqual(BarTheme.rowHeight, 48)
        XCTAssertEqual(BarTheme.pillHeight, 44)
        XCTAssertEqual(BarTheme.keyHeight, 24)
        XCTAssertEqual(BarTheme.appIconSize, 32)
        XCTAssertEqual(BarTheme.symbolSize, 16)
        XCTAssertGreaterThanOrEqual(BarTheme.minTarget, 24)
        XCTAssertEqual(BarTheme.measure, 380)
        XCTAssertEqual(Key("a").fittingSize.height, BarTheme.keyHeight)
        XCTAssertEqual(ModePill.height, BarTheme.pillHeight)
    }

    // MARK: - No literal geometry

    /// Files whose numbers are not layout: the tokens themselves, and
    /// artwork drawn in its own units (the app's icon, the menu bar's star,
    /// the lit mark).
    private static let exempt: Set<String> = ["Geometry.swift", "AppIconArt.swift", "StatusIcon.swift", "LitMark.swift"]

    /// What a geometry literal sits in: a gap, an inset, a constraint's
    /// constant, a frame, a radius, a size, arithmetic on a frame's edge, or a
    /// named constant that is a gap.
    static let contexts: [(String, String)] = [
        ("a spacing", #"\bspacing\s*=\s*[^\n]*"#),
        ("a constraint's constant", #"\bconstant:[^\n,)]*"#),
        ("a constraint's size", #"ToConstant:[^\n,)]*"#),
        ("a custom spacing", #"setCustomSpacing\([^\n,]*"#),
        ("insets", #"NSEdgeInsets\([^\n]*"#),
        ("a frame or a size", #"\b(?:NSRect|CGRect|NSSize|CGSize|NSPoint|CGPoint|NSMakeRect|NSMakeSize|NSMakePoint)\([^\n]*"#),
        ("an inset or an offset", #"\b(?:insetBy|offsetBy)\([^\n]*"#),
        ("a radius", #"\b(?:xRadius|yRadius|cornerRadius|cornerWidth|cornerHeight)\s*[:=][^\n,)]*"#),
        ("a dimension", #"\b(?:width|height|dx|dy|x|y)\s*:[^\n,)]*"#),
        ("arithmetic on an edge", #"\b(?:width|height|minX|maxX|midX|minY|maxY|midY)\s*[-+*]\s*[0-9][^\n,)]*"#),
        ("a gap, an inset or a margin", #"(?i:padding|inset|margin|gap|pad|gutter)\w*\s*(?::\s*CGFloat)?\s*=\s*[^\n]*"#),
    ]

    /// The numbers that may stand: nothing, and a hairline. A factor of two
    /// (both sides, half) is not a gap.
    private static func isAllowed(_ value: Double, before: Character?) -> Bool {
        if [0, 0.5, 1].contains(abs(value)) { return true }
        return abs(value) == 2 && (before == "*" || before == "/")
    }

    private static let literal = try! NSRegularExpression(pattern: #"(?<![\w.])-?[0-9]+(?:\.[0-9]+)?(?![\w.]*\w)"#)

    /// A named constant declared once, as a member: its value is the token.
    /// (A name that is a gap, an inset or a margin is still held to the grid.)
    private static let namedConstant = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:private|fileprivate|internal|public)\s+)?static\s+(?:let|var)\s"#)

    /// Every number in `text` that is not allowed, with its context.
    static func offenders(in text: String) throws -> [String] {
        var found: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(line)
            let whole = NSRange(location: 0, length: (line as NSString).length)
            let named = namedConstant.firstMatch(in: line, range: whole) != nil
            for (what, pattern) in contexts where !named || what == "a gap, an inset or a margin" {
                let regex = try NSRegularExpression(pattern: pattern)
                for match in regex.matches(in: line, range: whole) {
                    let region = (line as NSString).substring(with: match.range) as NSString
                    for number in literal.matches(in: region as String, range: NSRange(location: 0, length: region.length)) {
                        let value = Double(region.substring(with: number.range)) ?? 0
                        var before: Character?
                        var index = number.range.location - 1
                        while index >= 0 {
                            let character = Character(region.substring(with: NSRange(location: index, length: 1)))
                            if character != " " { before = character; break }
                            index -= 1
                        }
                        if !isAllowed(value, before: before) { found.append("\(what): \(region.trimmingCharacters(in: .whitespaces))") }
                    }
                }
            }
        }
        return found
    }

    /// The source without its comments and without what is compiled only into
    /// a debug build (a preview stages a scene for the eye), and without the
    /// lines that cast a shadow, which the material contract will own.
    static func layoutCode(_ raw: String) -> String {
        var depth = 0
        var kept: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if depth > 0 {
                if trimmed.hasPrefix("#if") { depth += 1 } else if trimmed.hasPrefix("#endif") { depth -= 1 }
                kept.append("")
            } else if trimmed == "#if DEBUG" {
                depth = 1
                kept.append("")
            } else {
                kept.append(String(line))
            }
        }
        let lines = DesignDriftTests.code(kept.joined(separator: "\n")).split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { line in
            let lower = line.lowercased()
            return lower.contains("shadow") || lower.contains("softshape") ? "" : String(line)
        }.joined(separator: "\n")
    }

    /// A radius, a gap, an inset or a size in layout code names a token: the
    /// theme's, or a constant named for what it is. A number written where it
    /// is used fails the build, except 0 and a hairline.
    func testNoLayoutCodeWritesANumberWhereATokenBelongs() throws {
        var found: [String] = []
        for file in DesignDriftTests.swiftFiles(under: DesignDriftTests.appSources)
        where !Self.exempt.contains(file.lastPathComponent) {
            let text = Self.layoutCode(try String(contentsOf: file, encoding: .utf8))
            for hit in try Self.offenders(in: text) { found.append("\(file.lastPathComponent): \(hit)") }
        }
        XCTAssertEqual(found, [], "name a step (Grid), a rung (BarTheme.*Radius, BarTheme.nested) or a size from Geometry.swift")
    }

    func testTheGeometryGuardCatchesWhatItNames() throws {
        let samples = [
            "stack.spacing = 10", "view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14)",
            "icon.widthAnchor.constraint(equalToConstant: 18)", "stack.setCustomSpacing(8, after: last)",
            "stack.edgeInsets = NSEdgeInsets(top: 6, left: 2, bottom: 6, right: 2)",
            "let frame = NSRect(x: 12, y: 0, width: w, height: h)", "rect.insetBy(dx: 5, dy: 1)",
            "layer.cornerRadius = 16.8", "label.frame = NSRect(x: pad, y: 0, width: bounds.width - 20, height: 4)",
            "let x = bounds.width + 3", "static let gap: CGFloat = 10",
        ]
        for sample in samples {
            XCTAssertFalse(try Self.offenders(in: sample).isEmpty, "the guard misses: \(sample)")
        }
        let allowed = [
            "stack.spacing = Grid.close", "constant: -BarTheme.paneInset", "constant: 0", "constant: -1",
            "NSEdgeInsets(top: 0, left: Grid.part, bottom: 0, right: Grid.part)", "let centre = bounds.width / 2",
            "rect.insetBy(dx: 0.5, dy: 0.5)", "layer.cornerRadius = BarTheme.controlRadius", "width: pad * 2",
            "static let gap = Grid.part", "line.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)",
        ]
        for sample in allowed {
            XCTAssertEqual(try Self.offenders(in: sample), [], "the guard flags what the tokens do: \(sample)")
        }
        XCTAssertEqual(try Self.offenders(in: Self.layoutCode("#if DEBUG\nstack.spacing = 10\n#endif\nstack.spacing = Grid.part")), [],
                       "a debug preview is exempt")
        XCTAssertEqual(try Self.offenders(in: Self.layoutCode("layer.shadowOffset = CGSize(width: 0, height: -4)")), [],
                       "a shadow is the material contract's")
    }

    func testNoSurfaceNamesAnOldAliasForARadius() throws {
        var found: [String] = []
        let aliases = #"\b(?:glassRadius|rowRadius|chipRadius|wellRadius|highlightRadius|glassChipRadius)\b|BarTheme\.hairlineRadius\b[^(]|surfaceRadius\s*=\s*pillHeight\s*/\s*\("#
        for file in DesignDriftTests.swiftFiles(under: DesignDriftTests.appSources) {
            let text = DesignDriftTests.code(try String(contentsOf: file, encoding: .utf8))
            if text.range(of: aliases, options: .regularExpression) != nil { found.append(file.lastPathComponent) }
        }
        XCTAssertEqual(found, [], "every radius is a rung of the ladder or the nesting helper")
    }

    // MARK: - On every surface

    /// The frame of `view` in `root`'s coordinates.
    private func frame(of view: NSView, in root: NSView) -> NSRect { view.convert(view.bounds, to: root) }

    private func walk(_ view: NSView, _ visit: (NSView) -> Void) {
        visit(view)
        for sub in view.subviews { walk(sub, visit) }
    }

    /// Whether `view` is inside something that scrolls or draws its own
    /// contents: its geometry is the scroll view's, not the layout's.
    private func isInsideScroller(_ view: NSView) -> Bool {
        var up: NSView? = view.superview
        while let current = up {
            if current is NSScrollView || current is NSClipView || current is NSTextView { return true }
            up = current.superview
        }
        return false
    }

    /// Views that are placed outside their parent on purpose: the drawn
    /// shadow's host (the window is the surface plus its margin) and what it
    /// hosts.
    private func hangsByDesign(_ view: NSView) -> Bool {
        view is ObjectSurface || String(describing: type(of: view)).contains("ShadowHost")
    }

    /// Every view of every gallery surface, in both looks, held to the rules
    /// of design/03-geometry.md that a picture can show.
    func testEverySurfaceKeepsTheGeometryRules() throws {
        var outside: [String] = [], shadows: [String] = [], keys: [String] = [], empty: [String] = []
        var rows: [String] = [], targets: [String] = [], words: [String] = [], checked = 0
        var counts = ["shadows": 0, "key columns": 0, "empty": 0, "settings rows": 0, "word controls": 0, "raised rows": 0, "targets": 0]
        for look in GalleryLook.all {
            look.apply()
            for shot in GalleryShots.all where shot.looks.contains(look) {
                guard let (root, keep) = try? shot.build(look) else { continue }
                // The sheets paint by drawing; the rules are for what is laid out.
                if shot.surface == "foundation" { continue }
                checked += 1
                let name = shot.name(in: look)
                root.window?.contentView?.layoutSubtreeIfNeeded()
                root.layoutSubtreeIfNeeded()
                let bounds = root.bounds.insetBy(dx: -0.5, dy: -0.5)

                // Nothing hangs outside its parent, and nothing's shadow or lip
                // reaches past the surface it stands in.
                walk(root) { view in
                    guard view !== root, !view.isHidden, let parent = view.superview else { return }
                    if isInsideScroller(view) || hangsByDesign(view) || hangsByDesign(parent) { return }
                    if parent.bounds.isEmpty || String(describing: type(of: view)).contains("KeyboardFocus") { return }
                    // A label's frame is wider than the line it draws by its cell's padding;
                    // what must stay inside is what it aligns.
                    let inParent = view.alignmentRect(forFrame: view.frame)
                    if !parent.bounds.insetBy(dx: -0.5, dy: -0.5).contains(inParent), inParent.width > 0, inParent.height > 0 {
                        outside.append("\(name): \(type(of: view)) \(inParent.integral) leaves \(type(of: parent)) \(parent.bounds.integral)")
                    }
                    if let layer = view.layer, layer.shadowOpacity > 0, layer.shadowRadius <= 8 {
                        counts["shadows", default: 0] += 1
                        let reach = layer.shadowRadius + abs(layer.shadowOffset.height)
                        let drawn = frame(of: view, in: root).insetBy(dx: -layer.shadowRadius, dy: -reach)
                        if !bounds.contains(drawn) {
                            shadows.append("\(name): \(type(of: view)) draws \(drawn.integral) past the surface \(root.bounds.integral)")
                        }
                    }
                }

                // A key is as wide as its legend needs and no wider, square at
                // the least: nothing stretches it.
                walk(root) { view in
                    guard let key = view as? Key, !key.isHidden else { return }
                    counts["key columns", default: 0] += 1
                    if key.frame.width > key.width + 0.5 {
                        keys.append("\(name): key \"\(key.legend)\" is \(key.frame.width) wide, its legend needs \(key.width)")
                    }
                }

                // A column with nothing in it takes no space.
                walk(root) { view in
                    guard let stack = view as? NSStackView, !stack.isHidden, !isInsideScroller(stack) else { return }
                    let shown = stack.arrangedSubviews.filter { !$0.isHidden }
                    counts["empty", default: 0] += shown.isEmpty ? 1 : 0
                    if shown.isEmpty, stack.frame.width * stack.frame.height > 0.5 {
                        empty.append("\(name): an empty stack is \(stack.frame.integral)")
                    }
                }

                // A row's leading key or icon, its title and its trailing
                // control share the centre of the title's first line.
                walk(root) { view in
                    if view.identifier?.rawValue == "settings.row", let line = view.subviews.first {
                        var title: NSTextField?
                        walk(line) { if title == nil, let field = $0 as? NSTextField, field.typeStyle?.role == .label { title = field } }
                        guard let title else { return }
                        counts["settings rows", default: 0] += 1
                        let centre = frame(of: title, in: root).midY
                        for part in line.subviews where part.superview === line && !(part is NSStackView && part.subviews.contains { $0 === title.superview }) {
                            guard !part.isHidden else { continue }
                            let first = (part as? NSStackView)?.arrangedSubviews.first ?? part
                            let mid = frame(of: first, in: root).midY
                            if abs(mid - centre) > 0.5 {
                                rows.append("\(name): \(type(of: part)) \(mid) is off the title's \(centre)")
                            }
                        }
                    }
                    if view is RaisedRow, !(view is RaisedRow && String(describing: type(of: view)).contains("Landing")) {
                        var title: NSTextField?
                        walk(view) { if title == nil, let field = $0 as? NSTextField, field.typeStyle?.role == .title, !field.isHidden { title = field } }
                        guard let title else { return }
                        counts["raised rows", default: 0] += 1
                        let centre = frame(of: title, in: root).midY
                        walk(view) { part in
                            guard !part.isHidden, part is Key || (part is NSImageView && !(part.superview is NSTextField)) else { return }
                            if part is NSImageView, part.superview?.superview is Key { return }
                            let mid = frame(of: part, in: root).midY
                            if abs(mid - centre) > 0.5 {
                                rows.append("\(name): \(type(of: part)) \(mid) is off the title's \(centre)")
                            }
                        }
                    }
                }

                // A control that holds words pads 12 at its sides, and a popup's
                // chevron stands 8 from its words.
                walk(root) { view in
                    if let popup = view as? NSPopUpButton, !popup.isHidden, popup.bounds.width > 0,
                       let cell = popup.cell as? NSPopUpButtonCell {
                        counts["word controls", default: 0] += 1
                        let title = cell.titleRect(forBounds: popup.bounds)
                        if abs(title.minX - BarTheme.wordPadding) > 0.5 {
                            words.append("\(name): a popup's words start \(title.minX) in")
                        }
                        let chevron = popup.subviews.compactMap { $0 as? NSImageView }.first
                        if let chevron {
                            if abs((popup.bounds.width - chevron.frame.maxX) - BarTheme.wordPadding) > 0.5 {
                                words.append("\(name): a popup's chevron is \(popup.bounds.width - chevron.frame.maxX) from the border")
                            }
                            if chevron.frame.minX - title.maxX < BarTheme.chevronGap - 0.5 {
                                words.append("\(name): a popup's chevron is \(chevron.frame.minX - title.maxX) from its words")
                            }
                        }
                    }
                    if let button = view as? RoomButton, !button.isHidden, button.bounds.width > 0 {
                        counts["word controls", default: 0] += 1
                        let room = button.bounds.width - button.attributedTitle.size().width
                        if room < BarTheme.wordPadding * 2 - 0.5 {
                            words.append("\(name): a button pads \(room / 2) at its sides")
                        }
                    }
                }

                // Anything clickable is at least 24 by 24.
                walk(root) { view in
                    guard let control = view as? NSControl, !(control is NSTextField), !(control is NSImageView), !control.isHidden,
                          !isInsideScroller(control) else { return }
                    let size = control.frame.size
                    counts["targets", default: 0] += 1
                    if size.width < BarTheme.minTarget - 0.5 || size.height < BarTheme.minTarget - 0.5 {
                        targets.append("\(name): \(type(of: control)) is \(size)")
                    }
                }
                _ = keep
            }
        }
        XCTAssertGreaterThan(checked, 100, "the gallery's surfaces were built")
        XCTAssertGreaterThan(counts["shadows"] ?? 0, 10, "keys and rows with a lip were looked at")
        XCTAssertGreaterThan(counts["key columns"] ?? 0, 50, "keys were looked at")
        XCTAssertGreaterThan(counts["settings rows"] ?? 0, 50, "settings rows were looked at")
        XCTAssertGreaterThan(counts["raised rows"] ?? 0, 10, "the bars' rows were looked at")
        XCTAssertGreaterThan(counts["targets"] ?? 0, 20, "clickable things were looked at")
        XCTAssertEqual(Array(Set(outside)).sorted(), [], "a view reserves the room for what it holds")
        XCTAssertEqual(Array(Set(shadows)).sorted(), [], "reserve room for a lip or a shadow's reach")
        XCTAssertEqual(Array(Set(keys)).sorted(), [], "a column of keys is as wide as its widest")
        XCTAssertEqual(Array(Set(empty)).sorted(), [], "a column with nothing in it takes no space")
        XCTAssertEqual(Array(Set(rows)).sorted(), [], "a row's parts share the title's first line")
        XCTAssertGreaterThan(counts["word controls"] ?? 0, 10, "popups and buttons were looked at")
        XCTAssertEqual(Array(Set(words)).sorted(), [], "a control that holds words pads 12")
        XCTAssertEqual(Array(Set(targets)).sorted(), [], "anything clickable is 24 by 24 at least")
    }

    /// Nested things round at the outer radius less their inset: the launcher's
    /// rows, a Settings group's rows, a Keep card's swatch and sheets, the
    /// walk's tiles and Feedback's note.
    func testWhatIsNestedRoundsConcentrically() throws {
        GalleryLook.day.apply()
        func radii(of shot: String, state: String, where match: (NSView) -> Bool) throws -> [CGFloat] {
            let made = try XCTUnwrap(GalleryShots.all.first { $0.surface == shot && $0.state == state }, "\(shot)-\(state)")
            let (root, keep) = try made.build(.day)
            root.window?.contentView?.layoutSubtreeIfNeeded()
            root.layoutSubtreeIfNeeded()
            var out: [CGFloat] = []
            walk(root) { if match($0), let layer = $0.layer { out.append(layer.cornerRadius) } }
            _ = keep
            return out
        }
        let row = BarTheme.paneRowRadius
        let launcher = try radii(of: "launcher", state: "results-second-chosen") { $0 is RaisedRow }
        XCTAssertFalse(launcher.isEmpty)
        XCTAssertTrue(launcher.allSatisfy { abs($0 - row) < 0.01 }, "a launcher row is 12 inside the pane: \(launcher)")
        let commands = try radii(of: "commands", state: "typed-pa") { $0 is RaisedRow }
        XCTAssertTrue(commands.allSatisfy { abs($0 - row) < 0.01 }, "and so is a commands row: \(commands)")
        let settings = try radii(of: "settings", state: "general") { $0 is RaisedRow }
        XCTAssertTrue(settings.allSatisfy { abs($0 - row) < 0.01 }, "and a settings row: \(settings)")
        XCTAssertEqual(ClipboardStrip.insideRadius(rung: BarTheme.controlRadius), row, "a swatch in a Keep card")
        XCTAssertEqual(ClipboardStrip.insideRadius(rung: BarTheme.markRadius), row, "and a sheet in it")
        XCTAssertEqual(BarTheme.nested(outer: BarTheme.surfaceRadius, inset: Grid.section, rung: BarTheme.controlRadius),
                       BarTheme.controlRadius, "a tile or a note a room's inset inside its room keeps its own rung")
    }
}
