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
/// a shot stages a real panel and lets it land, so the same hundred and fifty
/// shots were built twenty times over, and a CI runner half as fast as a desk
/// ran those test classes past any shard's time. A sweep takes its shot from
/// here; one that changes the surface it is given builds it itself with
/// `shot.build`, which is always fresh.
///
/// A built shot stands in a window that follows the application's look (a
/// panel has none of its own); a kept one is given its look as its own, so
/// that the application's turning does not reach it, and it is served only
/// while its look is the one in force. Eye comfort is part of what it was
/// built at: a sweep that does not set it builds a dimmed shot at full level.
///
/// A shot built with a caret in it is a picture that cannot be drawn twice:
/// a sweep that draws it brings its window in to hold the keys and puts it
/// away, which ends the editing the shot was built in, so the next draw is
/// not the one a fresh build gives. Such a shot is kept for the sweeps that
/// only read its views (`drawing: false`, the default) and built afresh for
/// the sweeps that draw it or change it, and those fresh builds are not kept.
enum GalleryBuilds {
    private struct Kept {
        let made: (view: NSView, keep: [AnyObject])
        /// Built with no caret in it: nothing a sweep does to it changes the next draw.
        let quiet: Bool
    }

    private nonisolated(unsafe) static var kept: [String: Kept] = [:]

    static func key(_ shot: GalleryShot, _ look: GalleryLook) -> String {
        let eye = EyeComfortState.shared
        return "\(shot.name(in: look))|\(eye.enabled)|\(eye.level)"
    }

    /// The shot built for `look`, which is in force: this process's one build
    /// of it at the Eye comfort now set, made now if there is none.
    /// `drawing`: the sweep draws it or changes it, which a shot with a caret
    /// in it does not survive (see above).
    static func built(_ shot: GalleryShot, in look: GalleryLook,
                      drawing: Bool = false) throws -> (view: NSView, keep: [AnyObject]) {
        // A look that is not in force would be built on a ground it is not
        // drawn on, and kept for one that is.
        guard NSApplication.shared.appearance?.name == look.appearance else { return try shot.build(look) }
        let key = key(shot, look)
        if let entry = kept[key], entry.made.view.window != nil, entry.quiet || !drawing { return entry.made }
        let before = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        let made = try shot.build(look)
        let quiet = isQuiet(made)
        if quiet || !drawing {
            // A kept window is its look's, whichever look the application is in: left to
            // follow the application, every turn of the look (and every test's end puts
            // it back) would lay out and redraw all of them, a second or more each time
            // with the whole gallery kept, and the next picture would be read before it landed.
            for window in NSApplication.shared.windows where !before.contains(ObjectIdentifier(window)) && window.appearance == nil {
                window.appearance = NSAppearance(named: look.appearance)
            }
            kept[key] = Kept(made: made, quiet: quiet)
        }
        return made
    }

    /// Whether a built shot is a picture that stays as it was built: one with
    /// no caret in it.
    static func isQuiet(_ made: (view: NSView, keep: [AnyObject])) -> Bool {
        let windows = [made.view.window] + made.keep.map { $0 as? NSWindow }
        return !windows.contains { $0?.firstResponder is NSText }
    }

    /// Let go of every one, as a test that changed what they stand on must.
    static func discard() { kept = [:] }
}

extension GalleryShot {
    /// This shot as a sweep takes it: built once per process.
    func built(in look: GalleryLook, drawing: Bool = false) throws -> (view: NSView, keep: [AnyObject]) {
        try GalleryBuilds.built(self, in: look, drawing: drawing)
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
    private nonisolated(unsafe) static var nativeKey = 0

    /// A window that keeps the display's own scale. The well's cells are
    /// drawn with a caret one and a half points wide, and on a 1x display
    /// that caret is not found in the picture of the 2x one the window says
    /// it has, while it is in a 1x picture of itself.
    static func keepNative(_ window: NSWindow) {
        objc_setAssociatedObject(window, &nativeKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func pin() {
        guard !pinned, let method = class_getInstanceMethod(NSWindow.self, #selector(getter: NSWindow.backingScaleFactor))
        else { return }
        pinned = true
        let scale = GalleryRender.scale
        typealias Getter = @convention(c) (AnyObject, Selector) -> CGFloat
        let original = unsafeBitCast(method_getImplementation(method), to: Getter.self)
        let block: @convention(block) (NSWindow) -> CGFloat = { window in
            objc_getAssociatedObject(window, &nativeKey) != nil
                ? original(window, #selector(getter: NSWindow.backingScaleFactor)) : scale
        }
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

    /// The main run loop has nothing left to do: every block queued on the main
    /// queue has run, and every block those queued, and so on, until two passes
    /// in a row find nothing waiting. `limit` is a guard against a hang and never
    /// a wait; nothing here sleeps.
    ///
    /// Each pass handles what is ready and returns at once, so a surface that
    /// stages itself over any number of turns (a preview's `async`, a layout
    /// that asks for another) is done in as many passes as it took, not in
    /// the time someone guessed.
    static func drain(limit: TimeInterval = 30) {
        let deadline = Date().addingTimeInterval(limit)
        var idle = 0
        while idle < 2, Date() < deadline {
            idle = CFRunLoopRunInMode(.defaultMode, 0, true) == .handledSource ? 0 : idle + 1
        }
    }

    /// `view` and its window laid out now, as the next frame would lay them
    /// out, so that what a rule reads is where the surface puts it and not
    /// where it stood before the last turn of the loop.
    static func layOut(_ view: NSView) {
        view.window?.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
    }

    /// What can be seen of `windows` and everything in them: where each stands,
    /// and for each view its kind, its place, whether it shows, and the words and
    /// the picture it holds. Two readings that are the same are two turns of the
    /// loop that had nothing left to land, and two windows that read the same are
    /// the same surface.
    static func appearance(of windows: [NSWindow]) -> Int {
        var hasher = Hasher()
        hasher.combine(windows.count)
        func visit(_ view: NSView) {
            // The system's own caret indicator comes and goes with the key window,
            // and is no part of what a surface shows.
            if String(describing: type(of: view)).hasPrefix("NSTextInsertionIndicator")
                || String(describing: type(of: view)).hasPrefix("NSTextIndicatorOverlay") { return }
            hasher.combine(ObjectIdentifier(type(of: view)))
            hasher.combine(view.frame.origin.x)
            hasher.combine(view.frame.origin.y)
            hasher.combine(view.frame.size.width)
            hasher.combine(view.frame.size.height)
            hasher.combine(view.isHidden)
            if let field = view as? NSTextField {
                hasher.combine(field.attributedStringValue.string)
                hasher.combine(field.font?.fontName)
            } else if let image = view as? NSImageView {
                hasher.combine(image.image != nil)
            } else if let text = view as? NSTextView {
                hasher.combine(text.string)
            }
            view.subviews.forEach(visit)
        }
        for window in windows {
            hasher.combine(window.frame.origin.x)
            hasher.combine(window.frame.origin.y)
            hasher.combine(window.frame.size.width)
            hasher.combine(window.frame.size.height)
            window.contentView.map(visit)
        }
        return hasher.finalize()
    }

    /// Turn the loop until `windows` stop changing: the main queue is drained,
    /// they are laid out and drawn, and that is repeated until `rounds` in a row
    /// leave them exactly as the round before did. Nothing in it waits for a
    /// time to pass; a surface that has landed is done in as many turns as it
    /// took to land. `limit` only keeps a hang from holding the run for ever,
    /// and a surface still changing at the limit is settled as it stands.
    ///
    /// `windows` is asked again each round, because a surface may make its
    /// window on a later turn than the one that asked for it.
    ///
    /// `landed` is for what the loop cannot see coming: work a surface has handed
    /// to a task or a queue, which lands on a turn nothing has yet asked for. A
    /// surface that says it is still waiting is waited for, however still it looks.
    @discardableResult
    static func settle(_ windows: () -> [NSWindow], landed: () -> Bool = { true }, rounds: Int = 3,
                       limit: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(limit)
        var last = appearance(of: windows())
        var quiet = 0
        while quiet < rounds {
            guard Date() < deadline else { return false }
            drain(limit: max(0.1, deadline.timeIntervalSinceNow))
            let now = windows()
            for window in now {
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            let seen = appearance(of: now)
            quiet = seen == last && landed() ? quiet + 1 : 0
            last = seen
        }
        return true
    }

    /// Whether what a surface was built from has nothing in flight. Feedback
    /// hands its note to a task when it is sent, and is a different surface
    /// (saved, or thanked) when the answer comes back.
    static func landed(_ kept: [AnyObject]) -> Bool {
        !kept.contains { ($0 as? FeedbackController)?.isSending == true }
    }

    /// The same for the windows of `views`, which a test has changed (its look,
    /// its words) and now reads.
    @discardableResult
    static func settle(_ views: NSView...) -> Bool {
        settle({ views.compactMap(\.window) })
    }

    /// The same for `windows` themselves.
    @discardableResult
    static func settle(_ windows: NSWindow...) -> Bool {
        settle({ windows })
    }

    /// The window `body` made that stands for the surface: the biggest, put
    /// away at once so nothing reaches the screen.
    ///
    /// A surface stages itself on a later turn (a preview's `async`), so the
    /// window is waited for, not assumed: the loop is turned until a window
    /// that matches has been made and has a size and stands as it will, and
    /// no longer (`settle`). A fixed beat was what this waited on once, and it
    /// was a guess at how long a desk took: on a runner half as fast it was
    /// over before the surface was made, and on a desk it was most of the
    /// time.
    static func surface(made body: () -> [AnyObject],
                        where match: (NSWindow) -> Bool = { _ in true },
                        frame: NSRect? = nil) throws -> (NSView, [AnyObject]) {
        DisplayScale.pin()
        let before = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        func made() -> [NSWindow] { NSApplication.shared.windows.filter { !before.contains(ObjectIdentifier($0)) } }
        func drawn(_ window: NSWindow) -> Bool {
            match(window) && window.frame.width > 0 && window.frame.height > 0 && window.contentView != nil
        }
        let kept = body()
        // Until a window is there to settle, the loop is turned for it, to the
        // same limit.
        let deadline = Date().addingTimeInterval(10)
        while !made().contains(where: drawn), Date() < deadline { drain(limit: 10) }
        settle(made, landed: { landed(kept) })
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
        try withPresentationFrame(Stage.screen) { try barSurface(query: query, chosen: chosen) }
    }

    private static func barSurface(query: String, chosen: Int) throws -> (NSView, [AnyObject]) {
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
        // The bar stands as the next frame would lay it out. Left with its layout pending, it is
        // laid out by whichever turn of the run loop comes first, and that is not always a turn
        // of this build's own: making the next launcher key waits on the input method, and the
        // loop it turns while it waits lays out every window with a layout owed, this one among
        // them. A kept build whose rows move when another is made is not one a reader is served.
        GalleryHost.settle(panel)
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
