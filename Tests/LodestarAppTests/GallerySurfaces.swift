import AppKit
import ObjectiveC
import XCTest
@testable import lodestar
@testable import LodestarCore

/// One picture to take: what it shows, in which state, and how to build it
/// in the look in force. Built fresh per look, so a colour, a shadow and a
/// weight are the ones the look asks for.
struct GalleryShot {
    let surface: String
    var state: String
    let looks: [GalleryLook]
    /// Cut away the transparent window around the surface (a panel handed a
    /// whole display), keeping its drawn shadow.
    var trim = false
    /// Draw the surface's children one at a time (see `bitmapBySiblings`).
    var bySiblings = false
    /// The Eye comfort level the surface is drawn at: 1 is full, 0.88 is
    /// the evening and 0.80 bedtime (design/06-eye-comfort.md).
    var level = 1.0
    /// The pill or the chip drawn after twenty seconds alone.
    var receded = false
    /// The view to capture, standing in a window the closure keeps alive
    /// through `keep`.
    let build: (GalleryLook) throws -> (view: NSView, keep: [AnyObject])

    func name(in look: GalleryLook) -> String { "\(surface)-\(state)-\(look.name)" }
}

/// The pictures a sweep reads, each built once for the process.
///
/// A sweep walks every shot in both looks, and a dozen of them do: building
/// a shot stages a real panel and lets the run loop settle (a tenth of a
/// second and more), so the same hundred and fifty shots were built twenty
/// times over, and a CI runner half as fast as a desk ran those test classes
/// past any shard's time. A sweep that only reads (measures, walks, draws)
/// takes its shot from here; one that changes the surface it is given builds
/// it itself with `shot.build`, which is always fresh.
///
/// A built shot stands in a window that follows the application's look (a
/// panel has none of its own), so one is kept and served only while its own
/// look is the one in force, and Eye comfort is part of what it was built
/// at: a sweep that does not set it builds a dimmed shot at full level.
enum GalleryBuilds {
    private nonisolated(unsafe) static var kept: [String: (view: NSView, keep: [AnyObject])] = [:]

    static func key(_ shot: GalleryShot, _ look: GalleryLook) -> String {
        let eye = EyeComfortState.shared
        return "\(shot.name(in: look))|\(eye.enabled)|\(eye.level)"
    }

    /// The shot built for `look`, which is in force: this process's one build
    /// of it at the Eye comfort now set, made now if there is none.
    static func built(_ shot: GalleryShot, in look: GalleryLook) throws -> (view: NSView, keep: [AnyObject]) {
        // A look that is not in force would be built on a ground it is not
        // drawn on, and kept for one that is.
        guard NSApplication.shared.appearance?.name == look.appearance else { return try shot.build(look) }
        let key = key(shot, look)
        if let made = kept[key], made.view.window != nil { return made }
        let made = try shot.build(look)
        kept[key] = made
        return made
    }

    /// Let go of every one, as a test that changed what they stand on must.
    static func discard() { kept = [:] }
}

extension GalleryShot {
    /// This shot as a read-only sweep takes it: built once per process.
    func built(in look: GalleryLook) throws -> (view: NSView, keep: [AnyObject]) {
        try GalleryBuilds.built(self, in: look)
    }
}

/// The scale every window reports in the suite: the gallery's own
/// (`GalleryRender.scale`), not that of whichever display the suite runs on.
///
/// A window nobody can see still answers `backingScaleFactor` from the main
/// display, and a legend, a rim or a line of words snaps itself to that
/// scale's pixels. On a runner's 1x display a capital stood a quarter point
/// off the keys beside it, and a word half a point off the middle of its slab,
/// where at the desk's 2x, with the same code, they stand true. The getter is
/// replaced once per process, for every window, the production panels the
/// harness stages among them.
enum DisplayScale {
    private nonisolated(unsafe) static var pinned = false

    static func pin() {
        guard !pinned, let method = class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.backingScaleFactor))
        else { return }
        pinned = true
        let scale = GalleryRender.scale
        let block: @convention(block) (NSWindow) -> CGFloat = { _ in scale }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}

/// What the harness builds around a surface that is not a panel of its own.
enum GalleryHost {
    /// A borderless window of the look, `size` points, holding `content`.
    static func window(_ content: NSView, size: NSSize, look: GalleryLook) -> NSWindow {
        DisplayScale.pin()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: look.appearance)
        window.isReleasedWhenClosed = false
        content.frame = NSRect(origin: .zero, size: size)
        content.autoresizingMask = [.width, .height]
        window.contentView = content
        return window
    }

    /// A pane (a surface of its own, the ceramic every panel is) with
    /// `content` laid out in it by the caller's constraints, at `size`.
    static func pane(size: NSSize, fill pane: CeramicPane.Fill = .pane, look: GalleryLook,
                     _ fill: (NSView) -> Void) -> NSWindow {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        Ceramic.installPane(in: root, cornerRadius: BarTheme.surfaceRadius, fill: pane)
        fill(root)
        return window(root, size: size, look: look)
    }

    /// The panels `body` made, in the order they came: the windows the
    /// application did not have before.
    static func windows(made body: () -> Void) -> [NSWindow] {
        let before = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        body()
        return NSApplication.shared.windows.filter { !before.contains(ObjectIdentifier($0)) }
    }

    /// Let the run loop turn for a beat: what a surface defers to the next
    /// turn (a staged preview, a settled layout) lands.
    ///
    /// Everything already queued on the main queue runs first, however long
    /// that takes, and then the beat is turned in full. A beat alone is a
    /// time the run loop is given, not work it is made to do: a turn that goes
    /// to other work (a look changing across every window the process still
    /// holds, which is more of them with each test that ran before) can use it
    /// up and leave a staged surface for after the beat, so that the picture
    /// is taken of a window that is not made yet, in a full run and never alone.
    static func settle(_ seconds: TimeInterval = 0.12) {
        var drained = false
        DispatchQueue.main.async { drained = true }
        let deadline = Date().addingTimeInterval(30)
        while !drained, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The window `body` made that stands for the surface: the biggest, put
    /// away at once so nothing reaches the screen.
    ///
    /// A surface stages itself on a later turn (a preview's `async`), so the
    /// window is waited for, not assumed: the beat is turned, and then more
    /// of them until a window that matches has been made and has a size, up
    /// to ten seconds. On a runner half as fast as a desk the beat alone was
    /// over before the surface was made.
    static func surface(made body: () -> [AnyObject], settle beat: TimeInterval = 0.12,
                        where match: (NSWindow) -> Bool = { _ in true },
                        frame: NSRect? = nil) throws -> (NSView, [AnyObject]) {
        DisplayScale.pin()
        let before = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        func made() -> [NSWindow] { NSApplication.shared.windows.filter { !before.contains(ObjectIdentifier($0)) } }
        func drawn(_ window: NSWindow) -> Bool {
            match(window) && window.frame.width > 0 && window.frame.height > 0 && window.contentView != nil
        }
        let kept = body()
        settle(beat)
        let deadline = Date().addingTimeInterval(10)
        while !made().contains(where: drawn), Date() < deadline { settle(0.05) }
        let windows = made()
        windows.forEach { $0.orderOut(nil) }
        let panel = try XCTUnwrap(windows.filter(match).max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height },
                                  "the surface made a window")
        // A surface that is staged without being opened is sized as opening
        // would size it.
        if let frame { panel.setPaneFrame(frame, display: false) }
        return (try XCTUnwrap(panel.contentView), kept + [panel])
    }
}

// MARK: - Keys

enum GalleryKeys {
    /// Every kind of legend a key carries: a letter, a descender, a capital,
    /// a glyph, a digit, a word, a chord, a mark of punctuation.
    static let legends = ["a", "e", "g", "s", "y", "A", "⏎", "⇧", "1", "9", "esc", "⌘K", "tab", "⌫", "↑", "space", "lode",
                          "'", "`", ";", "/", ".", ",", "-", "="]

    /// A row of separate keys, 8 apart, centred on the face of whatever carries it.
    static func row(_ legends: [String], configure: (Key) -> Void = { _ in }) -> (NSStackView, [Key]) {
        let keys = legends.map { legend -> Key in
            let key = Key(legend)
            configure(key)
            return key
        }
        let stack = NSStackView(views: keys)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Grid.close
        stack.translatesAutoresizingMaskIntoConstraints = false
        return (stack, keys)
    }

    static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.setRole(.meta)
        label.textColor = BarTheme.secondaryColor
        return label
    }

    /// Every legend kind in all three states and both sizes, a sequence, a
    /// double tap, a chord, alternatives and punctuation, on the pane and on
    /// a chosen row, and a key named in a sentence.
    static func sheet(look: GalleryLook) -> (NSWindow, [AnyObject]) {
        let size = NSSize(width: 1120, height: 900)
        var keys: [Key] = []
        let window = GalleryHost.pane(size: size, look: look) { root in
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = Grid.part
            column.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(column)
            NSLayoutConstraint.activate([
                column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Grid.section),
                column.topAnchor.constraint(equalTo: root.topAnchor, constant: Grid.section),
            ])
            func line(_ title: String, _ legends: [String], _ configure: @escaping (Key) -> Void = { _ in }) {
                column.addArrangedSubview(caption(title))
                let (stack, made) = row(legends, configure: configure)
                keys += made
                column.addArrangedSubview(stack)
            }
            func group(_ title: String, _ views: [NSView], spacing: CGFloat = Grid.section) {
                column.addArrangedSubview(caption(title))
                let stack = NSStackView(views: views)
                stack.orientation = .horizontal
                stack.alignment = .centerY
                stack.spacing = spacing
                stack.translatesAutoresizingMaskIntoConstraints = false
                column.addArrangedSubview(stack)
            }
            line("standard, 24 tall: resting", legends)
            line("lit", legends) { $0.state = .lit }
            line("quiet: no face, a hairline, quiet ink", legends) { $0.state = .quiet }

            // Large, in every state.
            let figures = ["7", "3", "10"]
            let large = [KeyState.resting, .lit, .quiet].flatMap { state in
                figures.map { figure -> Key in
                    let key = Key(figure, size: .large, state: state)
                    keys.append(key)
                    return key
                }
            }
            group("large, 36 tall: resting, lit, quiet", large, spacing: Grid.close)

            // Sequences, double taps, chords, alternatives.
            let sequence = Keycaps.strokes(["e", "p"])
            let launcher = Keycaps.strokes(["lode", "e", "p"])
            let double = Keycaps.strokes(["lode"], double: true)
            let litDouble = Keycaps.strokes(["lode"], double: true, lit: true)
            let chords = ["⌘K", "⌥J", "⌥⇧⌘V", "⇧A"].map { Key($0) }
            keys += chords
            let alternatives = KeyStrokes(groups: [["h"], ["j"], ["k"], ["l"]])
            let ways = KeyStrokes(groups: [["z", "o"], ["z", "c"]])
            keys += [sequence, launcher, double, litDouble, alternatives, ways].flatMap(\.caps)
            group("a sequence: a key a keystroke, 4 apart · a double tap: one key and ×2",
                  [sequence, launcher, double, litDouble] as [NSView], spacing: Grid.section)
            group("a chord is one key, as macOS writes it · alternatives and ways stand 8 apart",
                  chords + [alternatives, ways] as [NSView], spacing: Grid.section)

            // The same keys on a chosen row, the slab: keys of the other look.
            column.addArrangedSubview(caption("on the chosen row, the slab"))
            let chosen = ListRow(height: BarTheme.rowHeight)
            chosen.choose(true)
            column.addArrangedSubview(chosen)
            let (onRow, made) = row(legends)
            // Only the key that acts lights on the slab: one ⏎, the rest rest.
            let enter = Key("⏎")
            enter.lit = true
            keys += made + [enter]
            chosen.setTrailing([onRow, enter])
            chosen.widthAnchor.constraint(equalToConstant: 1070).isActive = true

            // The walk's keyboard: separate keys, 8 apart, each as wide as its legend.
            column.addArrangedSubview(caption("a keyboard row, as the walk draws it: each key as wide as what it says"))
            let board = ["fn", "⌃", "⌥", "⌘", "space", "⌘", "⌥"].map { Key($0) }
            board[4].lit = true
            board[5].lit = true
            keys += board
            let boardRow = NSStackView(views: board)
            boardRow.orientation = .horizontal
            boardRow.alignment = .centerY
            boardRow.spacing = Grid.close
            column.addArrangedSubview(boardRow)

            // A key named in a sentence is written as typed.
            column.addArrangedSubview(caption("a key named in a sentence: ◎ Breath jk saved · ✕ lode e q is not on the graph · Press a, and the newest pastes"))
        }
        return (window, [window] + keys)
    }

    static var shots: [GalleryShot] {
        [GalleryShot(surface: "keycaps", state: "all", looks: GalleryLook.all) { look in
            let (window, keep) = sheet(look: look)
            return (window.contentView!, keep)
        }]
    }
}

// MARK: - The launcher

/// The window world the launcher needs to stand: a model nobody tracks,
/// the layout and the parking lot over a display of fixed size, a state
/// store in a scratch directory.
final class GalleryWorld {
    let directory: URL
    let model: WindowModel
    let hud = HUD()
    let actions: Actions
    let appIndex = AppIndex()

    init(model: WindowModel = WindowModel()) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lodestar-gallery-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.model = model
        let parking = ParkingLot(mover: AXMover(), bounds: { [Stage.screen] })
        let layout = LayoutController(model: model, parking: parking, mover: AXMover())
        actions = Actions(model: model, parking: parking, layout: layout, appIndex: appIndex,
                          store: SealedFixture.stateStore(directory.appendingPathComponent("state.json")), hud: hud)
        // Apps every Mac has, in the order a person's hands would have them.
        let boosts = ["com.apple.Safari": 9.0, "com.apple.mail": 8, "com.apple.Notes": 7, "com.apple.MobileSMS": 6,
                      "com.apple.iCal": 5, "com.apple.Terminal": 4, "com.apple.systempreferences": 3]
        appIndex.usageBoost = { boosts[$0 ?? ""] ?? 0 }
        appIndex.refresh()
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

enum GalleryLauncher {
    /// The addresses the sample graph teaches.
    static let addresses = ["safari": ["s"], "mail": ["e", "p"], "notes": ["n"], "messages": ["m"], "calendar": ["c"],
                            "terminal": ["t"], "system settings": ["g", "s"]]

    static func find<T: NSView>(_ type: T.Type, in view: NSView?, where match: (T) -> Bool = { _ in true }) -> T? {
        guard let view else { return nil }
        if let hit = view as? T, match(hit) { return hit }
        for sub in view.subviews { if let hit = find(type, in: sub, where: match) { return hit } }
        return nil
    }

    /// The launcher as it stands for `query`, the `chosen`th row chosen.
    static func bar(query: String, chosen: Int, look: GalleryLook) throws -> (NSView, [AnyObject]) {
        ActivePolicy.frameOverride = Stage.screen
        let world = GalleryWorld()
        var made: SearcherController?
        let panels = GalleryHost.windows {
            made = SearcherController(appIndex: world.appIndex, actions: world.actions, model: world.model)
            made?.graphAddress = { addresses[$0] }
            made?.show()
        }
        let searcher = try XCTUnwrap(made)
        let panel = try XCTUnwrap(panels.first(where: { $0 is KeyablePanel }), "the launcher's panel")
        panel.orderOut(nil)
        if !query.isEmpty, let field = find(NSTextField.self, in: panel.contentView, where: { $0.isEditable }) {
            field.stringValue = query
            // As typed: the caret stands at the end of the words.
            field.currentEditor()?.selectedRange = NSRange(location: (query as NSString).length, length: 0)
            searcher.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
        for _ in 0..<chosen {
            let field = find(NSTextField.self, in: panel.contentView, where: { $0.isEditable })
            _ = searcher.control(try XCTUnwrap(field), textView: NSTextView(),
                                 doCommandBy: #selector(NSResponder.moveDown(_:)))
        }
        return (try XCTUnwrap(panel.contentView), [searcher, world, panel])
    }

    static var shots: [GalleryShot] {
        func bar(_ state: String, query: String, chosen: Int) -> GalleryShot {
            GalleryShot(surface: "launcher", state: state, looks: GalleryLook.all) { look in
                try Self.bar(query: query, chosen: chosen, look: look)
            }
        }
        return [
            bar("results-second-chosen", query: "", chosen: 1),
            bar("results-first-chosen", query: "", chosen: 0),
            bar("typed-ma", query: "ma", chosen: 0),
            bar("no-match", query: "zzq", chosen: 0),
        ]
    }
}
