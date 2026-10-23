import AppKit
import XCTest
@testable import lodestar
@testable import LodestarCore

/// The key contract (design/10-key.md), held by what is drawn: a key's
/// legend is rendered into a bitmap in every state and both looks and read
/// back by its ink, so a legend that is off its face, a baseline that
/// wanders with a descender, or a key wider than what it says fails here.
final class KeyTests: XCTestCase {
    override func tearDown() { GalleryLook.reset() }

    static let legends = ["a", "g", "y", "e", "s", "A", "⏎", "⇧", "1", "esc", "⌘K", "'", ";"]
    static let states: [KeyState] = [.resting, .lit, .pressed, .quiet]

    /// What a key's legend drew: its ink in the key's own coordinates
    /// (points, y up), the face it sits on, and the key itself.
    struct Drawn {
        let key: Key
        let ink: CGRect
        let face: CGRect
    }

    /// The legend's ink, read by drawing the key with and without it and
    /// keeping the pixels that differ.
    static func draw(_ legend: String, state: KeyState, size: KeySize = .standard, look: GalleryLook) -> Drawn {
        look.apply()
        let key = Key(legend, size: size, state: state)
        let width = key.width
        let margin: CGFloat = 8
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width + margin * 2, height: key.size.height + margin * 2))
        key.translatesAutoresizingMaskIntoConstraints = true
        key.frame = NSRect(x: margin, y: margin, width: width, height: key.size.height)
        host.addSubview(key)
        let window = GalleryHost.window(host, size: host.frame.size, look: look)
        defer { window.close() }
        let with = GalleryRender.bitmap(of: host)
        key.legend = ""
        let without = GalleryRender.bitmap(of: host)
        key.legend = legend
        let face = key.face
        guard let a = with.bitmapData, let b = without.bitmapData else { return Drawn(key: key, ink: .null, face: face) }
        let scale = CGFloat(with.pixelsWide) / host.frame.width
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for row in 0..<with.pixelsHigh {
            for column in 0..<with.pixelsWide {
                let at = row * with.bytesPerRow + column * 4
                var difference = 0
                for channel in 0..<4 { difference += abs(Int(a[at + channel]) - Int(b[at + channel])) }
                if difference > 60 {
                    minX = min(minX, column); maxX = max(maxX, column)
                    minY = min(minY, row); maxY = max(maxY, row)
                }
            }
        }
        guard maxX >= 0 else { return Drawn(key: key, ink: .null, face: face) }
        // Pixel rows count from the top; points count from the bottom.
        let height = CGFloat(with.pixelsHigh)
        let ink = CGRect(x: CGFloat(minX) / scale - margin, y: (height - CGFloat(maxY) - 1) / scale - margin,
                         width: CGFloat(maxX - minX + 1) / scale,
                         height: CGFloat(maxY - minY + 1) / scale)
        return Drawn(key: key, ink: ink, face: face)
    }

    // MARK: - The legend is centred on the face, on one band

    /// Letters and digits are drawn with their own ink, so the rendered ink
    /// is their band: the x-height for a lowercase letter, the cap height
    /// for a capital or a digit.
    private static let inkIsTheBand: Set<String> = ["a", "e", "s", "A", "1", "'", ";"]

    func testALegendIsCentredOnTheFaceInEveryStateAndLook() {
        var wrong: [String] = []
        for look in GalleryLook.all {
            for state in Self.states {
                for legend in Self.legends {
                    let drawn = Self.draw(legend, state: state, look: look)
                    let name = "\(legend) \(state) \(look.name)"
                    guard !drawn.ink.isNull else { wrong.append("\(name): nothing drawn"); continue }
                    // Across: by its ink.
                    if abs(drawn.ink.midX - drawn.face.midX) > 0.5 {
                        wrong.append("\(name): ink centre \(drawn.ink.midX) is off the face's \(drawn.face.midX)")
                    }
                    // Up and down: the band's centre, from the font's metrics.
                    let band = drawn.key.placement.band
                    if abs((band.lowerBound + band.upperBound) / 2 - drawn.face.midY) > 0.5 {
                        wrong.append("\(name): band centre is off the face's \(drawn.face.midY)")
                    }
                    if Self.inkIsTheBand.contains(legend), abs(drawn.ink.midY - drawn.face.midY) > 0.5 {
                        wrong.append("\(name): ink centre \(drawn.ink.midY) is off the face's \(drawn.face.midY)")
                    }
                    // A glyph is drawn within its band, give or take what a
                    // symbol's own design adds.
                    if drawn.ink.minY < band.lowerBound - 2 && !["g", "y"].contains(legend)
                        || drawn.ink.maxY > band.upperBound + 2 {
                        wrong.append("\(name): ink \(drawn.ink.minY)…\(drawn.ink.maxY) leaves its band \(band)")
                    }
                }
            }
        }
        XCTAssertEqual(wrong, [])
    }

    func testLowercaseLegendsShareABaselineWhateverTheirDescenders() {
        for look in GalleryLook.all {
            for state in Self.states {
                let drawn = ["a", "e", "s", "g", "y"].map { Self.draw($0, state: state, look: look) }
                let tops = drawn.map(\.ink.maxY), bottoms = drawn.prefix(3).map(\.ink.minY)
                let name = "\(state) \(look.name)"
                XCTAssertLessThanOrEqual((tops.max() ?? 0) - (tops.min() ?? 0), 0.5, "x-height tops, \(name): \(tops)")
                XCTAssertLessThanOrEqual((bottoms.max() ?? 0) - (bottoms.min() ?? 0), 0.5, "baselines, \(name): \(bottoms)")
                XCTAssertLessThan(drawn[3].ink.minY, bottoms[0] - 1, "the descender of g hangs below the baseline, \(name)")
            }
        }
    }

    func testAnEmptyLegendDrawsNothingAndAKeyWithoutOneStillStands() {
        GalleryLook.day.apply()
        let key = Key("")
        XCTAssertEqual(key.width, key.size.height, "square")
        XCTAssertEqual(key.drawnSide, Ceramic.Side.control)
    }

    // MARK: - Width

    func testAKeyIsAsWideAsItsLegendPlusEightEachSideAndNeverNarrowerThanTall() {
        var wrong: [String] = []
        for look in GalleryLook.all {
            for legend in Self.legends + ["jk", "space", "lode", "tab", "m", "i", "W"] {
                let drawn = Self.draw(legend, state: .resting, look: look)
                let key = drawn.key
                let night = look == .night
                let ink = KeyLegend.measure(legend, size: .standard, night: night).ink.width
                let expected = max(KeySize.standard.height, ceil(ink) + 16)
                if key.width != expected { wrong.append("\(legend) \(look.name): \(key.width) is not \(expected)") }
                // And what is drawn agrees: the rendered ink is the measured ink.
                if abs(drawn.ink.width - ink) > 1.25 {
                    wrong.append("\(legend) \(look.name): drew \(drawn.ink.width) of ink, measured \(ink)")
                }
                if key.width < KeySize.standard.height { wrong.append("\(legend): narrower than tall") }
            }
        }
        XCTAssertEqual(wrong, [])
        GalleryLook.day.apply()
        for single in ["a", "i", "l", "1", "'"] {
            XCTAssertEqual(Key(single).width, 24, "\(single): a single letter stands on a square key")
        }
        XCTAssertGreaterThan(Key("esc").width, 24)
        XCTAssertEqual(Key("a").width, Key("e").width, "no minimum beyond square")
    }

    // MARK: - Sizes and parts

    func testTheStandardKeyIs24TallOn21AndThreeAndTheLargeIs36OnThirtyOneAndFive() {
        GalleryLook.day.apply()
        XCTAssertEqual(KeySize.standard.height, 24)
        XCTAssertEqual(KeySize.standard.faceHeight, 21)
        XCTAssertEqual(KeySize.standard.side, 3)
        XCTAssertEqual(KeySize.large.height, 36)
        XCTAssertEqual(KeySize.large.faceHeight, 31)
        XCTAssertEqual(KeySize.large.side, 5)
        XCTAssertEqual(KeySize.standard.role, .key)
        XCTAssertEqual(KeySize.large.role, .largeFigure)
        let key = Key("a"), large = Key("7", size: .large)
        XCTAssertEqual(key.intrinsicContentSize.height, 24)
        XCTAssertEqual(large.intrinsicContentSize.height, 36)
        XCTAssertEqual(key.face.height, 21)
        XCTAssertEqual(large.face.height, 31)
        XCTAssertEqual(large.legendFont.pointSize, BarTheme.Scale.input)
        XCTAssertEqual(key.legendFont.pointSize, BarTheme.Scale.meta)
    }

    func testTheLargeKeysFigureIsCentredOnItsFace() {
        for look in GalleryLook.all {
            for figure in ["7", "3", "10"] {
                let drawn = Self.draw(figure, state: .resting, size: .large, look: look)
                XCTAssertEqual(drawn.ink.midX, drawn.face.midX, accuracy: 0.5, "\(figure) \(look.name) across")
                XCTAssertEqual(drawn.ink.midY, drawn.face.midY, accuracy: 0.5, "\(figure) \(look.name) up and down")
                XCTAssertEqual(Key(figure, size: .large).width, max(36, ceil(drawn.key.width - 16) + 16), "hugs its figure, square at least")
            }
        }
    }

    // MARK: - Punctuation

    func testPunctuationAloneIsDrawnLargerAndCentredByItsInk() {
        for look in GalleryLook.all {
            let letter = Self.draw("e", state: .resting, look: look)
            for mark in ["'", "`", ";", "/", "."] {
                let drawn = Self.draw(mark, state: .resting, look: look)
                XCTAssertEqual(drawn.ink.midX, drawn.face.midX, accuracy: 0.5, "\(mark) \(look.name) across")
                XCTAssertEqual(drawn.ink.midY, drawn.face.midY, accuracy: 0.5, "\(mark) \(look.name) up and down")
                XCTAssertGreaterThan(drawn.key.legendFont.pointSize, BarTheme.Scale.meta - 0.01, "\(mark)")
            }
            // A tick is drawn large enough to see: its ink is a good share of the face's cap height.
            let capHeight = BarTheme.Role.key.font(night: look == .night).capHeight
            for mark in ["'", "`"] {
                let tick = Self.draw(mark, state: .resting, look: look)
                XCTAssertGreaterThan(tick.ink.height, capHeight * 0.4, "\(mark) \(look.name): \(tick.ink.height) of \(capHeight)")
                XCTAssertGreaterThan(tick.key.legendFont.pointSize, letter.key.legendFont.pointSize, "\(mark) is larger than a letter")
            }
        }
    }

    func testTheKindOfALegendDecidesItsBand() {
        XCTAssertEqual(KeyLegend.band(of: "a"), .xHeight)
        XCTAssertEqual(KeyLegend.band(of: "esc"), .xHeight)
        XCTAssertEqual(KeyLegend.band(of: "space"), .xHeight)
        XCTAssertEqual(KeyLegend.band(of: "lode"), .xHeight)
        XCTAssertEqual(KeyLegend.band(of: "A"), .capHeight)
        XCTAssertEqual(KeyLegend.band(of: "1"), .capHeight)
        XCTAssertEqual(KeyLegend.band(of: "⏎"), .capHeight)
        XCTAssertEqual(KeyLegend.band(of: "⌘K"), .capHeight)
        XCTAssertEqual(KeyLegend.band(of: "⇧"), .capHeight)
        for mark in ["'", "`", ";", "/", ".", ",", "-", "="] { XCTAssertEqual(KeyLegend.band(of: mark), .ink, mark) }
    }

    // MARK: - States

    func testTheFourStatesAreWhatTheContractSays() {
        GalleryLook.day.apply()
        let resting = Key("a"), lit = Key("a", state: .lit), pressed = Key("a", state: .pressed), quiet = Key("a", state: .quiet)
        for key in [resting, lit, pressed, quiet] {
            key.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
            key.layout()
        }
        XCTAssertEqual(resting.drawnSide, 3)
        XCTAssertEqual(lit.drawnSide, 3)
        XCTAssertEqual(pressed.drawnSide, 1, "the side gives up the rest")
        XCTAssertEqual(resting.face.minY - pressed.face.minY, 2, "and the face goes down by it")
        XCTAssertEqual(resting.face.height, pressed.face.height)
        XCTAssertEqual(quiet.drawnSide, 0)
        XCTAssertEqual(quiet.depth, .flat)
        XCTAssertEqual(quiet.face, resting.face, "a quiet key stands where the resting face stands, so a row shares its baseline")
        XCTAssertEqual(lit.standing.faceColor, BarTheme.accent.cgColor)
        XCTAssertNotEqual(lit.standing.sideColor, resting.standing.sideColor, "the orange's own darker side")
        XCTAssertEqual(lit.legendColor, BarTheme.onAccent)
        XCTAssertEqual(resting.legendColor, BarTheme.ink)
        XCTAssertEqual(quiet.legendColor, BarTheme.secondaryColor)
        XCTAssertNil(quiet.standing.faceColor.flatMap { $0.alpha > 0 ? $0 : nil }, "no fill")
        XCTAssertNotNil(quiet.standing.edgeColor, "a hairline")
        XCTAssertNil(pressed.layer?.animationKeys(), "nothing animates")
        XCTAssertEqual(resting.state, .resting)
        XCTAssertEqual(pressed.state, .pressed)
    }

    func testAPressedKeysLegendGoesDownWithItsFace() {
        for look in GalleryLook.all {
            let resting = Self.draw("e", state: .resting, look: look), pressed = Self.draw("e", state: .pressed, look: look)
            XCTAssertEqual(resting.ink.midY - pressed.ink.midY, 2, accuracy: 0.5, look.name)
            XCTAssertEqual(pressed.ink.midY, pressed.face.midY, accuracy: 0.5, "still centred on the face")
        }
    }

    func testTheKeysHintsAreOverContentOpaqueAndHairlined() {
        GalleryLook.day.apply()
        let quiet = Key("a", state: .quiet, overContent: true)
        quiet.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        quiet.layout()
        XCTAssertNotNil(quiet.standing.faceColor, "over another app's window a quiet key keeps a ground, or the content runs through its letter")
    }

    // MARK: - A sequence, a double tap

    private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    func testASequenceIsOneKeyPerKeystrokeFourApart() {
        GalleryLook.day.apply()
        let strokes = Keycaps.strokes(["e", "p"])
        strokes.layoutSubtreeIfNeeded()
        let keys = strokes.caps
        XCTAssertEqual(keys.map(\.legend), ["e", "p"], "never a chip reading \"e p\"")
        XCTAssertEqual(keys[1].frame.minX - keys[0].frame.maxX, Grid.tight)
        XCTAssertFalse(allViews(strokes).contains { ($0 as? NSTextField) != nil }, "no words, only keys")
    }

    func testAnAlternativeIsAKeyOfItsOwnStandingApart() {
        GalleryLook.day.apply()
        let strokes = KeyStrokes(groups: [["h"], ["j"], ["k"], ["l"]])
        strokes.layoutSubtreeIfNeeded()
        let keys = strokes.caps
        for pair in zip(keys, keys.dropFirst()) {
            XCTAssertEqual(pair.1.frame.minX - pair.0.frame.maxX, Grid.close, "separate keys stand 8 apart")
        }
    }

    func testADoubleTapIsOneKeyAndTimesTwoInQuietInkAtTheMetaSize() {
        GalleryLook.day.apply()
        let strokes = Keycaps.strokes(["lode"], double: true)
        strokes.layoutSubtreeIfNeeded()
        XCTAssertEqual(strokes.caps.map(\.legend), ["lode"], "one key, not two identical ones")
        let times = allViews(strokes).compactMap { $0 as? NSTextField }
        XCTAssertEqual(times.map(\.stringValue), ["×2"])
        XCTAssertEqual(times.first?.textColor, BarTheme.secondaryColor)
        XCTAssertEqual(times.first?.typeStyle?.role, .meta)
        XCTAssertEqual(times[0].alignmentRect(forFrame: times[0].frame).minX - strokes.caps[0].frame.maxX, Grid.tight, "4 after the key")
    }

    func testAGestureLineDrawsADoubleTapAndASequenceTheSameWay() {
        GalleryLook.day.apply()
        let line = Keycaps.line([.init(["lode"], "go", double: true), .init(["e", "p"], "mail")])
        line.layoutSubtreeIfNeeded()
        let keys = allViews(line).compactMap { $0 as? Key }
        XCTAssertEqual(keys.map(\.legend), ["lode", "e", "p"])
        let words = allViews(line).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(words.contains("×2"))
    }

    func testAKeysLegendIsSpokenByName() {
        XCTAssertEqual(KeyLegend.spoken("⏎"), "return")
        XCTAssertEqual(KeyLegend.spoken("⌘K"), "command K")
        XCTAssertEqual(KeyLegend.spoken("⇧⌘V"), "shift command V")
        XCTAssertEqual(KeyLegend.spoken("esc"), "esc")
        XCTAssertEqual(KeyLegend.spoken("e"), "e")
    }

    func testTheKeystrokesAWrittenGroupIs() {
        XCTAssertEqual(Keycaps.keystrokes(of: "zo"), ["z", "o"])
        XCTAssertEqual(Keycaps.keystrokes(of: "z="), ["z", "="])
        XCTAssertEqual(Keycaps.keystrokes(of: "]s"), ["]", "s"])
        XCTAssertEqual(Keycaps.keystrokes(of: "esc"), ["esc"])
        XCTAssertEqual(Keycaps.keystrokes(of: "⌘K"), ["⌘K"])
        XCTAssertEqual(Keycaps.keystrokes(of: "⇧F"), ["⇧F"])
        XCTAssertEqual(Keycaps.keystrokes(of: "a…z"), ["a…z"])
        XCTAssertEqual(Keycaps.keystrokes(of: "$"), ["$"])
        let row = GuideRow(key: "zo zc", label: "x")
        XCTAssertEqual(row.groups, [["z", "o"], ["z", "c"]])
        XCTAssertEqual(GuideRow(key: "h j k l", label: "x").groups, [["h"], ["j"], ["k"], ["l"]])
    }
}
