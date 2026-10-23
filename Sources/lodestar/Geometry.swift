import AppKit

/// The geometry contract (design/03-geometry.md): one curve, one grid and
/// the sizes everything is cut to. A radius, a gap, an inset or a size in
/// layout code is a name from this file, never a number written where it
/// is used; a drift test reads the sources and fails on one.
extension BarTheme {
    // MARK: - Radii

    /// The ladder, anchored on the pill's own curve: the pill is 44 tall and
    /// fully round, so its ends have a radius of 22, and a surface rounds
    /// like the pill's end. Each rung below is the one above over φ²
    /// (22 → 8.40 → 3.21).
    static let phi: CGFloat = 1.618_033_988_75
    static let pillHeight: CGFloat = 44
    /// A panel, a card, the pill (whose ends it is).
    static let surfaceRadius: CGFloat = pillHeight / 2
    /// A key, a chip, a field, a popup, a button.
    static let controlRadius: CGFloat = surfaceRadius / (phi * phi)
    /// A highlight on text, a small badge.
    static let markRadius: CGFloat = controlRadius / (phi * phi)

    /// A hairline (a caret, a meter's bar) rounds to half its own width.
    static func hairlineRadius(width: CGFloat) -> CGFloat { width / 2 }

    /// A thing inside another rounds at the outer radius less its inset, so
    /// the gap between the two curves is even all the way round, and never
    /// below its own rung: a key inside a row, whose radius less the inset
    /// falls under 8.4, rounds at 8.4.
    static func nested(outer: CGFloat, inset: CGFloat, rung: CGFloat = markRadius) -> CGFloat {
        max(rung, outer - inset)
    }

    /// A row, a card or a field one pane-inset inside a pane: 22 − 12 = 10.
    static let paneRowRadius: CGFloat = nested(outer: surfaceRadius, inset: Grid.part, rung: controlRadius)

    /// A view shorter than twice its radius is a stadium: its ends are
    /// half its height.
    static func radius(_ rung: CGFloat, height: CGFloat) -> CGFloat { min(rung, height / 2) }

    // MARK: - The grid

    /// Every gap, inset and padding is one of these steps. The half-step
    /// `half` is allowed only inside a control (a key's horizontal padding,
    /// a chip's), because 4 crowds a letter and 8 makes a short key wide.
    enum Grid {
        /// Between a key and its side; a hairline's offset.
        static let hair: CGFloat = 2
        /// Between keys in a sequence; half a key's inner padding.
        static let tight: CGFloat = 4
        /// Inside a control; between an icon and its label.
        static let close: CGFloat = 8
        /// A pane's inset to its rows and field; between a row's parts.
        static let part: CGFloat = 12
        /// Between groups; a room's inset.
        static let group: CGFloat = 16
        /// Between sections of a room.
        static let section: CGFloat = 24
        /// A room's outer margin.
        static let margin: CGFloat = 32
        /// Between a room's columns.
        static let column: CGFloat = 48
        /// Only inside a control.
        static let half: CGFloat = 6

        static let steps: [CGFloat] = [hair, tight, close, part, group, section, margin, column]
    }

    // MARK: - Controls that hold words

    /// A control that holds words (a popup, a button, a field) pads 12 at its
    /// sides, and a popup's chevron stands 8 from its words. Only a key or a
    /// chip, which hold a letter, take the half-step.
    static let wordPadding: CGFloat = Grid.part
    static let chevronGap: CGFloat = Grid.close

    // MARK: - A bar's pane

    /// A bar's pane insets its field and its rows by one step, and the
    /// symbol and the words in each stand one step inside that.
    static let paneInset: CGFloat = Grid.part
    /// Where a bar's symbol starts, and where its field ends: the pane's
    /// inset and the row's own padding, so the symbol stands over the rows'
    /// icons.
    static let fieldInset: CGFloat = paneInset + Grid.part
    /// Where a bar's top edge stands, as a share of the screen's height:
    /// the bars' own line, so every surface opens at one height.
    static let topLine: CGFloat = 0.64

    /// What a bar's field takes from the top: the well, one pane inset
    /// from the pane's top and sides, and the well's own height.
    static var fieldArea: CGFloat { paneInset + inputHeight }

    /// The height under the field: nothing but the pane's inset below the
    /// well when no rows follow; otherwise the gap, the rows with a hair
    /// between them, and the pane's inset.
    static func rowsArea(count: Int, rowHeight: CGFloat = BarTheme.rowHeight) -> CGFloat {
        guard count > 0 else { return paneInset }
        return Grid.close + CGFloat(count) * rowHeight + CGFloat(count - 1) * Grid.hair + paneInset
    }

    // MARK: - Sizes

    /// How wide a field a person types into is, by what it holds. A field is
    /// as wide as its longest answer, not as the room it stands in.
    enum Field {
        /// A year, a count.
        static let number: CGFloat = 72
        /// A keycode.
        static let narrow: CGFloat = 80
        /// A name.
        static let short: CGFloat = 112
        /// A profile in a popup, a key's name.
        static let profile: CGFloat = 168
        static let keyName: CGFloat = 128
        /// An address, a pattern, a word.
        static let regular: CGFloat = 176
        /// A choice among apps or calendars.
        static let menu: CGFloat = 208
        /// A search address.
        static let wide: CGFloat = 280
    }

    /// The launcher, Ask, Commands: one instrument.
    static let panelWidth: CGFloat = 640
    /// A bar's field, which holds the 23-point field role.
    static let inputHeight: CGFloat = 60
    /// One line of body with an icon.
    static let rowHeight: CGFloat = 48
    /// A row with a detail line under its title: the chosen row stands on a
    /// side inside its frame, and two lines need as much face as one line
    /// had frame.
    static let detailRowHeight: CGFloat = rowHeight + Grid.tight
    /// A key's height: 21 of face on 3 of side. The key contract sets its
    /// width (its legend and a step each side) and parts (design/10-key.md).
    static let keyHeight: CGFloat = KeySize.standard.height
    /// An app's icon in a row; its artwork carries its own margin.
    static let appIconSize: CGFloat = 32
    /// A symbol leading a row, at the body's size.
    static let symbolSize: CGFloat = 16
    /// The least anything clickable is, though Lodestar is keyed first.
    static let minTarget: CGFloat = 24
    /// A room's one-line field, and a button's taller answer.
    static let fieldHeight: CGFloat = 32
    /// Where a window stands before it has content: sized by what it holds,
    /// not by this.
    static let unplaced = NSRect(x: 0, y: 0, width: 100, height: 100)
    /// An app's icon beside a title.
    static let titleIconSize: CGFloat = 24
    /// A bar's caret: a hairline in the accent, as tall as the line it stands in.
    static let caretWidth: CGFloat = 1.5
    static let caretHeight: CGFloat = 20
    static let bodyCaretHeight: CGFloat = 18
    /// A switch: a pointer target 24 high around a track 16 high.
    static let switchWidth: CGFloat = 32
    static let switchTrackHeight: CGFloat = 16
    /// A sentence's measure: about fifty characters at the voice role.
    static let measure: CGFloat = 380
}

typealias Grid = BarTheme.Grid
