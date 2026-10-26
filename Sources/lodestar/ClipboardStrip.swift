import AppKit
import LodestarCore
import UniformTypeIdentifiers

/// Keep: the clips as the hands hold them.
///
/// Eight clips stand on one row, each directly over the key that pastes
/// it: the newest on J under the right index finger, two keys wide and a
/// step taller, then K, L and ; each a little shorter, then the left
/// hand's F D S A, older and level. A gutter at G keeps the hands apart
/// the way the keyboard does. Over the left hand, on the number row's
/// line, are the four keepsakes; over the right hand the space stays
/// open until a search needs it.
///
/// The layout never changes. A search takes the bar over the right hand
/// and fills the same eight places with what matches; the keepsakes are
/// never touched. A held modifier shows on every card what it would
/// paste, so what is seen is what pastes.
///
/// Never key: the strip reads its keys from the event tap, so the window
/// you are typing in keeps focus and its insertion point the whole time.
/// That is what lets the paste be a plain ⌘V into an app that never lost
/// the cursor. It takes no mouse either: it is read, and a click anywhere
/// ends it.
final class ClipboardStrip {
    static let labels = Clipboard.recentLabels

    /// What the bar over the right hand is carrying, when it is carrying
    /// anything. Idle it stays empty — a bar sitting there permanently is
    /// furniture, and Keep is something you look at every day.
    enum Band {
        case none
        case search(String)
        /// A card's actions, drawn as a menu over the card.
        case actions([Action])
        /// A file name for an image being saved: what was typed, the
        /// name offered when nothing is, and the folder it lands in.
        case save(name: String, offered: String, folder: String)
    }

    /// One line of the actions menu.
    struct Action {
        let key: String
        let label: String
        let symbol: String
        var isDestructive = false
    }

    /// The modifier the hand is holding over the cards. Each one changes
    /// the keys the cards wear to the chord that would paste them, and
    /// `⌃` shows the reading it would paste in place of the clip.
    enum Held: Equatable { case none, option, control, shift }

    /// The list of source apps as drawn under the bar.
    struct SourceMenu: Equatable {
        struct Row: Equatable {
            let name: String
            let count: Int
        }
        var typed: String
        var rows: [Row]
        var selection: Int
    }

    /// A keepsake whose name is being written in its place.
    struct Naming: Equatable {
        let id: String
        var text: String
        /// The offered name stands selected: the first key typed replaces
        /// it, and a delete clears it for a name of your own.
        var selected: Bool
    }

    // MARK: - Geometry

    static let gap = Grid.part
    /// The space at G between the hands.
    static let gutter = Grid.section
    /// The narrowest a card may be and still hold a line of a command.
    /// Below it J gives up its second key, and every key keeps its card.
    static let minModule: CGFloat = 150
    static let maxModule: CGFloat = 196
    /// The older clips' height. J, K, L and ; stand above it in small
    /// steps, so the newest leads by a step, never by a leap.
    static let clipHeight: CGFloat = 150
    static let rise: [CGFloat] = [1.26, 1.17, 1.11, 1.06]
    /// The band over the right hand holds one field, a well 32 tall with the
    /// band's inset round it (design/12-well.md).
    static let barHeight = BarTheme.bandHeight
    static let margin = Grid.section
    /// Where Keep's top edge stands, as a share of the screen's height:
    /// the bars' own line, so every surface opens at one height.
    static let topLine = BarTheme.topLine

    /// Every place Keep draws, decided from the screen alone so a test can
    /// ask about any screen. Card frames by label, keepsakes by digit, and
    /// the bar over the right hand; screen coordinates.
    struct Layout: Equatable {
        var module: CGFloat
        /// Whether J stands over two keys. False on a screen too narrow
        /// for nine readable cards.
        var wideJ: Bool
        var places: [String: NSRect]
        var bar: NSRect

        /// The top of the tallest clip: the clip door stands above it.
        var rowTop: CGFloat { places["j"]?.maxY ?? bar.minY }
    }

    static func layout(in screen: NSRect) -> Layout {
        let usable = screen.width - margin * 2
        var wide = true
        var module = (usable - 7 * gap - gutter) / 9
        if module < minModule {
            wide = false
            module = (usable - 6 * gap - gutter) / 8
        }
        module = floor(min(module, maxModule))
        let width = (wide ? 9 : 8) * module + (wide ? 7 : 6) * gap + gutter
        let left = floor(screen.midX - width / 2)
        let barTop = floor(screen.minY + screen.height * topLine)
        let barBottom = barTop - barHeight
        let base = barBottom - gap - ceil(clipHeight * rise[0])

        var places: [String: NSRect] = [:]
        for (column, key) in ["a", "s", "d", "f"].enumerated() {
            let x = left + CGFloat(column) * (module + gap)
            places[key] = NSRect(x: x, y: base, width: module, height: clipHeight)
            let keepBottom = base + clipHeight + gap
            places["\(column + 1)"] = NSRect(x: x, y: keepBottom, width: module, height: barTop - keepBottom)
        }
        var x = left + 4 * module + 3 * gap + gutter
        for (step, key) in ["j", "k", "l", ";"].enumerated() {
            let w = step == 0 && wide ? module * 2 + gap : module
            let h = ceil(clipHeight * rise[step])
            places[key] = NSRect(x: x, y: base, width: w, height: h)
            x += w + gap
        }
        let j = places["j"]!, last = places[";"]!
        let bar = NSRect(x: j.minX, y: barBottom, width: last.maxX - j.minX, height: barHeight)
        return Layout(module: module, wideJ: wide, places: places, bar: bar)
    }

    // MARK: - State, for the tests

    private let panel: NSPanel
    private let root = NSView()

    private(set) var bandFrame: NSRect?
    private(set) var lastLayout: Layout?
    var isVisible: Bool { panel.isVisible }
    /// For the tests: the window casts no shadow of its own.
    var castsWindowShadow: Bool { panel.hasShadow }
    /// Which clip each label answers to, in rank order.
    private(set) var shownRecents: [Clipboard.Clip] = []
    /// The modifier the cards were last drawn under.
    private(set) var shownHeld: Held = .none
    private(set) var shownPins: [Int: Clipboard.Clip] = [:]
    /// The keepsakes stepped aside for the clip door.
    private(set) var pinsHidden = false
    private(set) var shownBadges: [String: String] = [:]
    private(set) var shownSources: [String: String] = [:]
    private(set) var shownCaptions: [String: String] = [:]
    private(set) var shownSwatches: [String: String] = [:]
    /// Lodestar's note on each card it has read, by clip id: the voice
    /// line first, then the exact lines, as drawn.
    private(set) var shownNotes: [String: [String]] = [:]
    /// The reading each card shows while `⌃` is held, by clip id.
    private(set) var shownReadings: [String: String] = [:]
    private(set) var shownMasked: [String: String] = [:]
    /// What a card of files lists, as drawn: its names (and the grey line
    /// of how many more), by clip id.
    private(set) var shownFiles: [String: [String]] = [:]
    /// How many sheets each card of files stands, and which cards are
    /// drawn dimmed because every file of them is gone.
    private(set) var shownSheets: [String: Int] = [:]
    private(set) var shownQuiet: Set<String> = []
    /// What each card is made of, in the order they were drawn.
    private(set) var shownFills: [CardFill] = []
    /// The free places as drawn, by slot: wells.
    private(set) var shownFreePlaces: [Int: NSView] = [:]
    private(set) var shownCards: [String: NSView] = [:]
    /// The key each card wears, by clip id; absent when it wears none.
    private(set) var shownKeys: [String: String] = [:]
    /// The keepsakes' names as drawn, by place.
    private(set) var shownNames: [Int: String] = [:]
    private(set) var shownSave: (name: String, offered: String, folder: String)?
    /// The actions menu's labels while one stands, for the tests.
    private(set) var shownActions: [String] = []
    /// What VoiceOver can reach, for the tests.
    var accessibleElements: [NSView] { (root.accessibilityChildren() as? [NSView]) ?? [] }
    /// The bar's count and source, as drawn.
    private(set) var shownCount: String?
    private(set) var shownSource: String?
    /// The band over the right hand and the field well in it, as drawn.
    private(set) var shownBand: (plate: NSView, field: WellView)?
    /// The field well of the list of sources, as drawn.
    private(set) var shownSourceField: WellView?
    private(set) var shownSourceRows: [String] = []
    /// The zones a timestamp is read into beside yours and UTC.
    var timeZones: [TimeZone] = []
    /// The moment a timestamp's note is felt against, and the zone that is
    /// "your clock": the real ones, a seam for the tests, because what a
    /// note says depends on the hour it is read at.
    var now: () -> Date = { Date() }
    var localZone: TimeZone = .current
    /// The units a measurement is read into.
    var units = ClipQuantity.System.regional()

    /// The clip door stands this far above the bottom of the screen: over
    /// the clips, with the keepsakes and the bar stepped aside.
    var doorFloor: CGFloat { Self.doorFloor(in: ActivePolicy.presentationFrame) }

    static func doorFloor(in screen: NSRect) -> CGFloat {
        layout(in: screen).rowTop - screen.minY + gap
    }

    private static let pad = Grid.part
    /// The key's inset from a card's top edge, the gap under it, and the
    /// foot's height. The key's own side (3 points) is part of the gap under
    /// its face, so the gap stays a hair: the key is 24 tall and a card's
    /// body is as tall as the file's sheet it holds.
    private static let head = Grid.part
    private static let keyGap = Grid.hair
    /// How far below a card's top inset the middle of a key's face is: the
    /// face stands half its side above the middle of the key's frame.
    private static let keyLine = BarTheme.keyHeight / 2 - Ceramic.Side.control / 2
    /// A card stands on a side inside its frame, so what it holds starts
    /// above it: the foot and the footer are measured from the face.
    private static let cardSide = Ceramic.Side.row
    private static let foot = cardSide + Grid.section

    /// What a thing inside a card rounds at: the card's radius less the
    /// card's inset, so the gap between the two curves is even, and never
    /// under the thing's own rung.
    static func insideRadius(rung: CGFloat) -> CGFloat {
        BarTheme.nested(outer: BarTheme.surfaceRadius, inset: pad, rung: rung)
    }

    init() {
        panel = Ceramic.makePanel(level: .statusBar)
        panel.ignoresMouseEvents = true
        panel.contentView = root
        // Separate objects in one window: each card casts its own drawn
        // shadow, and the window casts none.
        panel.hasShadow = false
    }

    func hide() { panel.orderOut(nil) }

    /// Lay the world out for one frame. Cheap enough to call on every
    /// keystroke while searching: previews come from the in-memory index
    /// and thumbnails are already decoded.
    func show(recents: [Clipboard.Clip], pins: [Clipboard.Clip],
              thumbnail: (String) -> NSImage?,
              fileThumbnail: (String, Int) -> NSImage? = { _, _ in nil },
              filesPresent: (String) -> [Bool]? = { _ in nil },
              filePaths: @escaping (String) -> [URL]? = { _ in nil },
              band: Band, selection: Int, actingOn: String? = nil,
              pinsHidden: Bool = false, held: Held = .none,
              source: String? = nil, matches: Int? = nil,
              sourceMenu: SourceMenu? = nil, naming: Naming? = nil) {
        let query: String?
        if case .search(let text) = band { query = text } else { query = nil }
        let screen = ActivePolicy.presentationFrame
        let layout = Self.layout(in: screen)
        let opening = !panel.isVisible
        lastLayout = layout
        self.pinsHidden = pinsHidden
        shownSave = nil
        shownActions = []
        shownBadges = [:]
        shownSources = [:]
        shownCaptions = [:]
        shownSwatches = [:]
        shownNotes = [:]
        shownReadings = [:]
        shownMasked = [:]
        shownFiles = [:]
        pathsOf = filePaths
        shownSheets = [:]
        shownQuiet = []
        shownFills = []
        shownFreePlaces = [:]
        shownCards = [:]
        shownKeys = [:]
        shownNames = [:]
        shownCount = nil
        shownSource = nil
        shownBand = nil
        shownSourceField = nil
        shownSourceRows = []
        bandFrame = nil

        shownHeld = held
        shownRecents = Array(recents.prefix(Self.labels.count))
        // The one card that is chosen is the slab: the card being named or
        // acted on, else what ⏎ would paste, the newest until a search moves
        // it. With the list of sources open the choice is in the list.
        let chosenID: String? = sourceMenu != nil ? nil
            : naming?.id ?? actingOn ?? (shownRecents.indices.contains(query != nil ? selection : 0)
                                         ? shownRecents[query != nil ? selection : 0].id : nil)
        // Last-wins, never a trap: a hand-edited index can hold two clips
        // claiming one place, and Keep opening is the wrong place to die.
        shownPins = Dictionary(pins.compactMap { clip in
            clip.pinnedSlot.map { ($0, clip) }
        }, uniquingKeysWith: { _, second in second })

        root.subviews.forEach { $0.removeFromSuperview() }

        // Everything built inside one disabled-animation transaction:
        // Keep appears complete in the frame the chord lands.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        panel.setFrame(screen, display: false)
        root.frame = NSRect(origin: .zero, size: screen.size)
        let local = { (rect: NSRect) in rect.offsetBy(dx: -screen.minX, dy: -screen.minY) }

        var ranked: [NSView] = []
        for (rank, clip) in shownRecents.enumerated() {
            let label = Self.labels[rank]
            guard let place = layout.places[label] else { continue }
            let reading = held == .control ? readingText(clip) : nil
            let key = keyText(label: label, rank: rank, searching: query != nil,
                              held: held, hasReading: reading != nil, selection: selection)
            // The key that pastes lights on the chosen card, and only while
            // pasting is what a key does: with a menu open the keys answer it.
            // A clip named before it has a place is named on the band's own
            // card, which is the slab; its card in the row is not a second one.
            let chosen = clip.id == chosenID && naming?.id != clip.id
            let lit = key != nil && chosen && actingOn == nil && sourceMenu == nil
            let files = fileArt(for: clip, picture: fileThumbnail, present: filesPresent)
            let card = makeCard(clip: clip, key: key, lit: lit, size: place.size,
                                face: rank == 0 && layout.wideJ ? .title : .body,
                                reading: reading,
                                thumbnail: clip.kind == .image ? thumbnail(clip.id) : nil,
                                files: files, chosen: chosen)
            card.frame = local(place)
            card.setAccessibilityLabel(spoken(clip, rank: rank, label: label, files: files))
            root.addSubview(card)
            ranked.append(card)
        }

        if !pinsHidden {
            for slot in 1...Clipboard.pinSlots {
                guard let place = layout.places["\(slot)"] else { continue }
                let card: NSView
                if let clip = shownPins[slot] {
                    let reading = held == .control ? readingText(clip) : nil
                    let key = keepKey(slot: slot, searching: query != nil, held: held,
                                      hasReading: reading != nil)
                    card = makeKeepsake(clip: clip, slot: slot, key: key, size: place.size,
                                        reading: reading,
                                        thumbnail: clip.kind == .image ? thumbnail(clip.id)
                                            : clip.kind == .file ? fileThumbnail(clip.id, 0) : nil,
                                        naming: naming?.id == clip.id ? naming : nil,
                                        chosen: clip.id == chosenID)
                    card.setAccessibilityLabel("Keepsake \(slot), \(Clipboard.name(of: clip))")
                    ranked.append(card)
                } else {
                    card = makeFreePlace(slot: slot, size: place.size,
                                         wearsKey: query == nil && held != .control)
                }
                card.frame = local(place)
                root.addSubview(card)
            }

            // The bar over the right hand: the search or the save name.
            switch band {
            case .search(let query):
                bandFrame = layout.bar
                addSearchBar(query: query, source: source, matches: matches,
                             shown: shownRecents.count, frame: local(layout.bar), holdsCaret: sourceMenu == nil)
            case .save(let name, let offered, let folder):
                bandFrame = layout.bar
                shownSave = (name, offered, folder)
                addSaveField(name: name, offered: offered, folder: folder, frame: local(layout.bar))
            case .actions(let actions):
                let size = actionSize(actions)
                addActionCard(actions, frame: local(actionFrame(for: actingOn, size: size,
                                                                layout: layout, screen: screen)))
            case .none:
                break
            }
            if let sourceMenu {
                addSourceMenu(sourceMenu, under: local(layout.bar))
            }
            // A clip being kept while every place is full has no place yet:
            // its name is written where the bar stands, over the right
            // hand, until ⌘1–⌘4 chooses where it goes.
            if let naming, !shownPins.values.contains(where: { $0.id == naming.id }),
               let clip = recents.first(where: { $0.id == naming.id }) {
                let size = NSSize(width: min(layout.bar.width, layout.module * 2 + Self.gap),
                                  height: layout.bar.height)
                let card = makeKeepsake(clip: clip, slot: 0, key: nil, size: size, reading: nil,
                                        thumbnail: nil, naming: naming, chosen: true)
                card.frame = local(NSRect(origin: layout.bar.origin, size: size))
                root.addSubview(card)
            }
        }

        root.setAccessibilityChildren(ranked + root.subviews.filter { !ranked.contains($0) && $0.isAccessibilityElement() })
        panel.setAccessibilityLabel("Keep")
        panel.orderFrontRegardless()
        CATransaction.commit()
        NSAnimationContext.endGrouping()

        if opening {
            let kept = shownPins.count
            NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
                .announcement: "Keep, \(shownRecents.count) clips, \(kept) keepsakes",
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
    }

    // MARK: - Bring

    /// The matches Bring is showing, by label order, for the shell to read
    /// back the pick and for the tests.
    private(set) var shownBring: [Bring.Match] = []
    private(set) var shownBringSources: [String] = []

    /// Bring, in Keep's places: what your other windows say, each line a
    /// card over the key that takes it, best first on J. The token a pick
    /// brings stands out in the line; the foot says which app and which
    /// window. No keepsakes: they are Keep's.
    func showBring(query: String, matches: [Bring.Match], total: Int, sources: [Bring.Source],
                   reading: Bool, source: String?, sourceMenu: SourceMenu?, held: Held = .none) {
        let screen = ActivePolicy.presentationFrame
        let layout = Self.layout(in: screen)
        let opening = !panel.isVisible
        lastLayout = layout
        shownHeld = held
        shownRecents = []
        shownPins = [:]
        shownCards = [:]
        shownKeys = [:]
        shownFills = []
        shownFreePlaces = [:]
        shownCount = nil
        shownSource = nil
        shownBand = nil
        shownSourceField = nil
        shownSourceRows = []
        bandFrame = layout.bar
        shownBring = Array(matches.prefix(Self.labels.count))
        shownBringSources = shownBring.map { sources.indices.contains($0.source) ? sources[$0.source].app : "" }
        root.subviews.forEach { $0.removeFromSuperview() }

        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(screen, display: false)
        root.frame = NSRect(origin: .zero, size: screen.size)
        let local = { (rect: NSRect) in rect.offsetBy(dx: -screen.minX, dy: -screen.minY) }

        var ranked: [NSView] = []
        for (rank, match) in shownBring.enumerated() {
            let label = Self.labels[rank]
            guard let place = layout.places[label] else { continue }
            let from = sources.indices.contains(match.source) ? sources[match.source] : nil
            let key = rank == 0 ? (held == .shift ? "⇧⏎" : "⏎")
                : (held == .shift ? "⌥⇧" : "⌥") + label.uppercased()
            let card = makeBringCard(match, from: from, key: key, lit: rank == 0, size: place.size,
                                     wholeLine: held == .shift,
                                     face: rank == 0 && layout.wideJ ? .title : .body)
            card.frame = local(place)
            card.setAccessibilityLabel(Caption.line(["\(label.uppercased()), match \(rank + 1)",
                                                      Self.spokenLine(match), from?.app, from?.window]))
            root.addSubview(card)
            ranked.append(card)
        }

        let count: String?
        if (query as NSString).length < Bring.minimumQuery {
            count = nil
        } else if total == 0 {
            count = reading ? "Reading" : "No matches"
        } else {
            count = total > shownBring.count ? "\(shownBring.count) of \(total)" : "\(total) found"
        }
        addBar(query: query, placeholder: "Type what you saw in another window",
               count: count, source: source, frame: local(layout.bar), holdsCaret: sourceMenu == nil)
        if let sourceMenu { addSourceMenu(sourceMenu, under: local(layout.bar)) }

        root.setAccessibilityChildren(ranked + root.subviews.filter { !ranked.contains($0) && $0.isAccessibilityElement() })
        panel.setAccessibilityLabel("Bring")
        panel.orderFrontRegardless()
        CATransaction.commit()
        NSAnimationContext.endGrouping()
        if opening {
            NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
                .announcement: "Bring, type what you saw in another window",
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
    }

    /// A line from another window: its text with the token a pick brings
    /// set in the label colour and the rest in the card's grey, or, while
    /// ⇧ is held, the whole line in the label colour, since that is what
    /// would come.
    private func makeBringCard(_ match: Bring.Match, from: Bring.Source?, key: String, lit: Bool,
                               size: NSSize, wholeLine: Bool, face: BarTheme.Role) -> NSView {
        let card = surface(size: size, fill: .pane)
        let id = "bring-\(match.source)-\(match.hit.location)-\(match.line.hashValue)"
        shownCards[id] = card
        shownKeys[id] = key
        _ = addKey(key, lit: lit, to: card, height: size.height)
        let body = NSRect(x: Self.pad, y: Self.foot, width: size.width - Self.pad * 2,
                          height: size.height - Self.head - BarTheme.keyHeight - Self.keyGap - Self.foot)
        let text = Self.bringLine(match, face: face, wholeLine: wholeLine)
        let preview = NSTextField(wrappingLabelWithString: "")
        preview.lineBreakMode = .byWordWrapping
        let line = Self.lineHeight(of: face)
        preview.maximumNumberOfLines = max(1, Int(body.height / line))
        preview.cell?.truncatesLastVisibleLine = true
        preview.attributedStringValue = text
        preview.followLook()
        preview.frame = body
        card.addSubview(preview)

        let where_ = NSTextField(labelWithString: from?.window ?? "")
        where_.setRole(.meta)
        where_.textColor = BarTheme.secondaryColor
        where_.lineBreakMode = .byTruncatingTail
        let app = NSTextField(labelWithString: from?.app ?? "")
        app.setRole(.meta)
        app.textColor = BarTheme.secondaryColor
        app.sizeToFit()
        app.frame.origin = NSPoint(x: Self.pad, y: Self.cardSide + Grid.close)
        card.addSubview(app)
        where_.sizeToFit()
        let room = size.width - Self.pad - app.frame.maxX - Grid.close
        if room > 24, from?.window.isEmpty == false {
            let width = min(where_.frame.width, room)
            where_.frame = NSRect(x: size.width - Self.pad - width, y: Self.cardSide + Grid.close, width: width, height: where_.frame.height)
            card.addSubview(where_)
        }
        return card
    }

    /// A line as a card draws it. The text starts a little before the hit,
    /// with an ellipsis, when the hit sits far enough in that the card's
    /// lines would end before it; the token a pick brings stands out; and
    /// every secret's middle is a bar, as on Keep's cards, because the
    /// danger is the screen.
    static func bringLine(_ match: Bring.Match, face: BarTheme.Role, wholeLine: Bool) -> NSAttributedString {
        let line = match.line as NSString
        var start = 0
        if match.hit.location > 48 {
            start = match.hit.location - 32
            let space = line.range(of: " ", options: [], range: NSRange(location: start, length: match.hit.location - start))
            if space.location != NSNotFound { start = NSMaxRange(space) }
        }
        let lead = start > 0 ? "…" : ""
        let shift = (lead as NSString).length - start
        let out = NSMutableAttributedString(
            string: lead + line.substring(from: start),
            attributes: BarTheme.attributes(face, color: wholeLine ? BarTheme.ink : BarTheme.secondaryColor))
        if !wholeLine {
            let token = NSIntersectionRange(match.token, NSRange(location: start, length: line.length - start))
            if token.length > 0 {
                // The token a pick brings is the same line a weight firmer.
                out.addAttributes(BarTheme.attributes(face == .title ? .roomTitle : .emphasis, color: BarTheme.ink),
                                  range: NSRange(location: token.location + shift, length: token.length))
            }
        }
        for span in ClipSecret.spans(in: match.line).reversed() {
            let middle = NSRange(location: span.range.location + span.head,
                                 length: max(0, span.range.length - span.head - span.tail))
            let shown = NSIntersectionRange(middle, NSRange(location: start, length: line.length - start))
            guard shown.length > 0 else { continue }
            out.replaceCharacters(in: NSRange(location: shown.location + shift, length: shown.length),
                                  with: secretBar(role: face))
        }
        return out
    }

    /// What VoiceOver says for a Bring card: the line with its secrets'
    /// middles left out.
    static func spokenLine(_ match: Bring.Match) -> String {
        ClipSecret.masked(match.lineText)?.text.replacingOccurrences(of: ClipSecret.blocks, with: " hidden ")
            ?? match.lineText
    }

    // MARK: - Keys the cards wear

    /// The chord that pastes a card right now, or nil when no chord does:
    /// a card wears only a key that is true.
    private func keyText(label: String, rank: Int, searching: Bool, held: Held,
                         hasReading: Bool, selection: Int) -> String? {
        // As typed: a bare key is lowercase, and a letter after a modifier
        // is a capital, as macOS writes a chord.
        let bare = label.lowercased(), chord = label.uppercased()
        switch held {
        case .control: return hasReading ? "⌃" + chord : nil
        case .option: return searching ? "⌥" + chord : bare
        case .shift: return searching ? nil : "⇧" + chord
        case .none:
            // While searching the letters are the query, so every match
            // wears the chord that takes it without leaving the search,
            // and the one ⏎ would take wears ⏎.
            if searching { return rank == selection ? "⏎" : "⌥" + chord }
            return bare
        }
    }

    private func keepKey(slot: Int, searching: Bool, held: Held, hasReading: Bool) -> String? {
        switch held {
        case .control: return hasReading ? "⌃\(slot)" : nil
        case .option: return searching ? "⌥\(slot)" : "\(slot)"
        case .shift: return searching ? nil : "⇧\(slot)"
        case .none: return searching ? "⌥\(slot)" : "\(slot)"
        }
    }

    /// What the card would paste as a reading, or nil.
    private func readingText(_ clip: Clipboard.Clip) -> String? {
        // Files show where they are in a form an eye reads on a narrow
        // card, and paste the same places whole and quoted.
        if clip.pastesAsFiles {
            return pathsOf(clip.id).flatMap { $0.isEmpty ? nil : Clipboard.pathsOnCard($0) }
        }
        return Clipboard.reading(of: clip, units: units, zones: timeZones)
    }
    /// Where a card's files are now, as the history last found them: the
    /// reading of a card of files is their paths.
    private var pathsOf: (String) -> [URL]? = { _ in nil }

    /// What VoiceOver says for a card: its key, its rank, what it holds,
    /// where it came from and when — the rank order, not the screen's.
    private func spoken(_ clip: Clipboard.Clip, rank: Int, label: String, files: FileArt?) -> String {
        let what: String
        if clip.kind == .image {
            what = "Image"
        } else if clip.kind == .file {
            what = Clipboard.fileSpeech(of: clip, missing: Clipboard.allMissing(files?.present))
        } else {
            what = masked(clip)?.text ?? clip.preview
        }
        return Caption.line(["\(label.uppercased()), clip \(rank + 1)",
                             String(what.prefix(120)),
                             clip.sourceHost ?? clip.sourceAppName,
                             Clipboard.age(of: clip)])
    }

    // MARK: - Cards

    /// A card is a thing you press to paste, so it stands on a side; what is
    /// not a card (`stands: false`: the bar, a menu, the list of sources)
    /// is a floating pane that lies flat, and so its fills read alone. A
    /// free place is a well, a place to put something, with no shadow.
    private func surface(size: NSSize, fill: CardFill, stands: Bool = true,
                         rung: CGFloat = BarTheme.surfaceRadius) -> NSView {
        let radius = BarTheme.radius(rung, height: size.height)
        let card: NSView
        switch fill {
        case .well:
            card = WellView(cornerRadius: radius)
            card.translatesAutoresizingMaskIntoConstraints = true
        case .pane, .slab:
            let object = SoftShadow.object(radius: radius)
            Ceramic.installPane(in: object, cornerRadius: radius, fill: fill == .slab ? .slab : .pane,
                                side: stands ? Self.cardSide : 0)
            object.chosen = fill == .slab
            card = object
        }
        card.frame = NSRect(origin: .zero, size: size)
        if stands { shownFills.append(fill) }
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.button)
        return card
    }

    private func addKey(_ text: String, lit: Bool, to card: NSView, height: CGFloat) -> Key {
        let cap = Self.placedCap(text, at: NSPoint(x: Self.pad, y: height - BarTheme.keyHeight - Self.head))
        cap.lit = lit
        card.addSubview(cap)
        return cap
    }

    /// One card, built and not shown: internal so a test can look into it
    /// without a strip on the display.
    func makeCard(clip: Clipboard.Clip, key: String?, lit: Bool, size: NSSize,
                  face: BarTheme.Role = .body,
                  reading: String?,
                  thumbnail: NSImage?, files: FileArt? = nil, chosen: Bool) -> NSView {
        let card = surface(size: size, fill: chosen ? .slab : .pane)
        shownCards[clip.id] = card
        let width = size.width, height = size.height
        let line = height - Self.head - Self.keyLine
        var leading = Self.pad
        if let key {
            shownKeys[clip.id] = key
            leading = addKey(key, lit: lit, to: card, height: height).frame.maxX + Grid.close
        }
        // A copy of several things says so beside its key.
        if let items = clip.itemsLabel {
            let count = NSTextField(labelWithString: items)
            count.setRole(.meta, tabular: true)
            count.textColor = BarTheme.secondaryColor
            count.sizeToFit()
            count.frame.origin = NSPoint(x: leading, y: line - count.frame.height / 2)
            card.addSubview(count)
        }

        // Every card's text starts the same distance below its top edge.
        let body = NSRect(x: Self.pad, y: Self.foot, width: width - Self.pad * 2,
                          height: height - Self.head - BarTheme.keyHeight - Self.keyGap - Self.foot)
        if let reading {
            // Held `⌃`: the card shows what it would paste, in Lodestar's
            // voice, where the clip was.
            shownReadings[clip.id] = reading
            let label = NSTextField(wrappingLabelWithString: reading)
            label.setRole(.voice)
            label.textColor = BarTheme.ink
            label.maximumNumberOfLines = 3
            label.cell?.truncatesLastVisibleLine = true
            label.frame = body
            card.addSubview(label)
        } else if let color = clip.color {
            let text = clip.preview.trimmingCharacters(in: .whitespacesAndNewlines)
            let other = text.hasPrefix("#") || text.lowercased().hasPrefix("0x") || !text.contains("(")
                ? color.rgb : color.hex
            // The clip keeps a line of its own: on a short card the other
            // notation gives way first.
            let room = body.height - Self.voiceHeight * 2 - Self.noteGap - Self.bodyLine
            let note = addNote(voice: color.name, lines: room >= Self.metaHeight ? [other] : [],
                               swatch: color, for: clip.id, to: card, in: body)
            addPreview(clip, to: card, in: body, above: note)
            shownSwatches[clip.id] = color.hex
        } else if let time = clip.time {
            // Your clock's line whole, or without its weekday on a card
            // too narrow for it: never cut short.
            let moment = now()
            var read = time.note(local: localZone, zones: timeZones, now: moment)
            if Self.lineWidth(read.local) > body.width - Grid.tight {
                read = time.note(local: localZone, zones: timeZones, now: moment, compact: true)
            }
            let room = body.height - Self.previewHeight(shown(clip).string, width: body.width) - Self.noteGap
            let rows = max(1, Int((room - Self.voiceHeight - Grid.hair) / Self.metaHeight))
            // UTC is there for anyone; a zone you kept is there because you
            // asked. Short of rows, UTC gives way before a zone you kept.
            var lines = Self.pack([read.local] + read.zones, width: body.width)
            if lines.count > rows { lines = Self.pack([read.local] + read.kept, width: body.width) }
            lines = Array(lines.prefix(rows))
            let note = addNote(voice: read.voice, lines: lines, swatch: nil, for: clip.id,
                               to: card, in: body)
            addPreview(clip, to: card, in: body, above: note)
        } else if let read = clip.quantity?.note(into: units) {
            let note = addNote(voice: read.voice, lines: read.exact.map { [$0] } ?? [], swatch: nil, for: clip.id,
                               to: card, in: body)
            addPreview(clip, to: card, in: body, above: note)
        } else if let sum = clip.sum {
            let note = addNote(voice: sum.voice(), lines: [], swatch: nil, for: clip.id, to: card, in: body)
            addPreview(clip, to: card, in: body, above: note)
        } else if let files, clip.kind == .file {
            addFiles(clip, art: files, to: card, in: body)
        } else if let thumbnail {
            let view = NSImageView(image: thumbnail)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.frame = body
            card.addSubview(view)
        } else {
            addPreview(clip, to: card, in: body, above: nil, role: face)
        }

        // The foot: where it came from on the left, how long and how old
        // on the right. The page a browser copy was made on is the
        // address the hand remembers, "the one from GitHub".
        let badge = Clipboard.lengthBadge(for: clip)
        if let badge { shownBadges[clip.id] = badge }
        var caption = Caption.line([badge, Clipboard.age(of: clip)])
        var showsSource = true
        if let files, clip.kind == .file {
            // Files say what they weigh, and a single one what it is; when
            // that does not fit beside the source, the kind goes first, and
            // after it the source itself, which is nearly always the
            // Finder and not worth an ellipsis where the size is a word.
            let age = Clipboard.age(of: clip)
            let missing = Clipboard.allMissing(files.present)
            let beside = width - Self.pad * 2 - Grid.close - Self.minimumSource
            caption = Clipboard.fileCaption(of: clip, age: age, missing: missing)
            if Self.lineWidth(caption) > beside {
                caption = Clipboard.fileCaption(of: clip, age: age, withKind: false, missing: missing)
                showsSource = Self.lineWidth(caption) <= beside
            }
        }
        shownCaptions[clip.id] = caption
        let age = NSTextField(labelWithString: caption)
        // An age ticks and a size is a number: figures that hold their width.
        age.setRole(.meta, tabular: true)
        age.textColor = BarTheme.secondaryColor
        age.sizeToFit()
        age.frame.origin = NSPoint(x: width - age.frame.width - Self.pad, y: Self.cardSide + Grid.close)
        card.addSubview(age)
        if showsSource, let origin = clip.sourceHost ?? clip.sourceAppName {
            let source = NSTextField(labelWithString: origin)
            source.setRole(.meta)
            source.textColor = BarTheme.secondaryColor
            source.lineBreakMode = .byTruncatingTail
            source.sizeToFit()
            let room = age.frame.minX - Grid.close - Self.pad
            // A card of files names its source whole or not at all: it is
            // nearly always the Finder, and "Find…" is no name.
            if clip.kind == .file, source.frame.width > room { return card }
            source.frame = NSRect(x: Self.pad, y: Self.cardSide + Grid.close, width: max(0, min(source.frame.width, room)),
                                  height: source.frame.height)
            card.addSubview(source)
            shownSources[clip.id] = origin
        }
        return card
    }

    // MARK: - Files

    /// What a card of files is drawn from beyond the clip: a picture per
    /// sheet (nil while it is still being decoded) and whether each file is
    /// still where it was (nil until that has been asked, off the main thread).
    struct FileArt {
        var pictures: [NSImage?]
        var present: [Bool]?
    }

    private func fileArt(for clip: Clipboard.Clip, picture: (String, Int) -> NSImage?,
                         present: (String) -> [Bool]?) -> FileArt? {
        guard clip.kind == .file else { return nil }
        let sheets = min(Clipboard.thumbnailedFiles, clip.itemCount)
        return FileArt(pictures: (0..<sheets).map { picture(clip.id, $0) }, present: present(clip.id))
    }

    /// A sheet of the stack: 50 by 64. The one file of a card stands larger.
    static let sheet = NSSize(width: 50, height: 64)
    static let soloSheet = NSSize(width: 64, height: 84)
    /// Each sheet behind the first stands this far right and up.
    static let cascadeStep = NSSize(width: Grid.group, height: Grid.close)

    /// Where the sheets of a stack stand in a card's body, the first at the
    /// lower left in front, each of the others a step up and to the right
    /// and behind it. Whole points.
    static func cascadeSheets(count: Int, in body: NSRect) -> [NSRect] {
        (0..<max(0, count)).map { index in
            NSRect(x: body.minX + Grid.tight + cascadeStep.width * CGFloat(index),
                   y: body.minY + Grid.hair + cascadeStep.height * CGFloat(index),
                   width: sheet.width, height: sheet.height)
        }
    }

    /// Where the one file's sheet stands: at the left of the body, centred
    /// in its height.
    static func soloSheetFrame(in body: NSRect) -> NSRect {
        NSRect(x: body.minX, y: body.minY + max(0, floor((body.height - soloSheet.height) / 2)),
               width: soloSheet.width, height: soloSheet.height)
    }

    /// The icons of types, asked of the system once each: what a sheet shows
    /// until its own picture is decoded.
    private static var typeIcons: [String: NSImage] = [:]

    private static func icon(type identifier: String?, name: String?) -> NSImage {
        let type = identifier.flatMap { UTType($0) }
            ?? name.flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension) } ?? .data
        if let known = typeIcons[type.identifier] { return known }
        let icon = NSWorkspace.shared.icon(for: type)
        typeIcons[type.identifier] = icon
        return icon
    }

    /// One sheet: the file's own picture filling it, or its icon standing
    /// in it. A sheet is content, a print lying on the card, and keeps the
    /// short shadow of one; it has no rim, edge or side of its own.
    private func makeSheet(frame: NSRect, picture: NSImage?, fact: Clipboard.FileFact?, name: String?,
                           in card: NSView) -> NSView {
        let sheet = SheetView(radius: Self.insideRadius(rung: BarTheme.markRadius))
        sheet.frame = frame
        let face = NSView(frame: sheet.bounds)
        face.wantsLayer = true
        face.layer?.cornerRadius = Self.insideRadius(rung: BarTheme.markRadius)
        face.layer?.masksToBounds = true
        face.layer?.backgroundColor = Ceramic.resolved(BarTheme.sheet, in: card)
        // The file's own face is cropped to the sheet, as a print is; an
        // icon is whole, with room around it.
        let ownFace = fact?.pictured == true && picture != nil
        let image = picture ?? Self.icon(type: fact?.type, name: name)
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let art = CALayer()
            art.frame = ownFace ? face.bounds : face.bounds.insetBy(dx: Grid.close, dy: Grid.close)
            art.contents = cg
            art.contentsGravity = ownFace ? .resizeAspectFill : .resizeAspect
            art.masksToBounds = true
            face.layer?.addSublayer(art)
        }
        sheet.addSubview(face)
        return sheet
    }

    /// A card of files, from the left of its body: the stack of sheets and
    /// the names beside it for several, one larger sheet and everything the
    /// card knows of the file for one. A card whose files are all gone
    /// keeps its look and loses its brightness.
    private func addFiles(_ clip: Clipboard.Clip, art: FileArt, to card: NSView, in body: NSRect) {
        let facts = clip.fileFacts ?? []
        let names = Clipboard.namesOnCard(of: clip)
        let count = clip.itemCount
        let missing = Clipboard.allMissing(art.present)
        var drawn: [NSView] = []

        if count > 1 {
            let sheets = Self.cascadeSheets(count: min(Clipboard.thumbnailedFiles, count), in: body)
            // Behind first, so the first file stands in front.
            for index in sheets.indices.reversed() {
                drawn.append(makeSheet(frame: sheets[index], picture: art.pictures.indices.contains(index) ? art.pictures[index] : nil,
                                       fact: facts.indices.contains(index) ? facts[index] : nil,
                                       name: names.indices.contains(index) ? names[index] : nil, in: card))
            }
            let left = (sheets.last?.maxX ?? body.minX) + Grid.part
            let room = body.maxX - left
            var lines: [String] = []
            // A card too narrow for the names keeps the stack alone: the
            // count beside the key and VoiceOver still say them. A name cut
            // to its first letters names nothing, so the room must hold one.
            if room >= Self.minimumNamesBeside {
                var top = body.maxY - Grid.part
                for line in Clipboard.nameLines(names: names, total: count) {
                    // "and 5 more" is never cut: where it does not fit, the
                    // number alone says it.
                    let text = line.grey && Self.lineWidth(line.text) > room
                        ? Clipboard.moreLine(count - (Clipboard.fileCardNames - 1), short: true) : line.text
                    let label = NSTextField(labelWithString: text)
                    label.setRole(.meta)
                    label.textColor = line.grey ? BarTheme.secondaryColor : BarTheme.ink
                    label.lineBreakMode = .byTruncatingTail
                    label.sizeToFit()
                    top -= Self.metaHeight
                    label.frame = NSRect(x: left, y: top, width: min(label.frame.width, room), height: Self.metaHeight)
                    top -= Grid.hair
                    drawn.append(label)
                    lines.append(text)
                }
            }
            shownFiles[clip.id] = lines
            shownSheets[clip.id] = sheets.count
        } else {
            let frame = Self.soloSheetFrame(in: body)
            drawn.append(makeSheet(frame: frame, picture: art.pictures.first.flatMap { $0 }, fact: facts.first,
                                   name: names.first, in: card))
            let left = frame.maxX + Grid.part
            let room = body.maxX - left
            var lines: [String] = []
            if room >= Self.minimumNames {
                var top = frame.maxY
                let title = NSTextField(wrappingLabelWithString: facts.first?.name ?? names.first ?? "")
                title.setRole(.name)
                title.textColor = BarTheme.ink
                title.lineBreakMode = .byWordWrapping
                title.maximumNumberOfLines = 2
                title.cell?.truncatesLastVisibleLine = true
                let height = ceil(title.sizeThatFits(NSSize(width: room, height: .greatestFiniteMagnitude)).height)
                let titleHeight = min(height, 2 * Self.metaHeight)
                top -= titleHeight
                title.frame = NSRect(x: left, y: top, width: room, height: titleHeight)
                drawn.append(title)
                lines.append(title.stringValue)
                // The folder it is in, then the pages, pixels or minutes: each
                // a grey line, and a line it has no word for is not drawn.
                for text in [facts.first?.folder, facts.first?.detail] {
                    guard let text, !text.isEmpty else { continue }
                    let label = NSTextField(labelWithString: text)
                    label.setRole(.meta)
                    label.textColor = BarTheme.secondaryColor
                    label.lineBreakMode = .byTruncatingTail
                    top -= Self.metaHeight + Grid.hair
                    label.frame = NSRect(x: left, y: top + Grid.hair, width: room, height: Self.metaHeight)
                    drawn.append(label)
                    lines.append(text)
                }
            }
            shownFiles[clip.id] = lines
            shownSheets[clip.id] = 1
        }

        let content = NSView(frame: body)
        for view in drawn {
            view.frame = view.frame.offsetBy(dx: -body.minX, dy: -body.minY)
            content.addSubview(view)
        }
        if missing {
            // Quiet, never faded (design/13-row.md): a card whose files are
            // gone keeps its look, opaque, and says so in the quiet ink, its
            // words and its keys. Nothing on it is drawn translucent.
            for case let words as NSTextField in drawn { words.textColor = BarTheme.secondaryColor }
            for case let key as Key in card.subviews { key.state = .quiet }
            shownQuiet.insert(clip.id)
        }
        card.addSubview(content)
    }

    /// The least room beside the one file's sheet worth its name, which
    /// may take two lines.
    private static let minimumNames: CGFloat = 40
    /// The least room beside a stack worth its names, one line each.
    private static let minimumNamesBeside: CGFloat = 76
    /// The least room a card's source is worth in the foot of a card of files.
    private static let minimumSource: CGFloat = 40

    /// A keepsake: its number, its name, and the start of what it holds.
    /// It rests where a passing clip floats.
    private func makeKeepsake(clip: Clipboard.Clip, slot: Int, key: String?, size: NSSize,
                              reading: String?, thumbnail: NSImage?, naming: Naming?,
                              chosen: Bool) -> NSView {
        let card = surface(size: size, fill: chosen || naming != nil ? .slab : .pane)
        shownCards[clip.id] = card
        let width = size.width, height = size.height
        var leading = Self.pad
        if let key {
            shownKeys[clip.id] = key
            leading = addKey(key, lit: false, to: card, height: height).frame.maxX + Grid.close
        }
        let line = height - Self.head - Self.keyLine

        let name = naming?.text ?? Clipboard.name(of: clip)
        shownNames[slot] = name
        let title = NSTextField(labelWithString: name)
        title.setRole(.body)
        title.textColor = BarTheme.ink
        title.lineBreakMode = .byTruncatingTail
        title.sizeToFit()
        if let naming {
            // While it is written the name line is a field, a well beside the
            // key. The card is the slab, so the well is the slab's look's, and
            // so is the selection's wash and the caret: they resolve where
            // they are drawn. A card too short for its line (the band's own
            // height) centres the well on its face.
            let centre = max(line, Self.cardSide + BarTheme.fieldHeight / 2 + Grid.hair)
            let well = addFieldWell(to: card, in: NSRect(x: leading, y: centre - BarTheme.fieldHeight / 2,
                                                          width: width - leading - Self.pad,
                                                          height: BarTheme.fieldHeight))
            let room = well.bounds.width - BarTheme.wordPadding * 2
            // The words are set in the slab's look, which is the other look
            // and a step heavier by night, so they are measured in it. A name
            // that outgrows the well scrolls as a field's does: the end, where
            // the caret is, stays in view; the offered name shows its head.
            let glyphs = BarTheme.width(of: name, in: .body, night: !Tone.systemDark)
            title.lineBreakMode = naming.selected ? .byTruncatingTail : .byTruncatingHead
            title.frame = NSRect(x: BarTheme.wordPadding, y: (well.bounds.height - title.frame.height) / 2,
                                 width: room, height: title.frame.height)
            if naming.selected {
                // The offered name stands selected: typing replaces it. The
                // selection is the one wash, ink at 30%, as in every well.
                let mark = NSView(frame: NSRect(x: title.frame.minX - Grid.hair, y: title.frame.minY,
                                                width: min(glyphs, room) + Grid.hair * 2, height: title.frame.height))
                mark.wantsLayer = true
                mark.layer?.cornerRadius = BarTheme.markRadius
                mark.layer?.backgroundColor = Ceramic.resolved(BarTheme.wash, in: card)
                well.addSubview(mark)
            }
            well.addSubview(title)
            if !naming.selected {
                addCaret(to: well, at: title.frame.minX + min(glyphs, room), role: .body)
            }
        } else {
            title.frame = NSRect(x: leading, y: line - title.frame.height / 2,
                                 width: min(title.frame.width, width - leading - Self.pad), height: title.frame.height)
            card.addSubview(title)
        }

        let body = NSRect(x: Self.pad, y: Self.cardSide + Self.head, width: width - Self.pad * 2,
                          height: height - Self.cardSide - Self.head * 2 - BarTheme.keyHeight - Self.keyGap)
        if let reading {
            shownReadings[clip.id] = reading
            let label = NSTextField(wrappingLabelWithString: reading)
            label.setRole(.voice)
            label.textColor = BarTheme.ink
            label.maximumNumberOfLines = 2
            label.cell?.truncatesLastVisibleLine = true
            label.frame = body
            card.addSubview(label)
        } else if let thumbnail {
            let view = NSImageView(image: thumbnail)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.frame = body
            card.addSubview(view)
        } else if body.height > 14 {
            let preview = NSTextField(wrappingLabelWithString: "")
            preview.setRole(.meta)
            preview.textColor = BarTheme.secondaryColor
            preview.lineBreakMode = .byWordWrapping
            preview.maximumNumberOfLines = max(1, Int(body.height / Self.metaHeight))
            preview.cell?.truncatesLastVisibleLine = true
            preview.attributedStringValue = shown(clip, role: .meta)
            preview.followLook()
            preview.frame = body
            card.addSubview(preview)
        }
        return card
    }

    /// A free place is a well, a place to put something, with its
    /// number legible: it is how a hand that has never kept anything
    /// learns that it can.
    private func makeFreePlace(slot: Int, size: NSSize, wearsKey: Bool) -> NSView {
        let card = surface(size: size, fill: .well)
        shownFreePlaces[slot] = card
        var leading = Self.pad
        if wearsKey {
            let cap = addKey("\(slot)", lit: false, to: card, height: size.height)
            cap.quiet = true
            leading = cap.frame.maxX + Grid.close
        }
        let label = NSTextField(labelWithString: "Keep here")
        label.setRole(.meta)
        label.textColor = BarTheme.secondaryColor
        label.sizeToFit()
        label.frame.origin = NSPoint(x: leading,
                                     y: size.height - Self.head - Self.keyLine - label.frame.height / 2)
        card.addSubview(label)
        card.setAccessibilityLabel("Keepsake \(slot), free")
        return card
    }

    /// A card's text, drawn the one way every card draws it, from the top
    /// of the body down. A card with a note beneath gives up the lines
    /// the note stands in, never its place or its face.
    private func addPreview(_ clip: Clipboard.Clip, to card: NSView, in body: NSRect, above note: CGFloat?,
                            role: BarTheme.Role = .body) {
        let preview = NSTextField(wrappingLabelWithString: "")
        preview.textColor = BarTheme.secondaryColor
        // Wrap to the card, ellipsize only the last line. Assigning
        // .byTruncatingTail here collapses the field to a single line
        // whatever the line limit says.
        preview.lineBreakMode = .byWordWrapping
        let line = Self.lineHeight(of: role)
        preview.maximumNumberOfLines = max(1, Int(body.height / line))
        preview.cell?.truncatesLastVisibleLine = true
        preview.attributedStringValue = shown(clip, role: role)
        preview.followLook()
        var frame = body
        if let note {
            frame.origin.y = note + Self.noteGap
            frame.size.height = body.maxY - frame.minY
            preview.maximumNumberOfLines = max(1, Int(frame.height / Self.bodyLine))
        }
        preview.frame = frame
        card.addSubview(preview)
    }

    /// Lodestar's note on a card it has read: at the foot of the body, so
    /// the clip above it keeps its place. The first line is Lodestar
    /// speaking, in its voice and in the clip's own grey; the exact values
    /// ride beneath. A color stands beside its note as a swatch. Returns
    /// the note's top edge.
    private func addNote(voice: String?, lines: [String], swatch color: ClipColor?, for id: String,
                         to card: NSView, in body: NSRect) -> CGFloat {
        var x = body.minX
        var drawn: [String] = []
        var labels: [NSTextField] = []
        // Beside its note, smaller on a narrow card, so the name's longest
        // word always fits on one line and no word is ever broken.
        let roomy = voice.map { Self.widestWord($0) <= body.width - Self.swatch - Grid.part } ?? true
        let swatchSide = roomy ? Self.swatch : Self.smallSwatch
        if color != nil { x += swatchSide + (roomy ? Grid.part : Grid.close) }
        let width = body.maxX - x
        if let voice {
            let label = NSTextField(wrappingLabelWithString: voice)
            label.setRole(.voice)
            label.textColor = BarTheme.secondaryColor
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 2
            label.frame.size = label.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
            labels.append(label)
            drawn.append(voice)
        }
        for line in lines {
            let label = NSTextField(labelWithString: line)
            label.setRole(.meta)
            label.textColor = BarTheme.secondaryColor
            label.lineBreakMode = .byTruncatingTail
            label.sizeToFit()
            labels.append(label)
            drawn.append(line)
        }
        // An exact line that would be cut off beside the swatch runs the
        // card's whole width beneath it instead; the swatch then stands
        // beside the name alone.
        let exact = labels.dropFirst(voice == nil ? 0 : 1)
        let under = color != nil && exact.contains { $0.frame.width > width }
        for label in exact {
            label.frame.size.width = min(label.frame.width, under ? body.width : width)
        }
        var y = body.minY
        var voiceBottom = body.minY
        for (index, label) in labels.enumerated().reversed() {
            let isVoice = index == 0 && voice != nil
            if isVoice { voiceBottom = y }
            label.frame.origin = NSPoint(x: isVoice || !under ? x : body.minX, y: y)
            card.addSubview(label)
            y += label.frame.height + (index == 1 && voice != nil ? Grid.hair : 0)
        }
        var top = y
        if let color {
            let middle = ((under ? voiceBottom : body.minY) + y) / 2
            let floor = under ? voiceBottom : body.minY
            let swatch = NSView(frame: NSRect(x: body.minX, y: max(floor, middle - swatchSide / 2),
                                              width: swatchSide, height: swatchSide))
            swatch.wantsLayer = true
            swatch.layer?.cornerRadius = Self.insideRadius(rung: BarTheme.controlRadius)
            swatch.layer?.backgroundColor = NSColor(srgbRed: color.red, green: color.green, blue: color.blue,
                                                    alpha: color.alpha).cgColor
            swatch.layer?.borderWidth = 0.5
            swatch.layer?.borderColor = Ceramic.resolved(BarTheme.hairline)
            card.addSubview(swatch)
            top = max(top, swatch.frame.maxY)
        }
        shownNotes[id] = drawn
        return top
    }

    /// How wide a caption line draws, measured as its label will.
    private static func lineWidth(_ text: String) -> CGFloat {
        BarTheme.width(of: text, in: .meta, tabular: true)
    }

    /// The widest single word of a note, as the voice draws it.
    private static func widestWord(_ text: String) -> CGFloat {
        text.split(separator: " ").map {
            BarTheme.width(of: String($0), in: .voice) + Grid.tight
        }.max() ?? 0
    }

    /// The exact lines, as few as hold them.
    private static func pack(_ parts: [String], width: CGFloat) -> [String] {
        func fits(_ text: String) -> Bool {
            let label = NSTextField(labelWithString: text)
            label.setRole(.meta)
            label.sizeToFit()
            return label.frame.width <= width
        }
        var lines: [String] = []
        for part in parts {
            if let last = lines.last, fits(Caption.line([last, part])) {
                lines[lines.count - 1] = Caption.line([last, part])
            } else {
                lines.append(part)
            }
        }
        return lines
    }

    /// A card's text as drawn: as much as a card holds, with a secret's
    /// middle as a bar (see `ClipSecret`). The clip keeps its whole text
    /// and the search reads it; only the glass is spared it, because Keep
    /// opened during a screen share is on everyone's screen.
    private func shown(_ clip: Clipboard.Clip, role: BarTheme.Role = .body) -> NSAttributedString {
        let masked = masked(clip)
        let text = String((masked?.text ?? clip.preview).prefix(Clipboard.cardCharacters))
        let out = NSMutableAttributedString(string: text, attributes: BarTheme.attributes(role, color: BarTheme.secondaryColor))
        guard let masked else { return out }
        shownMasked[clip.id] = text
        let length = (text as NSString).length
        for range in masked.blocks.reversed() where range.location < length {
            let drawn = NSIntersectionRange(range, NSRange(location: 0, length: length))
            out.replaceCharacters(in: drawn, with: Self.secretBar(role: role))
        }
        return out
    }

    /// The bar a secret's middle draws as: one rounded bar at the capital
    /// height in the text's own grey, the same width for every secret.
    private static func secretBar(role: BarTheme.Role) -> NSAttributedString {
        let size = NSSize(width: Grid.margin, height: ceil(role.font.capHeight))
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: size, flipped: false) { rect in
            BarTheme.secondaryColor.setFill()
            let bar = rect.insetBy(dx: Grid.hair, dy: 0)
            let corner = BarTheme.radius(BarTheme.markRadius, height: bar.height)
            NSBezierPath(roundedRect: bar, xRadius: corner, yRadius: corner).fill()
            return true
        }
        attachment.bounds = NSRect(origin: .zero, size: size)
        let bar = NSMutableAttributedString(attachment: attachment)
        bar.addAttributes(BarTheme.attributes(role, color: BarTheme.secondaryColor),
                          range: NSRange(location: 0, length: bar.length))
        return bar
    }

    /// Each clip's secret reading is kept while its text stands: Keep
    /// redraws on every keystroke of a search.
    private var maskings: [String: (preview: String, masked: ClipSecret.Masked?)] = [:]

    private func masked(_ clip: Clipboard.Clip) -> ClipSecret.Masked? {
        if let kept = maskings[clip.id], kept.preview == clip.preview { return kept.masked }
        let masked = clip.masked
        maskings[clip.id] = (clip.preview, masked)
        return masked
    }

    private static func previewHeight(_ text: String, width: CGFloat) -> CGFloat {
        let preview = NSTextField(wrappingLabelWithString: text)
        preview.setRole(.body)
        preview.lineBreakMode = .byWordWrapping
        preview.maximumNumberOfLines = 2
        return ceil(preview.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    private static let noteGap = Grid.close
    /// The most of the save band a folder's path may take.
    private static let placeShare: CGFloat = 0.4
    /// A colour's swatch beside its note, and its small size on a narrow card.
    private static let swatch = BarTheme.rowHeight - Grid.close
    private static let smallSwatch = Grid.section
    private static var bodyLine: CGFloat { lineHeight(of: .body) }
    /// The height of a line of a role, as a label sets it.
    private static func lineHeight(of role: BarTheme.Role) -> CGFloat {
        let font = role.font
        return ceil(font.ascender - font.descender + font.leading)
    }
    private static var metaHeight: CGFloat { lineHeight(of: .meta) }
    private static var voiceHeight: CGFloat { ceil(BarTheme.Role.voice.font.ascender - BarTheme.Role.voice.font.descender) + Grid.hair }

    /// The one key, sized by its legend and placed by frame, which is how a
    /// frame-laid card holds it.
    static func placedCap(_ text: String, at origin: NSPoint) -> Key {
        let cap = Keycaps.cap(text)
        cap.translatesAutoresizingMaskIntoConstraints = true
        cap.frame = NSRect(origin: origin, size: cap.frameSize)
        return cap
    }

    // MARK: - The bar

    /// The field of a band or a menu, drawn: a well of a field's height, the
    /// caret in it, so its edge is the deeper one. Its words and its caret
    /// are laid in it by the caller, in its own coordinates.
    private func addFieldWell(to plate: NSView, in rect: NSRect, holdsCaret: Bool = true) -> WellView {
        let well = WellView()
        well.translatesAutoresizingMaskIntoConstraints = true
        well.frame = rect
        well.caretIsHere = holdsCaret
        plate.addSubview(well)
        return well
    }

    /// The caret of a drawn field, at the insertion point `x` on the line
    /// the words stand on, as tall as that role's line.
    private func addCaret(to well: NSView, at x: CGFloat, role: BarTheme.Role) {
        let height = BarTheme.caretHeight(forPointSize: role.size)
        let caret = CaretMark(height: height)
        caret.frame.origin = NSPoint(x: x, y: (well.bounds.height - height) / 2)
        well.addSubview(caret)
    }

    /// The search over the right hand: `/`, what was typed, how many
    /// match, and the source the clips are filtered to.
    private func addSearchBar(query: String, source: String?, matches: Int?, shown: Int, frame: NSRect,
                              holdsCaret: Bool) {
        let count = matches.map { $0 == 0 ? "No matches" : $0 > shown ? "\(shown) of \($0)" : "\($0) found" }
        addBar(query: query, placeholder: "Search clips", count: count, source: source, frame: frame,
               holdsCaret: holdsCaret)
    }

    /// The bar over the right hand, Keep's search and Bring's alike: the
    /// key that opened it, what was typed, how many answer, and the app
    /// the answers are filtered to. The caret is in it unless the list of
    /// sources is open, which has a field of its own.
    private func addBar(query: String, placeholder: String, count countText: String?,
                        source: String?, frame: NSRect, holdsCaret: Bool) {
        // The band holds one field and rounds a field's inset beyond it.
        let bar = surface(size: frame.size, fill: .pane, stands: false, rung: BarTheme.bandRadius)
        bar.frame = frame
        bar.setAccessibilityRole(.textField)
        bar.setAccessibilityLabel(placeholder)
        bar.setAccessibilityValue(query)
        let well = addFieldWell(to: bar, in: bar.bounds.insetBy(dx: BarTheme.bandInset, dy: BarTheme.bandInset),
                                holdsCaret: holdsCaret)
        shownBand = (bar, well)
        let width = well.bounds.width, height = well.bounds.height
        // The source chip at the right: ⇥ and the app the clips come from.
        let chipKey = Self.placedCap("⇥", at: .zero)
        let name = NSTextField(labelWithString: source ?? "All apps")
        name.setRole(.meta)
        name.textColor = source == nil ? BarTheme.secondaryColor : BarTheme.ink
        name.sizeToFit()
        shownSource = name.stringValue
        name.frame.origin = NSPoint(x: width - BarTheme.wordPadding - name.frame.width,
                                    y: (height - name.frame.height) / 2)
        chipKey.frame.origin = NSPoint(x: name.frame.minX - Grid.close - chipKey.frame.width,
                                       y: (height - BarTheme.keyHeight) / 2)
        well.addSubview(chipKey)
        well.addSubview(name)

        var right = chipKey.frame.minX - Grid.group
        if let text = countText {
            shownCount = text
            let count = NSTextField(labelWithString: text)
            count.setRole(.meta, tabular: true)
            count.textColor = BarTheme.secondaryColor
            count.sizeToFit()
            count.frame.origin = NSPoint(x: right - count.frame.width, y: (height - count.frame.height) / 2)
            well.addSubview(count)
            right = count.frame.minX - Grid.group
        }

        let x = BarTheme.wordPadding
        let field = query.isEmpty
            ? NSTextField(labelWithAttributedString: BarTheme.placeholder(placeholder, role: .field))
            : NSTextField(labelWithString: query)
        if query.isEmpty { field.followLook() } else { field.setRole(.field); field.textColor = BarTheme.ink }
        field.lineBreakMode = .byTruncatingHead
        field.sizeToFit()
        field.frame = NSRect(x: x, y: (height - field.frame.height) / 2,
                             width: min(field.frame.width, max(0, right - x)), height: field.frame.height)
        well.addSubview(field)
        // The one caret, at the end of the words, where the placeholder starts.
        let glyphs = query.isEmpty ? 0 : BarTheme.width(of: query, in: .field)
        if holdsCaret { addCaret(to: well, at: x + min(glyphs, field.frame.width), role: .field) }
        root.addSubview(bar)
    }

    /// The list of source apps, dropped from the bar's right end over the
    /// cards: its own field, All apps above a rule, then the apps
    /// alphabetically with how many clips each holds.
    private func addSourceMenu(_ menu: SourceMenu, under bar: NSRect) {
        let rowHeight = BarTheme.lineHeight, fieldHeight = BarTheme.fieldHeight, width = Self.menuWidth
        // Everything stands 8 inside the menu, so the field and the lines
        // share their edges; the lines touch.
        let inset = BarTheme.lineInset
        let visible = 9
        let start = max(0, min(menu.selection - visible / 2, menu.rows.count - visible))
        let rows = Array(menu.rows.enumerated().dropFirst(start).prefix(visible))
        let ruled = rows.first?.offset == 0 && rows.count > 1
        let height = inset * 2 + fieldHeight + Grid.close + CGFloat(rows.count) * rowHeight + (ruled ? Self.ruleRoom : 0)
        let frame = NSRect(x: bar.maxX - width, y: bar.minY - Grid.close - height, width: width, height: height)
        let plate = surface(size: frame.size, fill: .pane, stands: false)
        plate.frame = frame
        plate.setAccessibilityRole(.list)
        plate.setAccessibilityLabel("Sources")

        var top = height - inset
        // Its own field, a well like every field: a line of words 12 inside it.
        let fieldY = top - fieldHeight
        let well = addFieldWell(to: plate, in: NSRect(x: inset, y: fieldY,
                                                       width: width - inset * 2, height: fieldHeight))
        shownSourceField = well
        let typed = menu.typed.isEmpty
            ? NSTextField(labelWithAttributedString: BarTheme.placeholder("Search apps", role: .body))
            : NSTextField(labelWithString: menu.typed)
        if menu.typed.isEmpty { typed.followLook() } else { typed.setRole(.body); typed.textColor = BarTheme.ink }
        typed.sizeToFit()
        typed.frame.origin = NSPoint(x: BarTheme.wordPadding, y: (fieldHeight - typed.frame.height) / 2)
        well.addSubview(typed)
        let glyphs = menu.typed.isEmpty ? 0 : BarTheme.width(of: menu.typed, in: .body)
        addCaret(to: well, at: BarTheme.wordPadding + glyphs, role: .body)
        top = fieldY - Grid.close

        for (index, row) in rows {
            let y = top - rowHeight
            // A line of the row contract: the app's name, cut at the tail, and
            // how many clips it holds at the end, quiet.
            let line = ListLine(frame: NSRect(x: inset, y: y, width: width - inset * 2, height: rowHeight))
            line.choose(index == menu.selection)
            line.label.stringValue = row.name
            let count = NSTextField(labelWithString: "\(row.count)")
            count.setRole(.meta, tabular: true)
            count.textColor = BarTheme.secondaryColor
            line.setTrailing([count])
            line.setAccessibilityElement(true)
            line.setAccessibilityLabel("\(row.name), \(row.count) clips")
            plate.addSubview(line)
            shownSourceRows.append(row.name)
            top = y
            if index == 0, ruled {
                // A rule between the line groups, 8 above and 8 below.
                let rule = NSView(frame: NSRect(x: inset, y: top - Self.ruleRoom / 2, width: width - inset * 2,
                                                height: Ceramic.Edge.line * 2))
                rule.wantsLayer = true
                rule.layer?.backgroundColor = Ceramic.resolved(BarTheme.hairline)
                plate.addSubview(rule)
                top -= Self.ruleRoom
            }
        }
        root.addSubview(plate)
    }

    // MARK: - Actions

    /// The source list's width; its lines and its field are the row contract's
    /// (32 tall, touching, 8 inside the menu).
    private static let menuWidth: CGFloat = 272
    /// The room a rule between two groups of lines takes: 8 above it and 8 below.
    private static let ruleRoom = Grid.close * 2
    /// What an action's label and its key keep between them at the least.
    private static let actionKeyGap = Grid.section
    private static let actionRole = BarTheme.Role.body

    private func actionLabelWidth(_ text: String) -> CGFloat {
        let field = NSTextField(labelWithString: text)
        field.setRole(Self.actionRole)
        field.sizeToFit()
        return ceil(field.frame.width)
    }

    /// The rule falls before the first destructive action, and only when
    /// something benign precedes it.
    private func separatorIndex(_ actions: [Action]) -> Int? {
        guard let first = actions.firstIndex(where: \.isDestructive), first > 0 else { return nil }
        return first
    }

    private func actionSize(_ actions: [Action]) -> NSSize {
        let widest = actions.map { actionLabelWidth($0.label) }.max() ?? 0
        // The keys stand in one column, as wide as the widest of them.
        let widestKey = actions.map { Key.width(of: $0.key) }.max() ?? 0
        // A line: its symbol 12 inside it, its words 12 after the symbol, its
        // key 12 inside the far edge; the lines 8 inside the menu.
        let width = BarTheme.lineInset * 2 + Grid.part + BarTheme.symbolSize + Grid.part
            + widest + Self.actionKeyGap + widestKey + Grid.part
        var height = CGFloat(actions.count) * BarTheme.lineHeight + BarTheme.lineInset * 2
        if separatorIndex(actions) != nil { height += Self.ruleRoom }
        return NSSize(width: min(width, BarTheme.measure), height: height)
    }

    /// The menu stands over the card it acts on, its left edge on the
    /// card's: above a clip, and above a keepsake, where the bar's line
    /// is. It never leaves the screen.
    private func actionFrame(for id: String?, size: NSSize, layout: Layout, screen: NSRect) -> NSRect {
        var anchor = layout.bar
        if let id, let slot = shownPins.first(where: { $0.value.id == id })?.key,
           let place = layout.places["\(slot)"] {
            anchor = place
        } else if let id, let rank = shownRecents.firstIndex(where: { $0.id == id }),
                  let place = layout.places[Self.labels[rank]] {
            anchor = place
        }
        var origin = NSPoint(x: anchor.minX, y: anchor.maxY + Self.gap)
        origin.x = min(origin.x, screen.maxX - Self.margin - size.width)
        origin.y = min(origin.y, screen.maxY - Self.margin - size.height)
        return NSRect(origin: origin, size: size)
    }

    private func addActionCard(_ actions: [Action], frame: NSRect) {
        let plate = surface(size: frame.size, fill: .pane, stands: false)
        plate.frame = frame
        plate.setAccessibilityRole(.menu)
        shownActions = actions.map(\.label)

        let rule = separatorIndex(actions)
        let inset = BarTheme.lineInset
        var top = frame.height - inset
        for (offset, action) in actions.enumerated() {
            if offset == rule {
                // A rule between the groups of lines, 8 above and 8 below.
                let line = NSView(frame: NSRect(
                    x: inset, y: top - Self.ruleRoom / 2,
                    width: frame.width - inset * 2, height: Ceramic.Edge.line * 2))
                line.wantsLayer = true
                line.layer?.backgroundColor = Ceramic.resolved(BarTheme.hairline)
                plate.addSubview(line)
                top -= Self.ruleRoom
            }
            let bottom = top - BarTheme.lineHeight
            // A line of the row contract: a symbol, the action's name cut at
            // the tail, and the key that fires it at the end. What cannot be
            // undone is told by its place, under the rule at the menu's foot,
            // never painted: one light, no alarm colour. Nothing here is
            // chosen: the keys fire.
            let line = ListLine(frame: NSRect(x: inset, y: bottom, width: frame.width - inset * 2,
                                              height: BarTheme.lineHeight))
            line.setLead(ListLine.symbol(action.symbol))
            line.label.stringValue = action.label
            line.setTrailing([Keycaps.cap(action.key)])
            plate.addSubview(line)
            top = bottom
        }
        root.addSubview(plate)
    }

    /// The save band: the search bar's shape with a different job. The
    /// offered name stands in the field until something is typed, so `⏎`
    /// alone is a complete answer; the folder is named at the right.
    private func addSaveField(name: String, offered: String, folder: String, frame: NSRect) {
        let plate = surface(size: frame.size, fill: .pane, stands: false, rung: BarTheme.bandRadius)
        plate.frame = frame
        let well = addFieldWell(to: plate, in: plate.bounds.insetBy(dx: BarTheme.bandInset, dy: BarTheme.bandInset))
        shownBand = (plate, well)
        let width = well.bounds.width, height = well.bounds.height

        let symbol = NSImageView(image: NSImage(
            systemSymbolName: "square.and.arrow.down",
            accessibilityDescription: nil)?
            .withSymbolConfiguration(BarTheme.symbolBand) ?? NSImage())
        symbol.contentTintColor = BarTheme.secondaryColor
        symbol.frame = NSRect(x: BarTheme.wordPadding, y: (height - BarTheme.symbolSize) / 2,
                              width: BarTheme.symbolSize, height: BarTheme.symbolSize)
        well.addSubview(symbol)

        let place = NSTextField(labelWithString: "→ " + folder)
        place.setRole(.meta)
        place.textColor = BarTheme.secondaryColor
        place.lineBreakMode = .byTruncatingMiddle
        place.sizeToFit()
        let placeWidth = min(place.frame.width, width * Self.placeShare)
        place.frame = NSRect(x: width - BarTheme.wordPadding - placeWidth, y: (height - place.frame.height) / 2,
                             width: placeWidth, height: place.frame.height)
        well.addSubview(place)

        let field = NSTextField(labelWithString: name.isEmpty ? offered : name)
        field.setRole(.field)
        field.textColor = name.isEmpty ? BarTheme.secondaryColor : BarTheme.ink
        field.lineBreakMode = .byTruncatingHead
        field.sizeToFit()
        let fieldX = symbol.frame.maxX + BarTheme.wordPadding
        let room = place.frame.minX - fieldX - Grid.section
        field.frame = NSRect(x: fieldX, y: (height - field.frame.height) / 2,
                             width: min(field.frame.width, room), height: field.frame.height)
        well.addSubview(field)

        let shown = name.isEmpty ? offered : name
        let glyphs = BarTheme.width(of: shown, in: .field)
        addCaret(to: well, at: field.frame.minX + min(glyphs, field.frame.width), role: .field)
        root.addSubview(plate)
    }

    /// What a card is made of: the pane, the slab for the one the hand is on
    /// (design/11-slab.md), or a well for a free place.
    enum CardFill {
        case pane, slab, well
    }
}

/// A file's sheet on a card: content, drawn as it is, resting on the card
/// with a short soft shadow cast from its own outline, as a picture does.
final class SheetView: NSView {
    private let radius: CGFloat
    private let cast = CALayer()

    init(radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        cast.shadowOffset = CGSize(width: 0, height: -Grid.tight)
        cast.shadowRadius = Grid.tight + Grid.hair
        cast.shadowOpacity = 1
        layer?.insertSublayer(cast, at: 0)
        tint()
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cast.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tint()
    }

    private func tint() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cast.shadowColor = Ceramic.resolved(BarTheme.shadowInk, in: self)
        cast.shadowOpacity = dark ? 0.42 : 0.16
        CATransaction.commit()
    }
}
