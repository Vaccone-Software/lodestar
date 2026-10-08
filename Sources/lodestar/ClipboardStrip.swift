import AppKit
import LodestarCore

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

    static let gap: CGFloat = 10
    /// The space at G between the hands.
    static let gutter: CGFloat = 26
    /// The narrowest a card may be and still hold a line of a command.
    /// Below it J gives up its second key, and every key keeps its card.
    static let minModule: CGFloat = 150
    static let maxModule: CGFloat = 196
    /// The older clips' height. J, K, L and ; stand above it in small
    /// steps, so the newest leads by a step, never by a leap.
    static let clipHeight: CGFloat = 150
    static let rise: [CGFloat] = [1.26, 1.17, 1.11, 1.06]
    static let barHeight: CGFloat = 46
    static let margin: CGFloat = 22
    /// Where Keep's top edge stands, as a share of the screen's height:
    /// the bars' own line, so every surface opens at one height.
    static let topLine: CGFloat = 0.64

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
    private(set) var shownWeights: [Glass.Weight] = []
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
    private(set) var shownSourceRows: [String] = []
    /// The zones a timestamp is read into beside yours and UTC.
    var timeZones: [TimeZone] = []
    /// The units a measurement is read into.
    var units = ClipQuantity.System.regional()

    /// The clip door stands this far above the bottom of the screen: over
    /// the clips, with the keepsakes and the bar stepped aside.
    var doorFloor: CGFloat { Self.doorFloor(in: ActivePolicy.presentationFrame) }

    static func doorFloor(in screen: NSRect) -> CGFloat {
        layout(in: screen).rowTop - screen.minY + gap
    }

    private static let pad: CGFloat = 12
    /// The key's inset from a card's top edge, and the foot's height.
    private static let head: CGFloat = 10
    private static let foot: CGFloat = 26

    init() {
        panel = Glass.makePanel(level: .statusBar)
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
        shownWeights = []
        shownCards = [:]
        shownKeys = [:]
        shownNames = [:]
        shownCount = nil
        shownSource = nil
        shownSourceRows = []
        bandFrame = nil

        shownRecents = Array(recents.prefix(Self.labels.count))
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
            let lit = key != nil && (query != nil ? rank == selection : rank == 0)
            let card = makeCard(clip: clip, key: key, lit: lit, size: place.size,
                                face: rank == 0 && layout.wideJ ? BarTheme.titleFont : BarTheme.bodyFont,
                                lift: rank < 4 ? .float : .rest,
                                reading: reading,
                                thumbnail: clip.kind == .image ? thumbnail(clip.id) : nil,
                                raised: clip.id == actingOn)
            card.frame = local(place)
            card.setAccessibilityLabel(spoken(clip, rank: rank, label: label))
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
                                        thumbnail: clip.kind == .image ? thumbnail(clip.id) : nil,
                                        naming: naming?.id == clip.id ? naming : nil,
                                        raised: clip.id == actingOn)
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
                             shown: shownRecents.count, frame: local(layout.bar))
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
                                        thumbnail: nil, naming: naming, raised: true)
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
        shownRecents = []
        shownPins = [:]
        shownCards = [:]
        shownKeys = [:]
        shownWeights = []
        shownCount = nil
        shownSource = nil
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
                                     lift: rank < 4 ? .float : .rest, wholeLine: held == .shift,
                                     face: rank == 0 && layout.wideJ ? BarTheme.titleFont : BarTheme.bodyFont)
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
        addBar(key: "=", query: query, placeholder: "Type what you saw in another window",
               count: count, source: source, frame: local(layout.bar))
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
                               size: NSSize, lift: ObjectSurface.Lift, wholeLine: Bool, face: NSFont) -> NSView {
        let card = surface(size: size, lift: lift, weight: .normal)
        let id = "bring-\(match.source)-\(match.hit.location)-\(match.line.hashValue)"
        shownCards[id] = card
        shownKeys[id] = key
        _ = addKey(key, lit: lit, to: card, height: size.height)
        let body = NSRect(x: Self.pad, y: Self.foot, width: size.width - Self.pad * 2,
                          height: size.height - Self.head - BarTheme.chipHeight - 6 - Self.foot)
        let text = Self.bringLine(match, face: face, wholeLine: wholeLine)
        let preview = NSTextField(wrappingLabelWithString: "")
        preview.lineBreakMode = .byWordWrapping
        let line = ceil(face.ascender - face.descender + face.leading)
        preview.maximumNumberOfLines = max(1, Int(body.height / line))
        preview.cell?.truncatesLastVisibleLine = true
        preview.attributedStringValue = text
        preview.frame = body
        card.addSubview(preview)

        let where_ = NSTextField(labelWithString: from?.window ?? "")
        where_.font = BarTheme.secondaryFont
        where_.textColor = BarTheme.secondaryColor
        where_.lineBreakMode = .byTruncatingTail
        let app = NSTextField(labelWithString: from?.app ?? "")
        app.font = BarTheme.secondaryFont
        app.textColor = BarTheme.secondaryColor
        app.sizeToFit()
        app.frame.origin = NSPoint(x: Self.pad, y: 8)
        card.addSubview(app)
        where_.sizeToFit()
        let room = size.width - Self.pad - app.frame.maxX - 10
        if room > 24, from?.window.isEmpty == false {
            let width = min(where_.frame.width, room)
            where_.frame = NSRect(x: size.width - Self.pad - width, y: 8, width: width, height: where_.frame.height)
            card.addSubview(where_)
        }
        return card
    }

    /// A line as a card draws it. The text starts a little before the hit,
    /// with an ellipsis, when the hit sits far enough in that the card's
    /// lines would end before it; the token a pick brings stands out; and
    /// every secret's middle is a bar, as on Keep's cards, because the
    /// danger is the screen.
    static func bringLine(_ match: Bring.Match, face: NSFont, wholeLine: Bool) -> NSAttributedString {
        let line = match.line as NSString
        var start = 0
        if match.hit.location > 48 {
            start = match.hit.location - 32
            let space = line.range(of: " ", options: [], range: NSRange(location: start, length: match.hit.location - start))
            if space.location != NSNotFound { start = NSMaxRange(space) }
        }
        let lead = start > 0 ? "…" : ""
        let shift = (lead as NSString).length - start
        let out = NSMutableAttributedString(string: lead + line.substring(from: start), attributes: [
            .font: face, .foregroundColor: wholeLine ? NSColor.labelColor : BarTheme.secondaryColor,
        ])
        if !wholeLine {
            let token = NSIntersectionRange(match.token, NSRange(location: start, length: line.length - start))
            if token.length > 0 {
                out.addAttributes([.foregroundColor: NSColor.labelColor,
                                   .font: NSFontManager.shared.convert(face, toHaveTrait: .boldFontMask)],
                                  range: NSRange(location: token.location + shift, length: token.length))
            }
        }
        for span in ClipSecret.spans(in: match.line).reversed() {
            let middle = NSRange(location: span.range.location + span.head,
                                 length: max(0, span.range.length - span.head - span.tail))
            let shown = NSIntersectionRange(middle, NSRange(location: start, length: line.length - start))
            guard shown.length > 0 else { continue }
            out.replaceCharacters(in: NSRange(location: shown.location + shift, length: shown.length),
                                  with: secretBar(font: face))
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
        let letter = label.uppercased()
        switch held {
        case .control: return hasReading ? "⌃" + letter : nil
        case .option: return searching ? "⌥" + letter : letter
        case .shift: return searching ? nil : "⇧" + letter
        case .none:
            // While searching the letters are the query, so every match
            // wears the chord that takes it without leaving the search,
            // and the one ⏎ would take wears ⏎.
            if searching { return rank == selection ? "⏎" : "⌥" + letter }
            return letter
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
        Clipboard.reading(of: clip, units: units, zones: timeZones)
    }

    /// What VoiceOver says for a card: its key, its rank, what it holds,
    /// where it came from and when — the rank order, not the screen's.
    private func spoken(_ clip: Clipboard.Clip, rank: Int, label: String) -> String {
        let what = clip.kind == .image ? "Image" : (masked(clip)?.text ?? clip.preview)
        return Caption.line(["\(label.uppercased()), clip \(rank + 1)",
                             String(what.prefix(120)),
                             clip.sourceHost ?? clip.sourceAppName,
                             Clipboard.age(of: clip)])
    }

    // MARK: - Cards

    /// `counted` is false for what is not a card — the bar, a menu, the
    /// list of sources — so the cards' weights read alone.
    private func surface(size: NSSize, lift: ObjectSurface.Lift, weight: Weight,
                         counted: Bool = true) -> ObjectSurface {
        let card = SoftShadow.object(radius: BarTheme.rowRadius, lift: lift)
        card.frame = NSRect(origin: .zero, size: size)
        let veil: Glass.Weight
        switch weight {
        case .normal: veil = .normal
        case .highlighted: veil = .raised
        case .empty: veil = .faint
        }
        Glass.installBackdrop(in: card, cornerRadius: BarTheme.rowRadius, weight: veil)
        if counted { shownWeights.append(veil) }
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.button)
        return card
    }

    private func addKey(_ text: String, lit: Bool, to card: NSView, height: CGFloat) -> NSView {
        let cap = Self.placedCap(text, at: NSPoint(x: Self.pad, y: height - BarTheme.chipHeight - Self.head))
        (cap as? KeyFace)?.lit = lit
        card.addSubview(cap)
        return cap
    }

    private func makeCard(clip: Clipboard.Clip, key: String?, lit: Bool, size: NSSize,
                          face: NSFont = BarTheme.bodyFont,
                          lift: ObjectSurface.Lift, reading: String?,
                          thumbnail: NSImage?, raised: Bool) -> NSView {
        let card = surface(size: size, lift: lift, weight: raised ? .highlighted : .normal)
        shownCards[clip.id] = card
        let width = size.width, height = size.height
        let line = height - Self.head - BarTheme.chipHeight / 2
        var leading = Self.pad
        if let key {
            shownKeys[clip.id] = key
            leading = addKey(key, lit: lit, to: card, height: height).frame.maxX + 8
        }
        // A copy of several things says so beside its key.
        if let items = clip.itemsLabel {
            let count = NSTextField(labelWithString: items)
            count.font = BarTheme.secondaryFont
            count.textColor = BarTheme.secondaryColor
            count.sizeToFit()
            count.frame.origin = NSPoint(x: leading, y: line - count.frame.height / 2)
            card.addSubview(count)
        }

        // Every card's text starts the same distance below its top edge.
        let body = NSRect(x: Self.pad, y: Self.foot, width: width - Self.pad * 2,
                          height: height - Self.head - BarTheme.chipHeight - 6 - Self.foot)
        if let reading {
            // Held `⌃`: the card shows what it would paste, in Lodestar's
            // voice, where the clip was.
            shownReadings[clip.id] = reading
            let label = NSTextField(wrappingLabelWithString: reading)
            label.font = BarTheme.voiceFont
            label.textColor = .labelColor
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
            var read = time.note(zones: timeZones)
            if Self.lineWidth(read.local) > body.width - 6 { read = time.note(zones: timeZones, compact: true) }
            let room = body.height - Self.previewHeight(shown(clip).string, width: body.width) - Self.noteGap
            let lines = Self.pack([read.local] + read.zones, width: body.width,
                                  rows: Int((room - Self.voiceHeight - 2) / Self.metaHeight))
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
        } else if let thumbnail {
            let view = NSImageView(image: thumbnail)
            view.imageScaling = .scaleProportionallyUpOrDown
            view.frame = body
            card.addSubview(view)
        } else {
            addPreview(clip, to: card, in: body, above: nil, font: face)
        }

        // The foot: where it came from on the left, how long and how old
        // on the right. The page a browser copy was made on is the
        // address the hand remembers, "the one from GitHub".
        let badge = Clipboard.lengthBadge(for: clip)
        if let badge { shownBadges[clip.id] = badge }
        let caption = Caption.line([badge, Clipboard.age(of: clip)])
        shownCaptions[clip.id] = caption
        let age = NSTextField(labelWithString: caption)
        age.font = BarTheme.secondaryFont
        age.textColor = BarTheme.secondaryColor
        age.sizeToFit()
        age.frame.origin = NSPoint(x: width - age.frame.width - Self.pad, y: 8)
        card.addSubview(age)
        if let origin = clip.sourceHost ?? clip.sourceAppName {
            let source = NSTextField(labelWithString: origin)
            source.font = BarTheme.secondaryFont
            source.textColor = BarTheme.secondaryColor
            source.lineBreakMode = .byTruncatingTail
            source.sizeToFit()
            let room = age.frame.minX - 8 - Self.pad
            source.frame = NSRect(x: Self.pad, y: 8, width: max(0, min(source.frame.width, room)),
                                  height: source.frame.height)
            card.addSubview(source)
            shownSources[clip.id] = origin
        }
        return card
    }

    /// A keepsake: its number, its name, and the start of what it holds.
    /// It rests where a passing clip floats.
    private func makeKeepsake(clip: Clipboard.Clip, slot: Int, key: String?, size: NSSize,
                              reading: String?, thumbnail: NSImage?, naming: Naming?,
                              raised: Bool) -> NSView {
        let card = surface(size: size, lift: .rest, weight: raised || naming != nil ? .highlighted : .normal)
        shownCards[clip.id] = card
        let width = size.width, height = size.height
        var leading = Self.pad
        if let key {
            shownKeys[clip.id] = key
            leading = addKey(key, lit: false, to: card, height: height).frame.maxX + 8
        }
        let line = height - Self.head - BarTheme.chipHeight / 2

        let name = naming?.text ?? Clipboard.name(of: clip)
        shownNames[slot] = name
        let title = NSTextField(labelWithString: name)
        title.font = BarTheme.rowLabelFont
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.sizeToFit()
        let room = width - leading - Self.pad
        title.frame = NSRect(x: leading, y: line - title.frame.height / 2,
                             width: min(title.frame.width, room), height: title.frame.height)
        if let naming {
            if naming.selected {
                // The offered name stands selected, in a quiet grey:
                // typing replaces it. The accent is the caret's alone.
                let mark = NSView(frame: title.frame.insetBy(dx: -2, dy: 0))
                mark.wantsLayer = true
                mark.layer?.cornerRadius = BarTheme.markRadius
                mark.layer?.backgroundColor = Glass.resolved(NSColor.labelColor.withAlphaComponent(0.14), in: card)
                card.addSubview(mark)
            }
            card.addSubview(title)
            let glyphs = (name as NSString).size(withAttributes: [.font: BarTheme.rowLabelFont]).width
            let caret = NSView(frame: NSRect(x: title.frame.minX + min(glyphs, room) + 1,
                                             y: line - 9, width: 1.5, height: 18))
            caret.wantsLayer = true
            caret.layer?.backgroundColor = Glass.resolved(BarTheme.readableAccent)
            card.addSubview(caret)
        } else {
            card.addSubview(title)
        }

        let body = NSRect(x: Self.pad, y: Self.head, width: width - Self.pad * 2,
                          height: height - Self.head * 2 - BarTheme.chipHeight - 6)
        if let reading {
            shownReadings[clip.id] = reading
            let label = NSTextField(wrappingLabelWithString: reading)
            label.font = BarTheme.voiceFont
            label.textColor = .labelColor
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
            preview.font = BarTheme.secondaryFont
            preview.textColor = BarTheme.secondaryColor
            preview.lineBreakMode = .byWordWrapping
            preview.maximumNumberOfLines = max(1, Int(body.height / Self.metaHeight))
            preview.cell?.truncatesLastVisibleLine = true
            preview.attributedStringValue = shown(clip, font: BarTheme.secondaryFont)
            preview.frame = body
            card.addSubview(preview)
        }
        return card
    }

    /// A free place keeps the material and loses the frosting, with its
    /// number legible: it is how a hand that has never kept anything
    /// learns that it can.
    private func makeFreePlace(slot: Int, size: NSSize, wearsKey: Bool) -> NSView {
        let card = surface(size: size, lift: .rest, weight: .empty)
        var leading = Self.pad
        if wearsKey {
            let cap = addKey("\(slot)", lit: false, to: card, height: size.height)
            cap.alphaValue = 0.55
            leading = cap.frame.maxX + 8
        }
        let label = NSTextField(labelWithString: "Keep here")
        label.font = BarTheme.secondaryFont
        label.textColor = BarTheme.secondaryColor
        label.sizeToFit()
        label.frame.origin = NSPoint(x: leading,
                                     y: size.height - Self.head - BarTheme.chipHeight / 2 - label.frame.height / 2)
        card.addSubview(label)
        card.setAccessibilityLabel("Keepsake \(slot), free")
        return card
    }

    /// A card's text, drawn the one way every card draws it, from the top
    /// of the body down. A card with a note beneath gives up the lines
    /// the note stands in, never its place or its face.
    private func addPreview(_ clip: Clipboard.Clip, to card: NSView, in body: NSRect, above note: CGFloat?,
                            font: NSFont = BarTheme.bodyFont) {
        let preview = NSTextField(wrappingLabelWithString: "")
        preview.font = font
        preview.textColor = BarTheme.secondaryColor
        // Wrap to the card, ellipsize only the last line. Assigning
        // .byTruncatingTail here collapses the field to a single line
        // whatever the line limit says.
        preview.lineBreakMode = .byWordWrapping
        let line = ceil(font.ascender - font.descender + font.leading)
        preview.maximumNumberOfLines = max(1, Int(body.height / line))
        preview.cell?.truncatesLastVisibleLine = true
        preview.attributedStringValue = shown(clip, font: font)
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
        let roomy = voice.map { Self.widestWord($0) <= body.width - 50 } ?? true
        let swatchSide: CGFloat = roomy ? 40 : 26
        if color != nil { x += swatchSide + (roomy ? 10 : 8) }
        let width = body.maxX - x
        if let voice {
            let label = NSTextField(wrappingLabelWithString: voice)
            label.font = BarTheme.voiceFont
            label.textColor = BarTheme.secondaryColor
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 2
            label.frame.size = label.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
            labels.append(label)
            drawn.append(voice)
        }
        for line in lines {
            let label = NSTextField(labelWithString: line)
            label.font = BarTheme.secondaryFont
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
            y += label.frame.height + (index == 1 && voice != nil ? 2 : 0)
        }
        var top = y
        if let color {
            let middle = ((under ? voiceBottom : body.minY) + y) / 2
            let floor = under ? voiceBottom : body.minY
            let swatch = NSView(frame: NSRect(x: body.minX, y: max(floor, middle - swatchSide / 2),
                                              width: swatchSide, height: swatchSide))
            swatch.wantsLayer = true
            swatch.layer?.cornerRadius = BarTheme.wellRadius
            swatch.layer?.backgroundColor = NSColor(srgbRed: color.red, green: color.green, blue: color.blue,
                                                    alpha: color.alpha).cgColor
            swatch.layer?.borderWidth = 0.5
            swatch.layer?.borderColor = Glass.resolved(NSColor.labelColor.withAlphaComponent(0.2))
            card.addSubview(swatch)
            top = max(top, swatch.frame.maxY)
        }
        shownNotes[id] = drawn
        return top
    }

    /// How wide a caption line draws, measured as its label will.
    private static func lineWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: BarTheme.secondaryFont]).width)
    }

    /// The widest single word of a note, as the voice draws it.
    private static func widestWord(_ text: String) -> CGFloat {
        text.split(separator: " ").map {
            ceil((String($0) as NSString).size(withAttributes: [.font: BarTheme.voiceFont]).width) + 4
        }.max() ?? 0
    }

    /// The exact lines, as few as hold them.
    private static func pack(_ parts: [String], width: CGFloat, rows: Int) -> [String] {
        func fits(_ text: String) -> Bool {
            let label = NSTextField(labelWithString: text)
            label.font = BarTheme.secondaryFont
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
        return Array(lines.prefix(max(1, rows)))
    }

    /// A card's text as drawn: as much as a card holds, with a secret's
    /// middle as a bar (see `ClipSecret`). The clip keeps its whole text
    /// and the search reads it; only the glass is spared it, because Keep
    /// opened during a screen share is on everyone's screen.
    private func shown(_ clip: Clipboard.Clip, font: NSFont = BarTheme.bodyFont) -> NSAttributedString {
        let masked = masked(clip)
        let text = String((masked?.text ?? clip.preview).prefix(Clipboard.cardCharacters))
        let out = NSMutableAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: BarTheme.secondaryColor,
        ])
        guard let masked else { return out }
        shownMasked[clip.id] = text
        let length = (text as NSString).length
        for range in masked.blocks.reversed() where range.location < length {
            let drawn = NSIntersectionRange(range, NSRange(location: 0, length: length))
            out.replaceCharacters(in: drawn, with: Self.secretBar(font: font))
        }
        return out
    }

    /// The bar a secret's middle draws as: one rounded bar at the capital
    /// height in the text's own grey, the same width for every secret.
    private static func secretBar(font: NSFont) -> NSAttributedString {
        let size = NSSize(width: 33, height: ceil(font.capHeight))
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: size, flipped: false) { rect in
            BarTheme.secondaryColor.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1.5, dy: 0), xRadius: 2, yRadius: 2).fill()
            return true
        }
        attachment.bounds = NSRect(origin: .zero, size: size)
        let bar = NSMutableAttributedString(attachment: attachment)
        bar.addAttributes([.font: font, .foregroundColor: BarTheme.secondaryColor],
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
        preview.font = BarTheme.bodyFont
        preview.lineBreakMode = .byWordWrapping
        preview.maximumNumberOfLines = 2
        return ceil(preview.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    private static let noteGap: CGFloat = 8
    private static var bodyLine: CGFloat { ceil(BarTheme.bodyFont.ascender - BarTheme.bodyFont.descender + BarTheme.bodyFont.leading) }
    private static var metaHeight: CGFloat { 16 }
    private static var voiceHeight: CGFloat { ceil(BarTheme.voiceFont.ascender - BarTheme.voiceFont.descender) + 2 }

    /// The shared keycap, sized by its own constraints and then placed by
    /// frame, which is how a frame-laid card holds an Auto Layout view.
    static func placedCap(_ text: String, at origin: NSPoint) -> NSView {
        let cap = Keycaps.cap(text)
        cap.layoutSubtreeIfNeeded()
        let size = cap.fittingSize
        cap.translatesAutoresizingMaskIntoConstraints = true
        cap.frame = NSRect(origin: origin, size: NSSize(width: size.width, height: BarTheme.chipHeight))
        return cap
    }

    // MARK: - The bar

    /// The search over the right hand: `/`, what was typed, how many
    /// match, and the source the clips are filtered to.
    private func addSearchBar(query: String, source: String?, matches: Int?, shown: Int, frame: NSRect) {
        let count = matches.map { $0 == 0 ? "No matches" : $0 > shown ? "\(shown) of \($0)" : "\($0) found" }
        addBar(key: "/", query: query, placeholder: "Search clips", count: count, source: source, frame: frame)
    }

    /// The bar over the right hand, Keep's search and Bring's alike: the
    /// key that opened it, what was typed, how many answer, and the app
    /// the answers are filtered to.
    private func addBar(key: String, query: String, placeholder: String, count countText: String?,
                        source: String?, frame: NSRect) {
        let bar = surface(size: frame.size, lift: .float, weight: .normal, counted: false)
        bar.frame = frame
        bar.setAccessibilityRole(.textField)
        bar.setAccessibilityLabel(placeholder)
        bar.setAccessibilityValue(query)
        let height = frame.height
        let slash = Self.placedCap(key, at: NSPoint(x: Self.pad, y: (height - BarTheme.chipHeight) / 2))
        bar.addSubview(slash)

        // The source chip at the right: ⇥ and the app the clips come from.
        let chipKey = Self.placedCap("⇥", at: .zero)
        let name = NSTextField(labelWithString: source ?? "All apps")
        name.font = BarTheme.secondaryFont
        name.textColor = source == nil ? BarTheme.secondaryColor : .labelColor
        name.sizeToFit()
        shownSource = name.stringValue
        name.frame.origin = NSPoint(x: frame.width - Self.pad - name.frame.width,
                                    y: (height - name.frame.height) / 2)
        chipKey.frame.origin = NSPoint(x: name.frame.minX - 6 - chipKey.frame.width,
                                       y: (height - BarTheme.chipHeight) / 2)
        bar.addSubview(chipKey)
        bar.addSubview(name)

        var right = chipKey.frame.minX - 14
        if let text = countText {
            shownCount = text
            let count = NSTextField(labelWithString: text)
            count.font = BarTheme.secondaryFont
            count.textColor = BarTheme.secondaryColor
            count.sizeToFit()
            count.frame.origin = NSPoint(x: right - count.frame.width, y: (height - count.frame.height) / 2)
            bar.addSubview(count)
            right = count.frame.minX - 14
        }

        let font = BarTheme.stripInputFont
        let x = slash.frame.maxX + 10
        let field = query.isEmpty
            ? NSTextField(labelWithAttributedString: BarTheme.placeholder(placeholder, like: font))
            : NSTextField(labelWithString: query)
        if !query.isEmpty { field.font = font; field.textColor = .labelColor }
        field.lineBreakMode = .byTruncatingHead
        field.sizeToFit()
        field.frame = NSRect(x: x, y: (height - field.frame.height) / 2,
                             width: min(field.frame.width, max(0, right - x)), height: field.frame.height)
        bar.addSubview(field)
        // A still caret in the accent, never a blinking one.
        let glyphs = query.isEmpty ? 0 : (query as NSString).size(withAttributes: [.font: font]).width
        let caret = NSView(frame: NSRect(x: x + min(glyphs, field.frame.width) + (query.isEmpty ? 0 : 2),
                                         y: (height - 20) / 2, width: 1.5, height: 20))
        caret.wantsLayer = true
        caret.layer?.backgroundColor = Glass.resolved(BarTheme.readableAccent)
        bar.addSubview(caret)
        root.addSubview(bar)
    }

    /// The list of source apps, dropped from the bar's right end over the
    /// cards: its own field, All apps above a rule, then the apps
    /// alphabetically with how many clips each holds.
    private func addSourceMenu(_ menu: SourceMenu, under bar: NSRect) {
        let rowHeight: CGFloat = 30, fieldHeight: CGFloat = 38, width: CGFloat = 270
        let visible = 9
        let start = max(0, min(menu.selection - visible / 2, menu.rows.count - visible))
        let rows = Array(menu.rows.enumerated().dropFirst(start).prefix(visible))
        let ruled = rows.first?.offset == 0 && rows.count > 1
        let height = fieldHeight + 8 + CGFloat(rows.count) * rowHeight + (ruled ? 9 : 0) + 8
        let frame = NSRect(x: bar.maxX - width, y: bar.minY - 6 - height, width: width, height: height)
        let plate = surface(size: frame.size, lift: .float, weight: .highlighted, counted: false)
        plate.frame = frame
        plate.setAccessibilityRole(.list)
        plate.setAccessibilityLabel("Sources")

        var top = height - 8
        let font = BarTheme.secondaryFont
        let typed = menu.typed.isEmpty
            ? NSTextField(labelWithAttributedString: BarTheme.placeholder("Search apps", like: BarTheme.bodyFont))
            : NSTextField(labelWithString: menu.typed)
        if !menu.typed.isEmpty { typed.font = BarTheme.bodyFont; typed.textColor = .labelColor }
        typed.sizeToFit()
        let fieldY = top - fieldHeight
        typed.frame.origin = NSPoint(x: 16, y: fieldY + (fieldHeight - typed.frame.height) / 2)
        plate.addSubview(typed)
        let glyphs = menu.typed.isEmpty ? 0 : (menu.typed as NSString).size(withAttributes: [.font: BarTheme.bodyFont]).width
        let caret = NSView(frame: NSRect(x: 16 + glyphs + (menu.typed.isEmpty ? -3 : 2),
                                         y: fieldY + (fieldHeight - 18) / 2, width: 1.5, height: 18))
        caret.wantsLayer = true
        caret.layer?.backgroundColor = Glass.resolved(BarTheme.readableAccent)
        plate.addSubview(caret)
        top = fieldY - 8

        for (index, row) in rows {
            let y = top - rowHeight
            let line = RaisedLine(frame: NSRect(x: 6, y: y, width: width - 12, height: rowHeight))
            line.setupRaised()
            line.applyRaised(index == menu.selection)
            let name = NSTextField(labelWithString: row.name)
            name.font = BarTheme.bodyFont
            name.textColor = .labelColor
            name.lineBreakMode = .byTruncatingTail
            name.sizeToFit()
            let count = NSTextField(labelWithString: "\(row.count)")
            count.font = font
            count.textColor = BarTheme.secondaryColor
            count.sizeToFit()
            count.frame.origin = NSPoint(x: line.frame.width - 10 - count.frame.width,
                                         y: (rowHeight - count.frame.height) / 2)
            name.frame = NSRect(x: 10, y: (rowHeight - name.frame.height) / 2,
                                width: min(name.frame.width, count.frame.minX - 18), height: name.frame.height)
            line.addSubview(name)
            line.addSubview(count)
            line.setAccessibilityElement(true)
            line.setAccessibilityLabel("\(row.name), \(row.count) clips")
            plate.addSubview(line)
            shownSourceRows.append(row.name)
            top = y
            if index == 0, ruled {
                let rule = NSView(frame: NSRect(x: 16, y: top - 5, width: width - 32, height: 1))
                rule.wantsLayer = true
                rule.layer?.backgroundColor = Glass.resolved(NSColor.labelColor.withAlphaComponent(0.12))
                plate.addSubview(rule)
                top -= 9
            }
        }
        root.addSubview(plate)
    }

    // MARK: - Actions

    private static let actionRow: CGFloat = 32
    private static let actionPadY: CGFloat = 12
    private static let actionInset: CGFloat = 14
    private static let actionChipGap = BarTheme.rowGap
    private static let actionKeyGap = BarTheme.rowKeyGap
    private static let actionIcon = BarTheme.rowIcon
    private static let actionSeparator: CGFloat = 11
    private static let actionChip = NSSize(width: BarTheme.chipMinWidth, height: BarTheme.chipHeight)
    private static let actionFont = BarTheme.rowLabelFont

    private func actionLabelWidth(_ text: String) -> CGFloat {
        let field = NSTextField(labelWithString: text)
        field.font = Self.actionFont
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
        let width = Self.actionInset * 2 + Self.actionIcon + Self.actionChipGap
            + widest + Self.actionKeyGap + Self.actionChip.width
        var height = CGFloat(actions.count) * Self.actionRow + Self.actionPadY * 2
        if separatorIndex(actions) != nil { height += Self.actionSeparator }
        return NSSize(width: min(max(width, 220), 340), height: height)
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
        let plate = surface(size: frame.size, lift: .float, weight: .highlighted, counted: false)
        plate.frame = frame
        plate.setAccessibilityRole(.menu)
        shownActions = actions.map(\.label)

        let rule = separatorIndex(actions)
        var top = frame.height - Self.actionPadY
        for (offset, action) in actions.enumerated() {
            if offset == rule {
                let line = NSView(frame: NSRect(
                    x: Self.actionInset, y: top - Self.actionSeparator / 2,
                    width: frame.width - Self.actionInset * 2, height: 1))
                line.wantsLayer = true
                line.layer?.backgroundColor = Glass.resolved(NSColor.labelColor.withAlphaComponent(0.12))
                plate.addSubview(line)
                top -= Self.actionSeparator
            }
            let bottom = top - Self.actionRow
            // What cannot be undone is told by its place, under the rule
            // at the menu's foot, never painted: one light, no alarm colour.
            let tint: NSColor = .labelColor
            let icon = NSImageView(image: NSImage(
                systemSymbolName: action.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(BarTheme.symbol) ?? NSImage())
            icon.contentTintColor = tint
            icon.frame = NSRect(x: Self.actionInset,
                                y: bottom + (Self.actionRow - Self.actionIcon) / 2,
                                width: Self.actionIcon, height: Self.actionIcon)
            plate.addSubview(icon)

            let label = NSTextField(labelWithString: action.label)
            label.font = Self.actionFont
            label.textColor = tint
            label.lineBreakMode = .byTruncatingTail
            label.sizeToFit()
            let labelX = Self.actionInset + Self.actionIcon + Self.actionChipGap
            let keyX = frame.width - Self.actionInset - Self.actionChip.width
            label.frame = NSRect(x: labelX,
                                 y: bottom + (Self.actionRow - label.frame.height) / 2,
                                 width: max(0, keyX - Self.actionKeyGap - labelX),
                                 height: label.frame.height)
            plate.addSubview(label)

            let chip = Self.placedCap(action.key.uppercased(), at: NSPoint(
                x: keyX, y: bottom + (Self.actionRow - Self.actionChip.height) / 2))
            chip.frame.size.width = max(chip.frame.width, Self.actionChip.width)
            plate.addSubview(chip)
            top = bottom
        }
        root.addSubview(plate)
    }

    /// The save band: the search bar's shape with a different job. The
    /// offered name stands in the field until something is typed, so `⏎`
    /// alone is a complete answer; the folder is named at the right.
    private func addSaveField(name: String, offered: String, folder: String, frame: NSRect) {
        let plate = surface(size: frame.size, lift: .float, weight: .normal, counted: false)
        plate.frame = frame
        let width = frame.width, height = frame.height

        let symbol = NSImageView(image: NSImage(
            systemSymbolName: "square.and.arrow.down",
            accessibilityDescription: nil)?
            .withSymbolConfiguration(BarTheme.symbolBand) ?? NSImage())
        symbol.contentTintColor = BarTheme.secondaryColor
        symbol.frame = NSRect(x: 16, y: (height - 18) / 2, width: 18, height: 18)
        plate.addSubview(symbol)

        let place = NSTextField(labelWithString: "→ " + folder)
        place.font = BarTheme.secondaryFont
        place.textColor = BarTheme.secondaryColor
        place.lineBreakMode = .byTruncatingMiddle
        place.sizeToFit()
        let placeWidth = min(place.frame.width, width * 0.4)
        place.frame = NSRect(x: width - 16 - placeWidth, y: (height - place.frame.height) / 2,
                             width: placeWidth, height: place.frame.height)
        plate.addSubview(place)

        let font = BarTheme.stripInputFont
        let field = NSTextField(labelWithString: name.isEmpty ? offered : name)
        field.font = font
        field.textColor = name.isEmpty ? BarTheme.secondaryColor : .labelColor
        field.lineBreakMode = .byTruncatingHead
        field.sizeToFit()
        let room = place.frame.minX - 44 - 20
        field.frame = NSRect(x: 44, y: (height - field.frame.height) / 2,
                             width: min(field.frame.width, room), height: field.frame.height)
        plate.addSubview(field)

        let shown = name.isEmpty ? offered : name
        let glyphs = (shown as NSString).size(withAttributes: [.font: font]).width
        let caret = NSView(frame: NSRect(x: field.frame.minX + min(glyphs, field.frame.width) + 2,
                                         y: (height - 20) / 2, width: 1.5, height: 20))
        caret.wantsLayer = true
        caret.layer?.backgroundColor = Glass.resolved(BarTheme.readableAccent)
        plate.addSubview(caret)
        root.addSubview(plate)
    }

    enum Weight {
        case normal, highlighted
        /// A free place: the same material, less frosted.
        case empty
    }
}

/// A row of the source list: the bars' raised step.
private final class RaisedLine: RaisedRow {}
