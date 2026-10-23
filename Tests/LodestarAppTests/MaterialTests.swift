import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// design/04-material.md. The values of the pane live in `PaneTests`; this
/// holds the rules: nothing is glass and nothing lets the desktop through,
/// every pressable thing stands on a side, every well has none, every flat
/// thing neither, and pressing gives a side up to a point.
final class MaterialTests: XCTestCase {
    override func tearDown() { GalleryLook.reset() }

    // MARK: - Opaque (rule 1)

    /// What names the glass, a visual effect or vibrancy, or a transparency
    /// setting to honour: none of it is in what ships. A debug preview, which
    /// stages a scene for the eye and is compiled out of a release build, may.
    private static let glassPatterns: [(String, String)] = [
        ("a glass type", #"NSGlassEffect\w*|TonedGlass"#),
        ("a visual effect", #"NSVisualEffect\w*|\.blendingMode|\.material\s*="#),
        ("vibrancy", #"[vV]ibrancy|\.vibrant(Light|Dark)|\.withVibrancy"#),
        ("a transparency setting", #"reduceTransparency|ShouldReduceTransparency"#),
        ("a veil", #"\bveil(Alpha)?\b"#),
    ]

    private func glassOffenders(in text: String) throws -> [String] {
        var found: [String] = []
        for (what, pattern) in Self.glassPatterns {
            let regex = try NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) {
                found.append("\(what): \((text as NSString).substring(with: match.range))")
            }
        }
        return found
    }

    func testNothingIsGlassVisualEffectOrVibrancyOutsideDebugPreviews() throws {
        var found: [String] = []
        for file in DesignDriftTests.swiftFiles(under: DesignDriftTests.appSources) {
            let raw = try String(contentsOf: file, encoding: .utf8)
            if Self.isDebugOnly(raw) { continue }
            for hit in try glassOffenders(in: DesignDriftTests.code(raw)) { found.append("\(file.lastPathComponent): \(hit)") }
        }
        XCTAssertEqual(found, [], "an opaque pane: no glass, no blur, no vibrancy, no transparency setting")
    }

    func testTheGlassGuardCatchesWhatItNames() throws {
        for sample in ["let g = NSGlassEffectView()", "NSGlassEffectContainerView()", "let e = NSVisualEffectView()",
                       "effect.blendingMode = .behindWindow", "effect.material = .popover", "view.allowsVibrancy",
                       "Accessibility.reduceTransparency()", "final class TonedGlass", "veil.alpha = 0.9"] {
            XCTAssertFalse(try glassOffenders(in: sample).isEmpty, "the guard misses: \(sample)")
        }
        for sample in ["Ceramic.installPane(in: root, cornerRadius: 22)", "panel.backgroundColor = .clear",
                       "layer.shadowColor = shadow"] {
            XCTAssertEqual(try glassOffenders(in: sample), [], "the guard flags what the material does: \(sample)")
        }
    }

    /// A file that is wholly a debug harness.
    private static func isDebugOnly(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.first == "#if DEBUG" && lines.last == "#endif"
    }

    /// A window is clear only to leave room for its pane's shadow and to
    /// curve its corners: whatever makes one not opaque hosts its pane on
    /// `SoftShadow`, which draws the shadow in that margin, or is the
    /// marks laid over another app's window, which are keys, not panes.
    func testAClearWindowIsOnlyTheMarginOfAnOpaquePane() throws {
        let notPanes: Set<String> = ["EditorMarks.swift", "Ceramic.swift"]
        var found: [String] = []
        for file in DesignDriftTests.swiftFiles(under: DesignDriftTests.appSources) {
            let raw = try String(contentsOf: file, encoding: .utf8)
            if Self.isDebugOnly(raw) || notPanes.contains(file.lastPathComponent) { continue }
            let text = DesignDriftTests.code(raw)
            if text.contains("isOpaque = false"), !text.contains("SoftShadow.host(") { found.append(file.lastPathComponent) }
        }
        XCTAssertEqual(found, [], "a clear window hosts an opaque pane on SoftShadow, or it is no surface")
    }

    /// The step every pane, face and well is made of is opaque, in both looks.
    func testEveryFillOfTheMaterialIsOpaque() throws {
        let fills: [(String, NSColor)] = [("pane", BarTheme.paneFill), ("face", BarTheme.faceFill),
                                          ("side", BarTheme.sideFill), ("well", BarTheme.wellFill)]
        for look in GalleryLook.all {
            NSAppearance(named: look.appearance)!.performAsCurrentDrawingAppearance {
                for (name, color) in fills {
                    XCTAssertEqual(color.usingColorSpace(.sRGB)?.alphaComponent ?? 0, 1, accuracy: 0.0001,
                                   "\(look.name): the \(name) lets nothing through")
                }
            }
        }
    }

    /// A panel from the gallery: every point inside the pane, clear of its
    /// corners, is opaque, so nothing of the desktop shows through the ceramic.
    func testNoPanelLetsTheDesktopThrough() throws {
        var checked = 0
        for look in GalleryLook.all {
            look.apply()
            for shot in GalleryShots.all where shot.looks.contains(look) && shot.surface != "foundation" {
                guard let (view, keep) = try? shot.build(look), let host = view as? ShadowHostView else { continue }
                _ = keep
                let rep = GalleryRender.bitmap(of: host)
                let scale = CGFloat(rep.pixelsWide) / rep.size.width
                let pane = host.bounds.insetBy(dx: SoftShadow.margin, dy: SoftShadow.margin)
                    .insetBy(dx: BarTheme.surfaceRadius, dy: BarTheme.surfaceRadius)
                guard pane.width > 0, pane.height > 0 else { continue }
                var clear: [String] = []
                for fx in stride(from: 0.0, through: 1.0, by: 0.1) {
                    for fy in stride(from: 0.0, through: 1.0, by: 0.1) {
                        let point = CGPoint(x: pane.minX + pane.width * fx, y: pane.minY + pane.height * fy)
                        let x = Int(point.x * scale), y = Int((rep.size.height - point.y) * scale)
                        guard (0..<rep.pixelsWide).contains(x), (0..<rep.pixelsHigh).contains(y),
                              let color = rep.colorAt(x: x, y: y) else { continue }
                        if color.alphaComponent < 0.999 { clear.append("\(point)") }
                    }
                }
                XCTAssertEqual(clear, [], "\(shot.name(in: look)) is opaque inside its pane")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 20, "the panels of the gallery were looked at")
    }

    // MARK: - Thickness over shadow, no gradients, no glows (rules 4 and 5)

    /// Pressability is a side, never a shadow: a shadow falls only from a
    /// floating pane. The theme casts it; a content picture and a file's
    /// sheet keep the shadows of content; the app's own artwork has its own.
    func testOnlyThePanesAndContentCastAShadow() throws {
        let casters: Set<String> = ["Ceramic.swift", "Material.swift", "ClipboardStrip.swift", "AppIconArt.swift"]
        var found: [String] = []
        for file in DesignDriftTests.swiftFiles(under: DesignDriftTests.appSources) where !casters.contains(file.lastPathComponent) {
            let raw = try String(contentsOf: file, encoding: .utf8)
            if Self.isDebugOnly(raw) { continue }
            let text = DesignDriftTests.code(raw)
            if text.range(of: #"\.shadow(Opacity|Radius|Offset|Color|Path)\b"#, options: .regularExpression) != nil {
                found.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(found, [], "a pane casts its shadow through PaneShadow; a key has a side, not a shadow")
        // What the theme itself casts is the pane's, and a picture's.
        let ceramic = DesignDriftTests.code(try String(contentsOf: DesignDriftTests.appSources.appendingPathComponent("Ceramic.swift"), encoding: .utf8))
        let shadows = ceramic.components(separatedBy: ".shadowOpacity").count - 1
        XCTAssertEqual(shadows, 1, "the theme file shades only the picture; the pane's shadow is Material.swift's")
    }

    /// The one fade that remains is the Settings scroll's foot, a mask whose
    /// alpha alone is read; and the overview's pool of light around its mark,
    /// part of that picture. Nothing else in chrome is shaded.
    func testNoChromeIsShadedByAGradientButTheScrollFootsMask() throws {
        let settings = DesignDriftTests.code(try String(
            contentsOf: DesignDriftTests.appSources.appendingPathComponent("SettingsController.swift"), encoding: .utf8))
        XCTAssertEqual(settings.components(separatedBy: "CAGradientLayer()").count - 1, 2,
                       "the scroll foot's mask and the mark's pool, and no third")
        XCTAssertTrue(settings.contains("scroll.layer?.mask = fade"), "the fade is a mask, never a colour")
        for file in DesignDriftTests.swiftFiles(under: DesignDriftTests.appSources) where file.lastPathComponent != "SettingsController.swift" {
            let raw = try String(contentsOf: file, encoding: .utf8)
            if Self.isDebugOnly(raw) { continue }
            let text = DesignDriftTests.code(raw)
            XCTAssertFalse(text.contains("CAGradientLayer") || text.contains("NSGradient("),
                           "\(file.lastPathComponent): a face is one colour, a well one colour and an edge")
        }
    }

    // MARK: - Depth by role (rule 3)

    private func walk(_ view: NSView, _ visit: (NSView) -> Void) {
        visit(view)
        for sub in view.subviews { walk(sub, visit) }
    }

    /// Every pressable thing stands on a side, every well has none, every flat
    /// thing neither, across every surface of the gallery in both looks.
    func testDepthFollowsRoleOnEveryGallerySurface() throws {
        var counts = ["keys": 0, "quiet keys": 0, "buttons": 0, "popups": 0, "switches": 0, "rows": 0, "cards": 0,
                      "wells": 0, "chips": 0, "tiles": 0]
        var wrong: [String] = []
        for look in GalleryLook.all {
            look.apply()
            for shot in GalleryShots.all where shot.looks.contains(look) {
                guard let (root, keep) = try? shot.build(look) else { continue }
                _ = keep
                root.window?.contentView?.layoutSubtreeIfNeeded()
                root.layoutSubtreeIfNeeded()
                let name = shot.name(in: look)
                walk(root) { view in
                    guard !view.isHidden else { return }
                    func expect(_ role: Ceramic.Depth, as kind: String) {
                        guard let depth = view as? CeramicDepth else {
                            wrong.append("\(name): a \(kind) (\(type(of: view))) does not say its depth")
                            return
                        }
                        switch (role, depth.depth) {
                        case (.standsUp, .standsUp(let side)):
                            if depth.drawnSide < Ceramic.Side.pressed - 0.01 || depth.drawnSide > Ceramic.Side.large + 0.01 {
                                wrong.append("\(name): a \(kind) shows a side of \(depth.drawnSide)")
                            }
                            if abs(depth.drawnSide - side) > 0.01 { wrong.append("\(name): a \(kind) draws \(depth.drawnSide) of \(side)") }
                        case (.sinks, .sinks), (.flat, .flat):
                            if depth.drawnSide != 0 { wrong.append("\(name): a \(kind) has a side of \(depth.drawnSide)") }
                        default:
                            wrong.append("\(name): a \(kind) is \(depth.depth), not \(role)")
                        }
                    }
                    if let key = view as? KeyFace {
                        if key.quiet && !key.lit { counts["quiet keys", default: 0] += 1; expect(.flat, as: "quiet key") }
                        else { counts["keys", default: 0] += 1; expect(.standsUp(side: 0), as: "key") }
                    } else if view is RoomButton {
                        counts["buttons", default: 0] += 1
                        expect(.standsUp(side: 0), as: "button")
                    } else if view is NSPopUpButton {
                        counts["popups", default: 0] += 1
                        expect(.standsUp(side: 0), as: "popup")
                    } else if view is AccentSwitch {
                        counts["switches", default: 0] += 1
                        expect(.standsUp(side: 0), as: "switch's knob")
                    } else if let row = view as? RaisedRow {
                        counts["rows", default: 0] += 1
                        expect(row.raised ? .standsUp(side: 0) : .flat, as: "row")
                    } else if let pane = view as? CeramicPane, pane.side > 0 {
                        counts["cards", default: 0] += 1
                        expect(.standsUp(side: 0), as: "card")
                    } else if view is WellView || view is WellField {
                        counts["wells", default: 0] += 1
                        expect(.sinks, as: "well")
                    } else if view is FlatChip {
                        counts["chips", default: 0] += 1
                        expect(.flat, as: "chip")
                    } else if String(describing: type(of: view)) == "TileColumn" {
                        counts["tiles", default: 0] += 1
                        expect(.standsUp(side: 0), as: "tile")
                    }
                }
            }
        }
        XCTAssertEqual(Array(Set(wrong)).sorted(), [], "depth follows role")
        for (kind, count) in counts where kind != "tiles" {
            XCTAssertGreaterThan(count, 0, "\(kind) were looked at")
        }
        XCTAssertGreaterThan(counts["keys"] ?? 0, 100)
        XCTAssertGreaterThan(counts["rows"] ?? 0, 10)
    }

    /// A pressable thing that is not drawn through a type that says its
    /// depth would escape the test above: every system control a surface
    /// builds is one of Lodestar's.
    func testEveryPressableControlOfTheGalleryDeclaresItsDepth() throws {
        var undeclared: [String] = []
        for look in GalleryLook.all {
            look.apply()
            for shot in GalleryShots.all where shot.looks.contains(look) {
                guard let (root, keep) = try? shot.build(look) else { continue }
                _ = keep
                walk(root) { view in
                    // A borderless link or a hit-target button over a tile is not a drawn thing.
                    guard let button = view as? NSButton, !(view is HandButton), !(view is CeramicDepth),
                          !button.isHidden, button.title != "" || button.image != nil else { return }
                    undeclared.append("\(shot.name(in: look)): \(type(of: button))")
                }
            }
        }
        XCTAssertEqual(Array(Set(undeclared)).sorted(), [], "a button is a RoomButton, a key, a popup or a switch")
    }

    // MARK: - Pressing (the side's rule)

    func testPressingCollapsesAKeysSideToAPointAndTheFaceFollowsItDown() {
        GalleryLook.day.apply()
        let key = KeyFace("a")
        let window = GalleryHost.window(key, size: NSSize(width: 60, height: BarTheme.keyHeight), look: .day)
        func laidOut() { key.needsLayout = true; key.layoutSubtreeIfNeeded() }
        laidOut()
        let resting = key.standing.faceFrame
        let letter = key.label.frame.midY
        XCTAssertEqual(key.drawnSide, Ceramic.Side.control, "3 points at a control's size")
        XCTAssertEqual(key.depth, .standsUp(side: 3))
        key.fill(.pressed)
        laidOut()
        XCTAssertEqual(key.drawnSide, Ceramic.Side.pressed, "1 point at once, with no animation between")
        XCTAssertEqual(key.depth, .standsUp(side: 1))
        let pressed = key.standing.faceFrame
        XCTAssertEqual(pressed.height, resting.height, "the face keeps its size")
        XCTAssertEqual(resting.minY - pressed.minY, Ceramic.Side.control - Ceramic.Side.pressed,
                       "it moves down by what the side gave up")
        XCTAssertEqual(letter - key.label.frame.midY, Ceramic.Side.control - Ceramic.Side.pressed, accuracy: 0.01,
                       "and its letter goes with it")
        XCTAssertNil(key.layer?.animationKeys(), "nothing animates")
        key.fill(.resting)
        XCTAssertEqual(key.drawnSide, Ceramic.Side.control)
        _ = window
    }

    func testPressingAButtonAndAPeekKeyFollowTheSameRule() {
        GalleryLook.day.apply()
        let button = RoomButton(title: "Open", target: nil, action: nil)
        button.frame = NSRect(x: 0, y: 0, width: 80, height: BarTheme.minTarget)
        let window = GalleryHost.window(button, size: button.frame.size, look: .day)
        button.layoutSubtreeIfNeeded()
        XCTAssertEqual(button.drawnSide, Ceramic.Side.control)
        button.highlight(true)
        button.layoutSubtreeIfNeeded()
        XCTAssertEqual(button.drawnSide, Ceramic.Side.pressed, "held down: one point")
        button.highlight(false)
        XCTAssertEqual(button.drawnSide, Ceramic.Side.control)
        _ = window
        let large = KeyMark.key("7", peek: true) as? MarkKey
        XCTAssertEqual(large?.drawnSide, Ceramic.Side.large, "5 points at a large key")
        XCTAssertEqual(Ceramic.Side.row, 4, "4 at a row's size")
    }

    func testAQuietKeyLiesFlatWithAHairline() {
        GalleryLook.day.apply()
        let key = KeyFace("a")
        key.quiet = true
        XCTAssertEqual(key.depth, .flat)
        XCTAssertEqual(key.drawnSide, 0, "no side, and no well beneath it")
        XCTAssertNil(key.standing.faceColor.flatMap { $0.alpha > 0 ? $0 : nil }, "no fill of its own: the pane shows")
        XCTAssertNotNil(key.standing.edgeColor, "a hairline")
    }

    func testTheSidesAreTheContractsAndTheKnobStandsOnOne() {
        XCTAssertEqual([Ceramic.Side.control, Ceramic.Side.row, Ceramic.Side.large, Ceramic.Side.pressed], [3, 4, 5, 1])
        let knob = AccentSwitch()
        XCTAssertEqual(knob.depth, .standsUp(side: Ceramic.Side.control))
        XCTAssertEqual(knob.drawnSide, Ceramic.Side.control)
    }
}
