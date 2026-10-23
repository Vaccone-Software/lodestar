import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// One picture to take: what it shows, in which state, and how to build it
/// in the look in force. Built fresh per look, so a colour, a shadow and a
/// weight are the ones the look asks for.
struct GalleryShot {
    let surface: String
    let state: String
    let looks: [GalleryLook]
    /// Cut away the transparent window around the surface (a panel handed a
    /// whole display), keeping its drawn shadow.
    var trim = false
    /// Draw the surface's children one at a time (see `bitmapBySiblings`).
    var bySiblings = false
    /// The view to capture, standing in a window the closure keeps alive
    /// through `keep`.
    let build: (GalleryLook) throws -> (view: NSView, keep: [AnyObject])

    func name(in look: GalleryLook) -> String { "\(surface)-\(state)-\(look.name)" }
}

/// What the harness builds around a surface that is not a panel of its own.
enum GalleryHost {
    /// A borderless window of the look, `size` points, holding `content`.
    static func window(_ content: NSView, size: NSSize, look: GalleryLook) -> NSWindow {
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
    static func settle(_ seconds: TimeInterval = 0.12) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// The window `body` made that stands for the surface: the biggest, put
    /// away at once so nothing of it reaches the screen.
    static func surface(made body: () -> [AnyObject], settle beat: TimeInterval = 0.12,
                        where match: (NSWindow) -> Bool = { _ in true },
                        frame: NSRect? = nil) throws -> (NSView, [AnyObject]) {
        var kept: [AnyObject] = []
        let made = windows { kept = body(); settle(beat) }
        made.forEach { $0.orderOut(nil) }
        let panel = try XCTUnwrap(made.filter(match).max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height },
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
    /// a glyph, a digit, a word, an address, a chord, a mark of punctuation.
    static let legends = ["a", "e", "g", "s", "y", "A", "⏎", "⇧", "1", "9", "esc", "⌘K", "tab", "⌫", "↑", "space", "'", "`", ";", "/"]

    /// A row of keys in a stack, centred on the face of whatever carries it.
    static func row(_ legends: [String], configure: (KeyFace) -> Void = { _ in }) -> (NSStackView, [KeyFace]) {
        let keys = legends.map { legend -> KeyFace in
            let key = KeyFace(legend)
            configure(key)
            return key
        }
        let stack = NSStackView(views: keys)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return (stack, keys)
    }

    static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.setRole(.meta)
        label.textColor = BarTheme.secondaryColor
        return label
    }

    /// Keys of every legend, resting, lit, quiet and pressed, on the pane
    /// and on a chosen row, and the walk's keyboard row.
    static func sheet(look: GalleryLook) -> (NSWindow, [AnyObject]) {
        let size = NSSize(width: 1000, height: 480)
        var keys: [KeyFace] = []
        let window = GalleryHost.pane(size: size, look: look) { root in
            let column = NSStackView()
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 12
            column.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(column)
            NSLayoutConstraint.activate([
                column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
                column.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            ])
            func line(_ title: String, _ legends: [String], _ configure: @escaping (KeyFace) -> Void = { _ in }) {
                column.addArrangedSubview(caption(title))
                let (stack, made) = row(legends, configure: configure)
                keys += made
                column.addArrangedSubview(stack)
            }
            line("resting, on the pane", legends)
            line("lit", legends) { $0.lit = true }
            line("quiet", legends) { $0.quiet = true }
            line("pressed", legends) { $0.fill(.pressed) }
            // The same keys on a chosen row, the raised step.
            column.addArrangedSubview(caption("on the chosen row"))
            let chosen = RaisedRow(frame: .zero)
            chosen.translatesAutoresizingMaskIntoConstraints = false
            chosen.setupRaised()
            chosen.applyRaised(true)
            column.addArrangedSubview(chosen)
            let (onRow, made) = row(legends)
            let (litOnRow, litMade) = row(legends) { $0.lit = true }
            keys += made + litMade
            let both = NSStackView(views: [onRow, litOnRow])
            both.orientation = .vertical
            both.alignment = .leading
            both.spacing = 8
            both.translatesAutoresizingMaskIntoConstraints = false
            chosen.addSubview(both)
            NSLayoutConstraint.activate([
                chosen.widthAnchor.constraint(equalToConstant: 950),
                chosen.heightAnchor.constraint(equalToConstant: 80),
                both.leadingAnchor.constraint(equalTo: chosen.leadingAnchor, constant: 14),
                both.centerYAnchor.constraint(equalTo: chosen.centerYAnchor),
            ])
            // The walk's keyboard: the space bar is a key of the same size as
            // those beside it, only wider.
            column.addArrangedSubview(caption("the walk's keyboard row: the space bar is the chip's size, wider"))
            let board = ["fn", "⌃", "⌥", "⌘", "space", "⌘", "⌥"].map { legend -> KeyFace in
                KeyFace(legend, padX: legend == "space" ? 22 : Grid.half)
            }
            board[4].lit = true
            board[5].lit = true
            keys += board
            let boardRow = NSStackView(views: board)
            boardRow.orientation = .horizontal
            boardRow.alignment = .centerY
            boardRow.spacing = 4
            column.addArrangedSubview(boardRow)
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
    static let addresses = ["safari": "s", "mail": "e p", "notes": "n", "messages": "m", "calendar": "c",
                            "terminal": "t", "system settings": "g s"]

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
